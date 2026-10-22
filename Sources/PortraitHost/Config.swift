import Foundation

/// Command-line options. Sizes are in points (what macOS calls "looks like" resolution).
struct Config {
    var widthPoints = 900
    var heightPoints = 1200
    var hiDPI = true
    var streamScale = 2.0      // stream pixels per point (2 = full Retina sharpness)
    var fps = 30
    var quality = 0.7          // JPEG quality 0.1 ... 1.0
    var httpPort: UInt16 = 8080
    var name = "Portrait iPad"

    var wsPort: UInt16 { httpPort &+ 1 }
    var streamWidth: Int { Config.even(Double(widthPoints) * streamScale) }
    var streamHeight: Int { Config.even(Double(heightPoints) * streamScale) }

    private static func even(_ value: Double) -> Int {
        let v = Int(value.rounded())
        return max(2, v - (v % 2))
    }

    static let usage = """
    PortraitHost – turns your iPad (via Safari) into a portrait second screen.

    Usage: swift run -c release PortraitHost [options]

      --width <points>     Width of the virtual display in points   (default 900)
      --height <points>    Height of the virtual display in points  (default 1200)
                           Tip: open the page on the iPad once – the overlay shows the
                           iPad's own size; pass those numbers for a perfect fit.
      --scale <n>          Stream pixels per point, 1 – 2           (default 2 = sharpest)
      --quality <q>        JPEG quality, 0.3 – 0.95                 (default 0.7)
      --fps <n>            Max frames per second                    (default 30)
      --port <n>           Web page port; frames use port+1         (default 8080)
      --no-hidpi           Non-Retina virtual display (bigger UI, blurrier text)
      --help               Show this help
    """

    static func parse(_ args: [String]) -> Config {
        var c = Config()
        var i = 0
        func value() -> String {
            i += 1
            guard i < args.count else { fail("Missing value for \(args[i - 1])") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--width":   c.widthPoints = intArg(value(), 200...4000)
            case "--height":  c.heightPoints = intArg(value(), 200...4000)
            case "--scale":   c.streamScale = doubleArg(value(), 0.5...2.0)
            case "--quality": c.quality = doubleArg(value(), 0.1...1.0)
            case "--fps":     c.fps = intArg(value(), 1...60)
            case "--port":    c.httpPort = UInt16(intArg(value(), 1024...65000))
            case "--no-hidpi": c.hiDPI = false
            case "--help", "-h": print(usage); exit(0)
            default: fail("Unknown option \(args[i])\n\n\(usage)")
            }
            i += 1
        }
        return c
    }

    private static func intArg(_ s: String, _ range: ClosedRange<Int>) -> Int {
        guard let v = Int(s), range.contains(v) else { fail("'\(s)' should be a whole number in \(range)") }
        return v
    }

    private static func doubleArg(_ s: String, _ range: ClosedRange<Double>) -> Double {
        guard let v = Double(s), range.contains(v) else { fail("'\(s)' should be a number in \(range)") }
        return v
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("Error: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

/// A random access key, saved so the iPad Home Screen bookmark keeps working between runs.
enum TokenStore {
    static func loadOrCreate() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".portraitdisplay-token")
        if let saved = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), saved.count >= 8 {
            return saved
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        try? token.write(to: url, atomically: true, encoding: .utf8)
        return String(token)
    }
}

/// IPv4 addresses of this Mac (Wi-Fi, Ethernet, hotspot…), for the iPad URL.
func localIPv4Addresses() -> [(interface: String, address: String)] {
    var result: [(interface: String, address: String)] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        guard let addr = ptr.pointee.ifa_addr,
              addr.pointee.sa_family == UInt8(AF_INET),
              (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                       nil, 0, NI_NUMERICHOST) == 0 {
            let name = String(cString: ptr.pointee.ifa_name)
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254.") { result.append((interface: name, address: ip)) }
        }
    }
    // Wi-Fi / Ethernet (en*) first.
    func rank(_ name: String) -> Int { name.hasPrefix("en") ? 0 : 1 }
    return result.sorted { (rank($0.interface), $0.interface) < (rank($1.interface), $1.interface) }
}
