import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let config = Config.parse(Array(CommandLine.arguments.dropFirst()))
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
    encoder = try VideoEncoder(width: config.streamWidth, height: config.streamHeight,
                               fps: config.fps, bitrateMbps: config.bitrateMbps)
} catch {
    fail(error.localizedDescription)
}
encoder.onConfig = { server.publish($0) }
encoder.onFrame = { server.publish($0) }

let capturer = Capturer(config: config, encoder: encoder)
server.onKeyframeNeeded = { capturer.requestKeyframe() }

if config.input {
    let injector = InputInjector(displayID: virtualDisplay.displayID)
    server.onInput = { injector.handle($0) }
    if !InputInjector.ensurePermission() {
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
            exit(1)
        }
        print("Capturing at up to \(config.fps) fps, H.264 \(config.streamWidth)×\(config.streamHeight) px, "
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
}
print("""

 The first time, that page shows how to install this Mac's certificate
 (needed for the H.264 decoder). Then it opens the display by itself.
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
