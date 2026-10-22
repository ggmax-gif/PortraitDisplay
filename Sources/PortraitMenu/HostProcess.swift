import Foundation

/// Runs PortraitHost (in the bundle's Helpers, or next to this executable in .build) with --status-lines and follows its "@key value"
/// lines. All output also goes to ~/Library/Logs/PortraitDisplay.log. Everything here is on the main thread.
final class HostProcess {
    enum State { case stopped, starting, running }

    private(set) var state = State.stopped
    private(set) var urls: [String] = []
    private(set) var viewers = 0
    private(set) var displayOn = false
    private(set) var stats: String?
    private(set) var needsAccessibility = false
    private var lastError: String?

    var onChange: (() -> Void)?
    /// The host quit by itself with an error. The message is its last "@error" line, if any.
    var onFailure: ((String) -> Void)?

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PortraitDisplay.log")

    private var process: Process?
    private var restartPending = false
    private var pending = Data()
    private var log: FileHandle?

    private var hostURL: URL {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PortraitHost")
        if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("PortraitHost")
    }

    /// Extra host options, e.g. `defaults write com.danielfung.PortraitDisplay hostArguments -array --width 820 --height 1180`
    private var extraArguments: [String] {
        UserDefaults.standard.stringArray(forKey: "hostArguments") ?? []
    }

    /// Virtual display only while an iPad is connected, like Sidecar. On unless turned off in the menu.
    static var onDemand: Bool {
        get { UserDefaults.standard.object(forKey: "onDemand") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "onDemand") }
    }

    func start() {
        guard process == nil else { return }
        urls = []; viewers = 0; displayOn = false; stats = nil; needsAccessibility = false; lastError = nil
        pending = Data()

        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)   // new log per run
        log = try? FileHandle(forWritingTo: Self.logURL)

        let p = Process()
        p.executableURL = hostURL
        p.arguments = extraArguments + (Self.onDemand ? ["--on-demand"] : []) + ["--status-lines"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }   // EOF
            DispatchQueue.main.async { self?.received(data) }
        }
        p.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { self?.exited(p) }
        }
        do {
            try p.run()
        } catch {
            onFailure?("Couldn't start \(hostURL.path): \(error.localizedDescription)")
            return
        }
        process = p
        state = .starting
        onChange?()
    }

    /// SIGINT: the host's Ctrl+C handler exits cleanly and the virtual display goes away.
    func stop() {
        process?.interrupt()
    }

    /// Stop, then start again with the current settings.
    func restart() {
        guard process != nil else { return }
        restartPending = true
        stop()
    }

    /// For app quit: stop and wait, so the display is gone before the app is.
    func stopAndWait() {
        guard let p = process else { return }
        p.interrupt()
        p.waitUntilExit()
    }

    private func received(_ data: Data) {
        log?.write(data)
        pending.append(data)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        guard line.hasPrefix("@") else { return }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1)
        guard let key = parts.first else { return }
        let value = parts.count > 1 ? String(parts[1]) : ""
        switch key {
        case "url": urls.append(value)
        case "running": state = .running
        case "viewers": viewers = Int(value) ?? 0
        case "display": displayOn = value == "on"
        case "stats": stats = value
        case "needs-accessibility": needsAccessibility = true
        case "error": lastError = value
        default: return
        }
        onChange?()
    }

    private func exited(_ p: Process) {
        guard p === process else { return }
        process = nil
        state = .stopped
        viewers = 0
        displayOn = false
        stats = nil
        try? log?.close()
        log = nil
        onChange?()
        if p.terminationReason == .uncaughtSignal || p.terminationStatus != 0 {
            restartPending = false
            onFailure?(lastError ?? "PortraitHost stopped unexpectedly (status \(p.terminationStatus)).")
        } else if restartPending {
            restartPending = false
            start()
        }
    }
}
