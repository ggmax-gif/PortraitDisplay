import AppKit
import CoreGraphics
import IOKit.pwr_mgt

/// Owns the virtual display and its screen capture. Normally they exist the whole run; with
/// --on-demand only while an iPad is connected: created when the first one connects, removed
/// `--linger` seconds after the last one leaves (so a Wi-Fi blip or a short screen lock doesn't send
/// every window back to the MacBook). Main queue only.
///
/// Capture stops while the Mac sleeps and restarts on wake; the virtual display itself stays. Closing
/// the lid also takes every display away first, and ScreenCaptureKit then stops with "Failed to find
/// any displays": a capture lost while the screens are off waits for them to wake, any other lost
/// capture is retried. It keeps running if it can while only the screens are off (the Mac's display
/// can idle off while you read on the iPad).
final class DisplayController {
    var onDisplay: ((CGDirectDisplayID?) -> Void)?   // the new display, or nil once it's gone
    private var landscape = false   // the iPad app is held sideways

    private enum State { case off, on(VirtualDisplay), stopping }
    private var state = State.off
    private var viewers = 0
    private var removal: DispatchWorkItem?
    private let config: Config
    private let capturer: Capturer
    private var asleep = false        // the Mac is asleep: capture stopped
    private var screensAsleep = false
    private var waitingForScreens = false   // capture was lost while the screens were off
    private var captureGeneration = 0 // bumped on every pause / restart, so stale retries do nothing
    private var awakeAssertion: IOPMAssertionID?

    init(config: Config, capturer: Capturer) {
        self.config = config
        self.capturer = capturer
        capturer.onStreamLost = { [weak self] error in self?.captureLost(error) }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pauseCapture()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resumeCapture()
        }
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = true
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensWoke()
        }
    }

    func viewersChanged(_ count: Int) {
        viewers = count
        keepScreensAwake(count > 0)
        update()
    }

    /// Nothing can be captured while the Mac's screens are off, so the iPad's picture would freeze
    /// when the Mac's display idles off while you read on the iPad. Closing the lid still sleeps it.
    private func keepScreensAwake(_ on: Bool) {
        if on, awakeAssertion == nil {
            var id = IOPMAssertionID(0)
            let reason = "An iPad is showing the Portrait iPad display" as CFString
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                awakeAssertion = id
            }
        } else if !on, let id = awakeAssertion {
            IOPMAssertionRelease(id)
            awakeAssertion = nil
        }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(config.lingerSeconds), execute: work)
        }
    }

    /// The iPad app turned to `degrees` from portrait. At 90 and 270 the display turns landscape. At
    /// 180 it stays portrait: the app turns its own picture, so upside down looks the same to the Mac.
    func setOrientation(_ degrees: Int) {
        guard let landscape = Orientation.isLandscape(degrees: degrees), landscape != self.landscape else { return }
        self.landscape = landscape
        guard case .on(let display) = state else { return }   // show() uses it
        display.setLandscape(landscape)
        applyMode(of: display, attempt: 0)
    }

    /// macOS lists the new modes a moment after the settings change, then the capture follows.
    private func applyMode(of display: VirtualDisplay, attempt: Int) {
        guard case .on(let current) = state, current === display, display.landscape == landscape else { return }
        guard display.selectPreferredMode() || attempt >= 30 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.applyMode(of: display, attempt: attempt + 1) }
            return
        }
        print("Virtual display turned \(landscape ? "landscape" : "portrait"): \(display.currentModeDescription)")
        let size = config.streamSize(landscape: landscape)
        capturer.resize(width: size.width, height: size.height)
    }

    private func show() {
        guard let display = VirtualDisplay(config: config, landscape: landscape) else {
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
            let size = self.config.streamSize(landscape: display.landscape)
            self.capturer.resize(width: size.width, height: size.height)
            self.startCapture(retries: 0)   // a first failure is usually permission: report it at once
        }
    }

    /// Starts capturing the current display, trying again every 2 s up to `retries` times (the
    /// displays take a moment to come back after a wake). Exits only when every try has failed while
    /// the Mac and its screens are awake.
    private func startCapture(retries: Int) {
        guard case .on(let display) = state, !asleep else { return }   // resumes on wake
        captureGeneration += 1
        let generation = captureGeneration
        capturer.start(displayID: display.displayID) { error in
            guard generation == self.captureGeneration else { return }
            guard let error else {
                let codec = self.config.codec == .hevc ? "HEVC (H.264 for iPads without it)" : "H.264"
                let size = self.config.streamSize(landscape: display.landscape)
                print("Capturing at up to \(self.config.fps) fps, \(codec) "
                      + "\(size.width)×\(size.height) px, max \(Int(self.config.bitrateMbps)) Mbit/s.")
                return
            }
            if self.screensAsleep { self.waitForScreens(); return }
            guard retries > 0 else { Self.captureFailed(error) }
            self.retry(after: 2, retries: retries - 1)
        }
    }

    private func retry(after seconds: Double, retries: Int) {
        captureGeneration += 1
        let generation = captureGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard generation == self.captureGeneration else { return }
            self.capturer.stop { self.startCapture(retries: retries) }
        }
    }

    private func waitForScreens() {
        guard !waitingForScreens else { return }
        waitingForScreens = true
        captureGeneration += 1
        print("Screens off: capture waits for them to wake.")
    }

    private func pauseCapture() {
        guard !asleep else { return }
        asleep = true
        waitingForScreens = false
        captureGeneration += 1
        guard case .on = state else { return }
        print("Mac asleep: capture paused.")
        capturer.stop {}
    }

    private func resumeCapture() {
        guard asleep else { return }
        asleep = false
        guard case .on = state else { return }
        print("Mac awake: resuming capture.")
        retry(after: 2, retries: 5)
    }

    private func screensWoke() {
        screensAsleep = false
        guard waitingForScreens, !asleep else { return }
        waitingForScreens = false
        print("Screens on: resuming capture.")
        retry(after: 2, retries: 5)
    }

    /// The stream died by itself. With the screens off (the lid closing, say) it waits for them;
    /// otherwise it's retried, for up to a minute.
    private func captureLost(_ error: Error) {
        print("Screen capture stopped (\(error.localizedDescription)).")
        if screensAsleep { waitForScreens(); return }
        retry(after: 2, retries: 30)
    }

    private func hide() {
        guard viewers == 0, case .on = state else { return }
        state = .stopping
        onDisplay?(nil)
        capturer.stop {
            self.state = .off   // releases the VirtualDisplay, which removes it
            self.landscape = false   // a Safari viewer next time wouldn't say
            print("Virtual display removed (no iPad for \(self.config.lingerSeconds) s).")
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

/// The iPad app's interface orientation, in degrees from portrait (UIKit's landscapeRight is 90,
/// portraitUpsideDown 180, landscapeLeft 270).
enum Orientation {
    /// Nil for anything that isn't a quarter turn.
    static func isLandscape(degrees: Int) -> Bool? {
        guard degrees % 90 == 0 else { return nil }
        return (degrees / 90) % 2 != 0
    }
}
