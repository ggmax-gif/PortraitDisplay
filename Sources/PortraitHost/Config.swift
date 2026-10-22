import Foundation

/// Command-line options. Sizes are in points (what macOS calls "looks like" resolution).
struct Config {
    var widthPoints = 1024     // iPad Pro 12.9" Home Screen app (status bar takes 32 pt)
    var heightPoints = 1334
    var hiDPI = true
    var input = true           // touch / Pencil from the iPad controls the Mac
    var streamScale = 2.0      // stream pixels per point (2 = full Retina sharpness)
    var fps = 60
    var bitrateMbps = 20.0     // encoder cap; still screens use far less
    var codec = VideoCodec.h264  // .hevc = HEVC while every iPad can decode it, else H.264
    var httpPort: UInt16 = 8080
    var name = "Portrait iPad"
    var statusLines = false    // set by the menu bar app

    var pagePort: UInt16 { httpPort &+ 1 }   // HTTPS viewer page
    var wsPort: UInt16 { httpPort &+ 2 }     // secure WebSocket
    var streamWidth: Int { Config.even(Double(widthPoints) * streamScale) }
    var streamHeight: Int { Config.even(Double(heightPoints) * streamScale) }

    private static func even(_ value: Double) -> Int {
        let v = Int(value.rounded())
        return max(2, v - (v % 2))
    }

    static let usage = """
    PortraitHost – turns your iPad (via Safari) into a portrait second screen.

    Usage: swift run -c release PortraitHost [options]

      --width <points>     Width of the virtual display in points   (default 1024)
      --height <points>    Height of the virtual display in points  (default 1334)
                           Tip: open the page on the iPad once – the overlay shows the
                           iPad's own size; pass those numbers for a perfect fit.
      --scale <n>          Stream pixels per point, 0.5 – 2         (default 2 = sharpest)
      --bitrate <mbps>     Video bitrate cap in Mbit/s, 2 – 40      (default 20)
      --codec <name>       h264 or hevc. hevc: ~40% less data while things move, a little
                           softer once still; H.264 for iPads that can't decode it (default h264)
      --fps <n>            Max frames per second, up to 120         (default 60)
      --port <n>           Setup page port; also uses port+1, +2    (default 8080)
      --no-hidpi           Non-Retina virtual display (bigger UI, blurrier text)
      --no-input           View only: ignore touch and Pencil from the iPad
      --status-lines       Also print "@key value" lines (used by the menu bar app)
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
            case "--bitrate": c.bitrateMbps = doubleArg(value(), 2...40)
            case "--fps":     c.fps = intArg(value(), 1...120)
            case "--codec":
                guard let codec = VideoCodec(rawValue: value()) else { fail("--codec should be h264 or hevc") }
                c.codec = codec
            case "--port":    c.httpPort = UInt16(intArg(value(), 1024...65000))
            case "--no-hidpi": c.hiDPI = false
            case "--no-input": c.input = false
            case "--status-lines": c.statusLines = true
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
    Status.emit("error", message)
    FileHandle.standardError.write(("Error: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

/// With --status-lines, "@key value" lines next to the normal output, for the menu bar app to read.
/// Keys: url, running, viewers, stats, needs-accessibility, error.
enum Status {
    static var enabled = false

    static func emit(_ key: String, _ value: String = "") {
        if enabled { print("@\(key) \(value)") }
    }
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
