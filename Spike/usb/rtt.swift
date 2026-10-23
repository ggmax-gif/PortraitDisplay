// USB spike, Mac side: waits for the iPad on usbmuxd, connects to the echo app's port through the
// cable, and times round trips. See docs/usb-design.md. Run: swift Spike/usb/rtt.swift
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let appPort: UInt16 = 20808
let pings = 1000
let bigMessage = 300_000     // about one keyframe
let bigRounds = 20

// MARK: usbmuxd messages: 16-byte little-endian header (length, version 1, type 8 = plist, tag) + XML plist.

func muxSocket() -> Int32 {
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
    return fd
}

func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var sent = 0
        while sent < data.count {
            let n = write(fd, raw.baseAddress! + sent, data.count - sent)
            precondition(n > 0, "write failed: \(String(cString: strerror(errno)))")
            sent += n
        }
    }
}

func readExactly(_ fd: Int32, _ count: Int) -> Data? {
    var data = Data(count: count)
    var got = 0
    while got < count {
        let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
        if n <= 0 { return nil }
        got += n
    }
    return data
}

func send(_ fd: Int32, _ message: [String: Any], tag: UInt32) {
    let body = try! PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
    var header = Data()
    for v in [UInt32(16 + body.count), 1, 8, tag] { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
    writeAll(fd, header + body)
}

func receive(_ fd: Int32) -> [String: Any]? {
    guard let header = readExactly(fd, 16) else { return nil }
    let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.load(as: UInt32.self))) }
    guard let body = readExactly(fd, length - 16) else { return nil }
    return try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
}

func base(_ type: String) -> [String: Any] {
    ["MessageType": type, "ClientVersionString": "PortraitDisplay-spike", "ProgName": "PortraitDisplay"]
}

// MARK: Find the iPad

func waitForUSBDevice() -> Int {
    let fd = muxSocket()
    send(fd, base("ListDevices"), tag: 1)
    if let list = receive(fd)?["DeviceList"] as? [[String: Any]],
       let usb = list.first(where: { (($0["Properties"] as? [String: Any])?["ConnectionType"] as? String) == "USB" }),
       let id = usb["DeviceID"] as? Int {
        close(fd)
        return id
    }
    close(fd)
    print("Waiting for the iPad on USB (plug it in, unlock it, tap Trust if asked)…")
    let listener = muxSocket()
    send(listener, base("Listen"), tag: 2)
    while let event = receive(listener) {
        let props = event["Properties"] as? [String: Any]
        if event["MessageType"] as? String == "Attached", props?["ConnectionType"] as? String == "USB",
           let id = event["DeviceID"] as? Int {
            close(listener)
            return id
        }
    }
    fatalError("usbmuxd closed the listen connection")
}

/// A socket that is now a raw TCP tunnel to `appPort` on the iPad, or nil and usbmuxd's error number.
func connectToApp(device: Int) -> (fd: Int32?, code: Int) {
    let fd = muxSocket()
    var message = base("Connect")
    message["DeviceID"] = device
    message["PortNumber"] = Int(appPort.bigEndian)   // usbmuxd wants it in network byte order
    send(fd, message, tag: 3)
    let result = receive(fd)?["Number"] as? Int ?? -1
    if result == 0 { return (fd, 0) }
    close(fd)
    return (nil, result)
}

// MARK: Measure

func percentile(_ sorted: [Double], _ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }

let device = waitForUSBDevice()
print("iPad found (usbmuxd device \(device)). Connecting to port \(appPort)…")
var tunnel: Int32 = -1
for attempt in 1...30 {
    let (fd, code) = connectToApp(device: device)
    if let fd { tunnel = fd; break }
    if attempt == 1 { print("Connect answered \(code) (3 = nothing listening: open the echo app on the iPad). Retrying…") }
    sleep(1)
}
guard tunnel >= 0 else { print("SPIKE FAILED: no connection to the app after 30 s."); exit(1) }
print("Connected through the cable.")

var times: [Double] = []
var payload = Data(count: 64)
for i in 0..<pings {
    payload[0] = UInt8(i & 0xFF)
    let t0 = DispatchTime.now().uptimeNanoseconds
    writeAll(tunnel, payload)
    guard let echo = readExactly(tunnel, payload.count), echo == payload else { print("SPIKE FAILED: bad echo at ping \(i)"); exit(1) }
    times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
}
let sorted = times.sorted()
print(String(format: "%d pings of 64 B: median %.2f ms, p99 %.2f ms, max %.2f ms",
             pings, percentile(sorted, 0.5), percentile(sorted, 0.99), sorted.last!))

let big = Data((0..<bigMessage).map { UInt8(truncatingIfNeeded: $0 &* 31) })
var bigTimes: [Double] = []
for _ in 0..<bigRounds {
    let t0 = DispatchTime.now().uptimeNanoseconds
    writeAll(tunnel, big)
    guard let echo = readExactly(tunnel, big.count), echo == big else { print("SPIKE FAILED: bad 300 KB echo"); exit(1) }
    bigTimes.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
}
let bigMedian = bigTimes.sorted()[bigRounds / 2]
print(String(format: "%d × %d KB round trips: median %.1f ms (%.0f Mbit/s each way)",
             bigRounds, bigMessage / 1000, bigMedian, Double(bigMessage * 8) / (bigMedian / 2 / 1000) / 1e6))

let pass = percentile(sorted, 0.5) < 2 && percentile(sorted, 0.99) < 5
print(pass ? "SPIKE PASSED (median < 2 ms, p99 < 5 ms)." : "SPIKE: connection works but latency is above the target.")
close(tunnel)
