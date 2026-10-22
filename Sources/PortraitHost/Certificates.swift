import Foundation
import Network
import Security

/// HTTPS is required because Safari only exposes WebCodecs (VideoDecoder) to secure pages.
/// A local CA lives in ~/.portraitdisplay/ and is installed on the iPad once. Each run issues a
/// fresh server certificate for the Mac's current private IPs, so a new Wi-Fi needs no reinstall.
/// The CA is name-constrained to private IP ranges, so it can't vouch for any real website.
enum Certificates {
    static let caName = "PortraitDisplay Local CA"

    /// Private ranges the CA may sign for: 10/8, 172.16/12 (incl. iPhone hotspot), 192.168/16,
    /// 100.64/10 (CGNAT, Tailscale) and loopback.
    static let permittedRanges: [(base: UInt32, mask: UInt32)] = [
        (0x0A00_0000, 0xFF00_0000), (0xAC10_0000, 0xFFF0_0000), (0xC0A8_0000, 0xFFFF_0000),
        (0x6440_0000, 0xFFC0_0000), (0x7F00_0000, 0xFF00_0000),
    ]

    static func isPermitted(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return false }
        let value = parts.reduce(0) { $0 << 8 | $1 }
        return permittedRanges.contains { value & $0.mask == $0.base }
    }

    private static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".portraitdisplay")
    private static var caKey: URL { dir.appendingPathComponent("ca.key") }
    private static var caPEM: URL { dir.appendingPathComponent("ca.pem") }

    /// The CA certificate in DER form, served to the iPad for installation.
    static func caDER() -> Data {
        let pem = (try? String(contentsOf: caPEM, encoding: .utf8)) ?? ""
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: base64) ?? Data()
    }

    /// Creates the CA on first use, issues a server certificate for `ips` and returns TLS options.
    static func tlsOptions(ips: [String]) throws -> NWProtocolTLS.Options {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: caKey.path) || !fm.fileExists(atPath: caPEM.path) {
            try createCA()
            print("Created a new certificate authority in \(dir.path) – install it on the iPad (see the setup page).")
        }
        let identity = try issueServerIdentity(ips: ips)
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        return options
    }

    private static func createCA() throws {
        func ip(_ v: UInt32) -> String { (0..<4).map { String(v >> (24 - 8 * $0) & 0xFF) }.joined(separator: ".") }
        let ranges = permittedRanges.map { "permitted;IP:\(ip($0.base))/\(ip($0.mask))" }
        // A permitted DNS subtree that can never resolve blocks every real hostname.
        let config = """
        [req]
        distinguished_name = dn
        [dn]
        [v3]
        basicConstraints = critical, CA:TRUE, pathlen:0
        keyUsage = critical, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        nameConstraints = critical, \(ranges.joined(separator: ", ")), permitted;DNS:portrait.invalid
        """
        try withTemporaryDirectory { tmp in
            let cnf = tmp.appendingPathComponent("ca.cnf")
            try config.write(to: cnf, atomically: true, encoding: .utf8)
            try openssl(["req", "-x509", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                         "-subj", "/CN=\(caName)", "-config", cnf.path, "-extensions", "v3",
                         "-keyout", caKey.path, "-out", caPEM.path])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKey.path)
    }

    private static func issueServerIdentity(ips: [String]) throws -> SecIdentity {
        let sans = (ips.filter(isPermitted) + ["127.0.0.1"]).map { "IP:\($0)" }
        let config = """
        [v3]
        basicConstraints = critical, CA:FALSE
        keyUsage = critical, digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        authorityKeyIdentifier = keyid
        subjectAltName = \(sans.joined(separator: ", "))
        """
        let password = UUID().uuidString
        let p12: Data = try withTemporaryDirectory { tmp in
            let path = { (name: String) in tmp.appendingPathComponent(name).path }
            try config.write(toFile: path("server.cnf"), atomically: true, encoding: .utf8)
            try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=Portrait Display",
                         "-keyout", path("server.key"), "-out", path("server.csr")])
            // 397 days: Apple rejects TLS certificates valid for longer.
            try openssl(["x509", "-req", "-sha256", "-days", "397", "-set_serial", String(UInt32.random(in: 1...UInt32.max)),
                         "-in", path("server.csr"), "-CA", caPEM.path, "-CAkey", caKey.path,
                         "-extfile", path("server.cnf"), "-extensions", "v3", "-out", path("server.pem")])
            // 3DES because Security.framework can't read every PKCS#12 cipher LibreSSL offers.
            try openssl(["pkcs12", "-export", "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES",
                         "-inkey", path("server.key"), "-in", path("server.pem"),
                         "-passout", "pass:\(password)", "-out", path("server.p12")])
            return try Data(contentsOf: URL(fileURLWithPath: path("server.p12")))
        }

        var items: CFArray?
        let options = [kSecImportExportPassphrase: password, kSecImportToMemoryOnly: true] as [CFString: Any] as CFDictionary
        let status = SecPKCS12Import(p12 as CFData, options, &items)
        guard status == errSecSuccess,
              let first = (items as? [[CFString: Any]])?.first,
              let identity = first[kSecImportItemIdentity] else {
            throw HostError.certificate("couldn't load the server certificate (\(status))")
        }
        return identity as! SecIdentity
    }

    private static func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("portraitdisplay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try body(tmp)
    }

    /// macOS's own LibreSSL, not whatever `openssl` Homebrew or Anaconda put first on PATH.
    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HostError.certificate("openssl \(arguments.first ?? "") failed: \(message)")
        }
    }
}
