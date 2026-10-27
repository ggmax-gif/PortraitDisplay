// Link spike, Mac side: connects to the echo app (Spike/link/EchoApp) and times round trips.
// See docs/native-viewer-design.md.
//
//   swift Spike/link/rtt.swift                 USB cable, through usbmuxd
//   swift Spike/link/rtt.swift --wifi          direct Wi-Fi (peer-to-peer, the router's Wi-Fi is blocked)
//   swift Spike/link/rtt.swift --wifi-router   ordinary Wi-Fi through the access point, for comparison
import Foundation
import Network

setvbuf(stdout, nil, _IOLBF, 0)
let appPort: UInt16 = 20808
let service = "_portraitecho._tcp"
let pings = 1000
let bigMessage = 300_000     // about one keyframe
let bigRounds = 20

protocol Link {
    func writeAll(_ data: Data)
    func readExactly(_ count: Int) -> Data?
}

// MARK: USB: usbmuxd messages are a 16-byte little-endian header (length, version 1, type 8 = plist,
// tag) followed by an XML plist. After a successful Connect the socket is a raw TCP tunnel.

struct SocketLink: Link {
    let fd: Int32

    func writeAll(_ data: Data) {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < data.count {
                let n = write(fd, raw.baseAddress! + sent, data.count - sent)
                precondition(n > 0, "write failed: \(String(cString: strerror(errno)))")
                sent += n
            }
        }
    }

    func readExactly(_ count: Int) -> Data? {
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

func muxSocket() -> SocketLink {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: 104) { strcpy($0, "/var/run/usbmuxd") }
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    precondition(ok == 0, "can't open /var/run/usbmuxd: \(String(cString: strerror(errno)))")
    return SocketLink(fd: fd)
}

func send(_ link: SocketLink, _ message: [String: Any], tag: UInt32) {
    let body = try! PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
    var header = Data()
    for v in [UInt32(16 + body.count), 1, 8, tag] { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
    link.writeAll(header + body)
}

func receive(_ link: SocketLink) -> [String: Any]? {
    guard let header = link.readExactly(16) else { return nil }
    let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.load(as: UInt32.self))) }
    guard let body = link.readExactly(length - 16) else { return nil }
    return try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
}

func base(_ type: String) -> [String: Any] {
    ["MessageType": type, "ClientVersionString": "PortraitDisplay-spike", "ProgName": "PortraitDisplay"]
}

func waitForUSBDevice() -> Int {
    let lister = muxSocket()
    send(lister, base("ListDevices"), tag: 1)
    defer { close(lister.fd) }
    if let list = receive(lister)?["DeviceList"] as? [[String: Any]],
       let usb = list.first(where: { (($0["Properties"] as? [String: Any])?["ConnectionType"] as? String) == "USB" }),
       let id = usb["DeviceID"] as? Int {
        return id
    }
    print("Waiting for the iPad on USB (plug it in, unlock it, tap Trust if asked)…")
    let listener = muxSocket()
    send(listener, base("Listen"), tag: 2)
    while let event = receive(listener) {
        let props = event["Properties"] as? [String: Any]
        if event["MessageType"] as? String == "Attached", props?["ConnectionType"] as? String == "USB",
           let id = event["DeviceID"] as? Int {
            close(listener.fd)
            return id
        }
    }
    fatalError("usbmuxd closed the listen connection")
}

func connectOverUSB() -> (Link, String) {
    let device = waitForUSBDevice()
    print("iPad found (usbmuxd device \(device)). Connecting to port \(appPort)…")
    for attempt in 1...30 {
        let mux = muxSocket()
        var message = base("Connect")
        message["DeviceID"] = device
        message["PortNumber"] = Int(appPort.bigEndian)   // usbmuxd wants it in network byte order
        send(mux, message, tag: 3)
        let result = receive(mux)?["Number"] as? Int ?? -1
        if result == 0 { return (mux, "USB cable") }
        close(mux.fd)
        if attempt == 1 { print("Connect answered \(result) (3 = nothing listening: open the echo app on the iPad). Retrying…") }
        sleep(1)
    }
    print("SPIKE FAILED: no connection to the app over USB after 30 s.")
    exit(1)
}

// MARK: Wi-Fi: find the app over Bonjour and connect with Network.framework.

final class ConnectionLink: Link {
    let connection: NWConnection
    init(_ connection: NWConnection) { self.connection = connection }

    func writeAll(_ data: Data) {
        let done = DispatchSemaphore(value: 0)
        connection.send(content: data, completion: .contentProcessed { error in
            precondition(error == nil, "send failed: \(error!)")
            done.signal()
        })
        done.wait()
    }

    func readExactly(_ count: Int) -> Data? {
        var result = Data()
        while result.count < count {
            let done = DispatchSemaphore(value: 0)
            var chunk: Data?
            connection.receive(minimumIncompleteLength: 1, maximumLength: count - result.count) { data, _, _, _ in
                chunk = data
                done.signal()
            }
            done.wait()
            guard let chunk, !chunk.isEmpty else { return nil }
            result.append(chunk)
        }
        return result
    }
}

/// The Mac's ordinary (infrastructure) Wi-Fi and wired interfaces, to block for a direct-only test.
func routerInterfaces() -> [NWInterface] {
    let monitor = NWPathMonitor()
    let done = DispatchSemaphore(value: 0)
    var found: [NWInterface] = []
    monitor.pathUpdateHandler = { path in
        found = path.availableInterfaces.filter {
            ($0.type == .wifi || $0.type == .wiredEthernet) && !$0.name.hasPrefix("awdl") && !$0.name.hasPrefix("llw")
        }
        done.signal()
    }
    monitor.start(queue: DispatchQueue(label: "monitor"))
    _ = done.wait(timeout: .now() + 2)
    monitor.cancel()
    return found
}

func connectOverWiFi(directOnly: Bool) -> (Link, String) {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.includePeerToPeer = true
    if directOnly {
        let blocked = routerInterfaces()
        parameters.prohibitedInterfaces = blocked
        print("Direct Wi-Fi only: not using \(Set(blocked.map(\.name)).sorted().joined(separator: ", ")).")
    }
    let queue = DispatchQueue(label: "wifi")
    let browser = NWBrowser(for: .bonjour(type: service, domain: nil), using: parameters)
    let found = DispatchSemaphore(value: 0)
    var endpoint: NWEndpoint?
    browser.browseResultsChangedHandler = { results, _ in
        if endpoint == nil, let first = results.first { endpoint = first.endpoint; found.signal() }
    }
    browser.start(queue: queue)
    print("Looking for the echo app over Wi-Fi (open it on the iPad)…")
    guard found.wait(timeout: .now() + 60) == .success, let endpoint else {
        print("SPIKE FAILED: the echo app wasn't found over Wi-Fi in 60 s.")
        exit(1)
    }
    browser.cancel()
    print("Found \(endpoint). Connecting…")

    let connection = NWConnection(to: endpoint, using: parameters)
    let ready = DispatchSemaphore(value: 0)
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready: ready.signal()
        case .failed(let error): print("SPIKE FAILED: \(error)"); exit(1)
        default: break
        }
    }
    connection.start(queue: queue)
    guard ready.wait(timeout: .now() + 30) == .success else { print("SPIKE FAILED: no connection in 30 s."); exit(1) }
    let interfaces = connection.currentPath?.availableInterfaces.map(\.name).joined(separator: ", ") ?? "unknown"
    return (ConnectionLink(connection), "Wi-Fi via \(interfaces)")
}

// MARK: Measure

func percentile(_ sorted: [Double], _ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }

let arguments = CommandLine.arguments.dropFirst()
let (link, path) = arguments.contains("--wifi") ? connectOverWiFi(directOnly: true)
    : arguments.contains("--wifi-router") ? connectOverWiFi(directOnly: false)
    : connectOverUSB()
print("Connected (\(path)).")

var payload = Data(count: 64)
for _ in 0..<10 {   // warm-up, not measured: the first exchange can wait on a permission prompt or a cold link
    link.writeAll(payload)
    guard link.readExactly(payload.count) != nil else { print("SPIKE FAILED: no echo"); exit(1) }
}
var times: [Double] = []
for i in 0..<pings {
    payload[0] = UInt8(i & 0xFF)
    let t0 = DispatchTime.now().uptimeNanoseconds
    link.writeAll(payload)
    guard let echo = link.readExactly(payload.count), echo == payload else { print("SPIKE FAILED: bad echo at ping \(i)"); exit(1) }
    times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
}
let sorted = times.sorted()
print(String(format: "%d pings of 64 B: median %.2f ms, p99 %.2f ms, max %.2f ms",
             pings, percentile(sorted, 0.5), percentile(sorted, 0.99), sorted.last!))

let big = Data((0..<bigMessage).map { UInt8(truncatingIfNeeded: $0 &* 31) })
var bigTimes: [Double] = []
for _ in 0..<bigRounds {
    let t0 = DispatchTime.now().uptimeNanoseconds
    link.writeAll(big)
    guard let echo = link.readExactly(big.count), echo == big else { print("SPIKE FAILED: bad 300 KB echo"); exit(1) }
    bigTimes.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
}
let bigMedian = bigTimes.sorted()[bigRounds / 2]
print(String(format: "%d × %d KB round trips: median %.1f ms (%.0f Mbit/s each way)",
             bigRounds, bigMessage / 1000, bigMedian, Double(bigMessage * 8) / (bigMedian / 2 / 1000) / 1e6))

let pass = percentile(sorted, 0.5) < 2 && percentile(sorted, 0.99) < 5
print(pass ? "PASSED (median < 2 ms, p99 < 5 ms) over \(path)."
           : "Connected over \(path), but latency is above the 2 ms / 5 ms target.")
