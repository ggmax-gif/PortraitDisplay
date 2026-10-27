import Foundation

/// Runs PortraitHost (in the bundle's Helpers, or next to this executable in .build) with --status-lines and follows its "@key value"
/// lines. All output also goes to ~/Library/Logs/PortraitDisplay.log. Everything here is on the main thread.
final class HostProcess {
    enum State { case stopped, starting, running }

    private(set) var state = State.stopped
    private(set) var urls: [String] = []
    private(set) var viewers = 0
    private(set) var links: [String] = []   // how each connected iPad is connected: "USB", "Wi-Fi"
    private(set) var displayOn = false
    private(set) var stats: String?
    private(set) var needsAccessibility = false
    /// The options this run was started with (from `Settings`), nil while stopped.
    private(set) var runningArguments: [String]?
    private var lastError: String?

    var onChange: (() -> Void)?
    /// The host quit by itself with an error. The message is its last "@error" line, if any.
    var onFailure: ((String) -> Void)?

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PortraitDisplay.log")

    private var process: Process?
    private var restartPending = false
    private var interrupted = false   // we sent SIGINT, so dying of it is a normal stop
    private var quitting = false
    private var pending = Data()
    private var log: FileHandle?

    private var hostURL: URL {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PortraitHost")
        if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("PortraitHost")
    }

    /// Whether this run removes the display when no iPad is connected.
    var onDemand: Bool { runningArguments?.contains("--on-demand") ?? false }

    func start() {
        guard process == nil else { return }
        urls = []; viewers = 0; links = []; displayOn = false; stats = nil; needsAccessibility = false; lastError = nil
        interrupted = false
        pending = Data()

        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)   // new log per run
        log = try? FileHandle(forWritingTo: Self.logURL)

        let arguments = Settings.hostArguments
        let p = Process()
        p.executableURL = hostURL
        p.arguments = ["--status-lines"] + arguments   // first, so even a bad option gets an "@error" line
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
        runningArguments = arguments
        state = .starting
        onChange?()
    }

    /// SIGINT: the host's Ctrl+C handler exits cleanly and the virtual display goes away.
    func stop() {
        guard let p = process else { return }
        interrupted = true
        p.interrupt()
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
        quitting = true
        interrupted = true
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
        case "viewers":
            viewers = Int(value) ?? 0
            if viewers == 0 { stats = nil }   // the host only sends stats while frames flow to an iPad
        case "display": displayOn = value == "on"
        case "links": links = value.isEmpty ? [] : value.split(separator: ",").map(String.init)
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
        runningArguments = nil
        state = .stopped
        viewers = 0
        links = []
        displayOn = false
        stats = nil
        try? log?.close()
        log = nil
        onChange?()
        if quitting { return }   // no alert or restart while the app quits
        // SIGINT can arrive before the host has set up its handler; that is still the stop we asked for.
        let stoppedByUs = interrupted && p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGINT
        if !stoppedByUs && (p.terminationReason == .uncaughtSignal || p.terminationStatus != 0) {
            restartPending = false
            onFailure?(lastError ?? "PortraitHost stopped unexpectedly (status \(p.terminationStatus)).")
        } else if restartPending {
            restartPending = false
            start()
        }
    }
}
