import Foundation
import Shared

/// Finds the iPad on the USB cable through usbmuxd (`/var/run/usbmuxd`, the channel Xcode and Finder
/// use) and connects to the native viewer app's port whenever the iPad is plugged in and the app is
/// open. A successful `Connect` turns the usbmuxd socket into a raw TCP tunnel to the app.
///
/// Messages to usbmuxd are a 16-byte little-endian header (length, version 1, type 8 = plist, tag)
/// followed by an XML plist. `PortNumber` goes in network byte order inside the plist integer.
/// Measured over this tunnel: 0.31 ms median round trip, 352 Mbit/s (docs/native-viewer-design.md).
final class USBMux {
    static let appPort = NativeLink.usbPort

    /// A tunnel to the app on `device`. Call `linkClosed(device:)` when it ends.
    var onConnected: ((_ fd: Int32, _ device: Int) -> Void)?

    private let queue = DispatchQueue(label: "portrait.usbmux")
    private var attached: Set<Int> = []    // USB devices usbmuxd reports, on `queue`
    private var connected: Set<Int> = []

    func start() {
        Thread.detachNewThread { [weak self] in self?.listen() }
    }

    func linkClosed(device: Int) {
        queue.async {
            self.connected.remove(device)
            self.queue.asyncAfter(deadline: .now() + 1) { self.tryConnect(device) }
        }
    }

    // MARK: Attach events (blocking, on its own thread)

    private func listen() {
        while true {
            if let fd = Self.open() {
                Self.send(fd, Self.message("Listen"), tag: 1)
                while let event = Self.receive(fd) { handle(event) }
                close(fd)
            }
            queue.async { self.attached.removeAll() }
            Thread.sleep(forTimeInterval: 2)   // usbmuxd restarted, or wasn't reachable: try again
        }
    }

    private func handle(_ event: [String: Any]) {
        guard let device = event["DeviceID"] as? Int else { return }
        let props = event["Properties"] as? [String: Any]
        switch event["MessageType"] as? String {
        case "Attached" where props?["ConnectionType"] as? String == "USB":
            queue.async {
                self.attached.insert(device)
                print("iPad on USB: waiting for the Portrait Display app to open on it.")
                self.tryConnect(device)
            }
        case "Detached":
            queue.async { self.attached.remove(device) }
        default:
            break
        }
    }

    // MARK: Connecting (on `queue`)

    private func tryConnect(_ device: Int) {
        guard attached.contains(device), !connected.contains(device) else { return }
        guard let fd = Self.open() else { return }
        var message = Self.message("Connect")
        message["DeviceID"] = device
        message["PortNumber"] = Int(Self.appPort.bigEndian)
        Self.send(fd, message, tag: 2)
        let result = Self.receive(fd)?["Number"] as? Int ?? -1
        if result == 0 {
            connected.insert(device)
            onConnected?(fd, device)
            return
        }
        close(fd)
        // 3 means nothing is listening yet: the app isn't open, or is in the background.
        queue.asyncAfter(deadline: .now() + 1) { self.tryConnect(device) }
    }

    // MARK: usbmuxd protocol

    private static func message(_ type: String) -> [String: Any] {
        ["MessageType": type, "ClientVersionString": "PortraitDisplay", "ProgName": "PortraitDisplay"]
    }

    private static func open() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { strcpy($0, "/var/run/usbmuxd") }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 { close(fd); return nil }
        var noSigPipe: Int32 = 1   // a write after usbmuxd hangs up should fail, not kill the process
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func send(_ fd: Int32, _ message: [String: Any], tag: UInt32) {
        guard let body = try? PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0) else { return }
        var data = Data()
        for v in [UInt32(16 + body.count), 1, 8, tag] { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(body)
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < data.count {
                let n = write(fd, raw.baseAddress! + sent, data.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    private static func receive(_ fd: Int32) -> [String: Any]? {
        guard let header = readExactly(fd, 16) else { return nil }
        let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.load(as: UInt32.self))) }
        guard length >= 16, length < 1 << 20, let body = readExactly(fd, length - 16) else { return nil }
        return try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
            if n <= 0 { return nil }
            got += n
        }
        return data
    }
}
