import Foundation
import CoreGraphics

/// Owns the virtual display and its screen capture. Normally they exist the whole run; with
/// --on-demand only while an iPad is connected: created when the first one connects, removed
/// `linger` seconds after the last one leaves (so a Wi-Fi blip or a short screen lock doesn't send
/// every window back to the MacBook). Main queue only.
final class DisplayController {
    static let linger: TimeInterval = 15

    var onDisplay: ((CGDirectDisplayID?) -> Void)?   // the new display, or nil once it's gone

    private enum State { case off, on(VirtualDisplay), stopping }
    private var state = State.off
    private var viewers = 0
    private var removal: DispatchWorkItem?
    private let config: Config
    private let capturer: Capturer

    init(config: Config, capturer: Capturer) {
        self.config = config
        self.capturer = capturer
    }

    func viewersChanged(_ count: Int) {
        viewers = count
        update()
    }

    func update() {
        if viewers > 0 || !config.onDemand {
            removal?.cancel()
            removal = nil
            if case .off = state { show() }   // while .stopping, the stop's completion calls update()
        } else if case .on = state, removal == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.removal = nil
                self?.hide()
            }
            removal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
        }
    }

    private func show() {
        guard let display = VirtualDisplay(config: config) else {
            fail("macOS refused to create the virtual display.")
        }
        state = .on(display)
        Status.emit("display", "on")
        onDisplay?(display.displayID)
        // Give macOS a moment to register the new display, then pick its mode and start capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard case .on(let current) = self.state, current === display else { return }
            display.selectPreferredMode()
            print("Virtual display \"\(self.config.name)\": \(display.currentModeDescription)")
            self.capturer.start(displayID: display.displayID) { error in
                if let error = error { Self.captureFailed(error) }
                let codec = self.config.codec == .hevc ? "HEVC (H.264 for iPads without it)" : "H.264"
                print("Capturing at up to \(self.config.fps) fps, \(codec) "
                      + "\(self.config.streamWidth)×\(self.config.streamHeight) px, max \(Int(self.config.bitrateMbps)) Mbit/s.")
            }
        }
    }

    private func hide() {
        guard viewers == 0, case .on = state else { return }
        state = .stopping
        onDisplay?(nil)
        capturer.stop {
            self.state = .off   // releases the VirtualDisplay, which removes it
            print("Virtual display removed (no iPad for \(Int(Self.linger)) s).")
            Status.emit("display", "off")
            self.update()       // an iPad may have connected while capture was stopping
        }
    }

    private static func captureFailed(_ error: Error) -> Never {
        print("""

        Couldn't capture the screen: \(error.localizedDescription)

        Give Terminal permission: System Settings → Privacy & Security →
        Screen & System Audio Recording → switch on Terminal, then quit
        Terminal completely and run this again.
        """)
        Status.emit("error", "capture: \(error.localizedDescription)")
        exit(1)
    }
}
