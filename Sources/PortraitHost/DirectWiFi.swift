import CryptoKit
import Foundation
import Network
import Shared

/// The native iPad app over direct peer-to-peer Wi-Fi (the link AirDrop uses), so the stream skips
/// the router. Measured on this link: 5.2 ms median round trip, against 12.7 ms through the router
/// (docs/native-viewer-design.md).
///
/// Security: the Mac would otherwise stream the screen to any nearby device advertising the service.
/// So the app is paired over the USB cable first: the Mac sends it this Mac's ID, name and a random
/// 256-bit key (`pairing.message`), and Wi-Fi connections use TLS with that pre-shared key, the ID
/// being its identity (Shared/DirectWiFiTLS.swift). A device without the key can't complete the
/// handshake, and the stream is encrypted over the air. Deleting the key file unpairs every iPad;
/// the next USB connection pairs again.
enum DirectWiFi {
    private static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".portraitdisplay")
    static let keyURL = folder.appendingPathComponent("direct-wifi.key")

    /// This Mac's pairing: created on first use, kept in ~/.portraitdisplay (readable only by you).
    static let pairing: Pairing = {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = saved(keyURL, count: 32) ?? create(keyURL, SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        // A stable ID, so pairing again (after unpairing) replaces this Mac's entry on the iPad.
        let idURL = folder.appendingPathComponent("mac-id")
        let id = saved(idURL, count: 36).flatMap { String(data: $0, encoding: .utf8) }
            ?? String(decoding: create(idURL, Data(UUID().uuidString.utf8)), as: UTF8.self)
        return Pairing(macID: id, macName: Host.current().localizedName ?? "Mac", key: key)
    }()

    static func parameters() -> NWParameters {
        DirectWiFiTLS.parameters(keys: [(pairing.macID, pairing.key)])
    }

    private static func saved(_ url: URL, count: Int) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count == count else { return nil }
        return data
    }

    private static func create(_ url: URL, _ data: Data) -> Data {
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        return data
    }
}

/// Finds the paired iPad app over direct Wi-Fi and connects to it whenever the USB cable isn't
/// already in use. Connections go only over the peer-to-peer interface: a Wi-Fi interface is required
/// (which rules out anri0, the IPv6 network Xcode runs over the cable) and the router's interfaces
/// are blocked, as the feasibility test had to.
final class DirectBrowser {
    /// A ready, authenticated connection to the app. Call `linkClosed()` when it ends.
    var onConnected: ((NWConnection) -> Void)?
    /// Whether a USB viewer is connected; the cable is preferred, so Wi-Fi waits.
    var usbInUse: () -> Bool = { false }

    private let queue = DispatchQueue(label: "portrait.direct")
    private var browser: NWBrowser?
    private var found: Set<NWEndpoint> = []
    private var connecting: NWConnection?
    private var connected = false
    private var announced = false
    private var lastProblem = ""

    func start() {
        queue.async { self.browse() }
        // Re-check every few seconds: the cable may have been unplugged, or a connect may have failed.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.queue.async { self?.tryConnect() }
        }
    }

    func linkClosed() {
        queue.async {
            self.connected = false
            self.queue.asyncAfter(deadline: .now() + 1) { self.tryConnect() }
        }
    }

    private func browse() {
        let browser = NWBrowser(for: .bonjour(type: NativeLink.bonjourService, domain: nil), using: Self.directParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.found = Set(results.map(\.endpoint))
            self?.tryConnect()
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .waiting(let error) = state { self?.report("Wi-Fi browsing is waiting: \(error)") }
            if case .failed(let error) = state {   // e.g. Local Network permission not granted yet: try again later
                self?.report("Wi-Fi browsing failed: \(error)")
                self?.browser?.cancel()
                self?.queue.asyncAfter(deadline: .now() + 5) { self?.browse() }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func tryConnect() {
        guard !connected, connecting == nil, !usbInUse(), let endpoint = found.first else { return }
        let connection = NWConnection(to: endpoint, using: Self.directParameters())
        connecting = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connecting else { return }
            switch state {
            case .ready:
                self.connecting = nil
                self.connected = true
                connection.stateUpdateHandler = nil   // the link takes over
                self.onConnected?(connection)
            case .failed(let error):
                // Not paired with this Mac (the TLS handshake fails), or out of range.
                self.report("couldn't connect directly over Wi-Fi: \(error)")
                connection.cancel()
                self.connecting = nil
            case .waiting(let error):
                // Often brief while the peer-to-peer link comes up; give it 10 s.
                self.report("waiting for the direct Wi-Fi link: \(error)")
                self.queue.asyncAfter(deadline: .now() + 10) { [weak connection] in
                    guard let connection, connection === self.connecting else { return }
                    connection.cancel()
                    self.connecting = nil
                }
            default:
                break
            }
        }
        if !announced {
            print("Found the iPad app over Wi-Fi; connecting directly (peer-to-peer).")
            announced = true
        }
        connection.start(queue: queue)
    }

    /// Each distinct problem once, so a retry every few seconds doesn't fill the log.
    private func report(_ problem: String) {
        guard problem != lastProblem else { return }
        lastProblem = problem
        print("iPad app: \(problem)")
        if problem.contains("-65570") || problem.lowercased().contains("prohibit") || problem.contains("policy") {
            print("  (macOS may be blocking local network access: System Settings → Privacy & Security → Local Network → Portrait Display)")
        }
    }

    private static func directParameters() -> NWParameters {
        let parameters = DirectWiFi.parameters()
        parameters.requiredInterfaceType = .wifi
        parameters.prohibitedInterfaces = routerInterfaces()
        return parameters
    }

    /// The Mac's ordinary Wi-Fi and wired interfaces; the peer-to-peer ones (awdl, llw) stay allowed.
    private static func routerInterfaces() -> [NWInterface] {
        var found: [String: NWInterface] = [:]
        for type in [NWInterface.InterfaceType.wifi, .wiredEthernet] {
            let monitor = NWPathMonitor(requiredInterfaceType: type)
            let done = DispatchSemaphore(value: 0)
            monitor.pathUpdateHandler = { path in
                for interface in path.availableInterfaces where !interface.name.hasPrefix("awdl") && !interface.name.hasPrefix("llw") {
                    found[interface.name] = interface
                }
                done.signal()
            }
            monitor.start(queue: DispatchQueue(label: "portrait.direct.monitor"))
            _ = done.wait(timeout: .now() + 1)
            monitor.cancel()
        }
        return Array(found.values)
    }
}
