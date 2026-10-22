import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let config = Config.parse(Array(CommandLine.arguments.dropFirst()))
let token = TokenStore.loadOrCreate()

guard let virtualDisplay = VirtualDisplay(config: config) else {
    fail("macOS refused to create the virtual display.")
}

let server = StreamServer(config: config, token: token)
do {
    try server.start()
} catch {
    fail("Couldn't start the web server: \(error)")
}

let capturer = Capturer(config: config) { jpeg in server.publish(jpeg) }

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
        print("Capturing at up to \(config.fps) fps, stream \(config.streamWidth)×\(config.streamHeight) px.")
    }
}

let addresses = localIPv4Addresses()
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

 Then Share → Add to Home Screen for a full-screen app.
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
