import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

let config = Config.parse(Array(CommandLine.arguments.dropFirst()))
Status.enabled = config.statusLines

// Under the menu bar app: quit with it, even if it crashes, so the virtual display never outlives it.
// Armed before the slow setup; the second getppid() catches a parent that died while arming.
var parentWatch: DispatchSourceProcess?
if config.statusLines {
    parentWatch = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
    parentWatch?.setEventHandler { exit(0) }
    parentWatch?.resume()
    if getppid() == 1 { exit(0) }
}
let token = TokenStore.loadOrCreate()

// Only private addresses: the iPad trusts the certificate for those and nothing else.
let addresses = localIPv4Addresses().filter { Certificates.isPermitted($0.address) }

let server = StreamServer(config: config, token: token)
do {
    let tls = try Certificates.tlsOptions(ips: addresses.map { $0.address })
    try server.start(tls: tls)
} catch {
    fail("Couldn't start the web server: \(error.localizedDescription)")
}

let encoder: VideoEncoder
do {
    encoder = try VideoEncoder(codec: server.initialCodec, width: config.streamWidth,
                               height: config.streamHeight, fps: config.fps, bitrateMbps: config.bitrateMbps)
} catch {
    fail(error.localizedDescription)
}
encoder.onConfig = { server.publish($0) }
encoder.onFrame = { server.publish($0) }

let capturer = Capturer(config: config, encoder: encoder)
server.onKeyframeNeeded = { capturer.requestKeyframe() }
server.onCodecWanted = { codec in
    encoder.switchCodec(to: codec)
    capturer.requestKeyframe()   // a still screen sends nothing new to carry the switch
}
capturer.freeSlots = { server.freeSlots }
server.onRoom = { capturer.roomAvailable() }
server.macStats = {
    let s = capturer.takeStats(), t = StreamServer.statsInterval
    return String(format: "Mac: captured %.0f/s, encoded %.0f/s (%@) in %.0f ms",
                  Double(s.captured) / t, Double(s.encoded) / t, encoder.codec.name, s.encodeMs)
}

let displays = DisplayController(config: config, capturer: capturer)
server.onViewerCount = { count in DispatchQueue.main.async { displays.viewersChanged(count) } }

if config.input {
    let injector = InputInjector()
    displays.onDisplay = { injector.setDisplay($0) }
    server.onInput = { injector.handle($0) }
    server.onViewerGone = { injector.release() }
    if !InputInjector.ensurePermission() {
        Status.emit("needs-accessibility")
        print("""
        Touch and Pencil input need Accessibility permission: System Settings → Privacy & Security →
        Accessibility → turn on the app running this (e.g. Terminal), then run this again.
        Until then the iPad is view-only. (--no-input hides this message.)

        """)
    }
}

displays.update()   // creates the display now, unless --on-demand

print("""

────────────────────────────────────────────────────────
 Portrait display is running. On the iPad, open Safari and go to:
""")
if addresses.isEmpty {
    print("   (no network found – connect the Mac to Wi-Fi)")
}
for entry in addresses {
    print("   http://\(entry.address):\(config.httpPort)/?t=\(token)    [\(entry.interface)]")
    Status.emit("url", "http://\(entry.address):\(config.httpPort)/?t=\(token)")
}
print("""

 The first time, that page shows how to install this Mac's certificate
 (needed for the video decoder). Then it opens the display by itself.
 Add it to the Home Screen from there (Share → Add to Home Screen).
 Move windows onto "\(config.name)" like any other monitor
 (arrange it in System Settings → Displays → Arrange…).
\(config.onDemand
    ? " The display appears when the iPad connects and goes away \(Int(DisplayController.linger)) s after it leaves."
    : " Press Ctrl+C here to stop – the virtual display goes away.")
────────────────────────────────────────────────────────

""")
Status.emit("running")

signal(SIGINT) { _ in
    print("\nStopped.")
    exit(0)
}

// An AppKit run loop rather than dispatchMain(): without it this process never hears about display
// changes, and a re-created virtual display (--on-demand) has no modes to choose from.
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
