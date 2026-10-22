import Foundation

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

guard let virtualDisplay = VirtualDisplay(config: config) else {
    fail("macOS refused to create the virtual display.")
}

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

if config.input {
    let injector = InputInjector(displayID: virtualDisplay.displayID)
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

// Give macOS a moment to register the new display, then pick its mode and start capturing.
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    virtualDisplay.selectPreferredMode()
    print("Virtual display \"\(config.name)\": \(virtualDisplay.currentModeDescription)")
    capturer.start(displayID: virtualDisplay.displayID) { error in
        if let error = error {
            print("""

            Couldn't capture the screen: \(error.localizedDescription)

            Give Terminal permission: System Settings → Privacy & Security →
            Screen & System Audio Recording → switch on Terminal, then quit
            Terminal completely and run this again.
            """)
            Status.emit("error", "capture: \(error.localizedDescription)")
            exit(1)
        }
        Status.emit("running", virtualDisplay.currentModeDescription)
        let codec = config.codec == .hevc ? "HEVC (H.264 for iPads without it)" : "H.264"
        print("Capturing at up to \(config.fps) fps, \(codec) \(config.streamWidth)×\(config.streamHeight) px, "
              + "max \(Int(config.bitrateMbps)) Mbit/s.")
    }
}

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
 Press Ctrl+C here to stop – the virtual display goes away.
────────────────────────────────────────────────────────

""")

signal(SIGINT) { _ in
    print("\nStopped.")
    exit(0)
}

dispatchMain()
