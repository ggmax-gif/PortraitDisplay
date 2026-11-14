import Foundation

/// The text Copy Diagnostics puts on the clipboard for a bug report: this Mac, the host's state, the
/// last iPad app seen, and recent log lines. The log also holds the Safari link with its private key,
/// so only allowlisted kinds of line go in, and the key is removed wherever it appears.
enum Diagnostics {
    /// Stats, connections, display and encoder changes, sleep and errors: what explained every
    /// performance problem so far.
    static let logLinePrefixes = [
        "Stats (", "iPad connected", "iPad disconnected", "iPad on USB", "Found the iPad",
        "Virtual display", "Encoder:", "Capturing at", "Screen capture", "Screens ", "Mac asleep", "Mac awake",
        "Couldn't", "macOS refused", "@error",
    ]

    static func excerpt(log: String, token: String?, limit: Int = 40) -> [String] {
        let kept = log.split(whereSeparator: \.isNewline).map(String.init)
            .filter { line in logLinePrefixes.contains { line.hasPrefix($0) } }
        return kept.suffix(limit).map { redact($0, token: token) }
    }

    /// Removes the Safari link's key: as a "t=" parameter, and the saved key itself anywhere.
    static func redact(_ line: String, token: String?) -> String {
        var line = line.replacingOccurrences(of: #"([?&#]t=)[A-Za-z0-9]+"#, with: "$1…", options: .regularExpression)
        if let token, token.count >= 8 { line = line.replacingOccurrences(of: token, with: "…") }
        return line
    }

    static func report(facts: [(String, String)], excerpt: [String], generated: Date = Date()) -> String {
        let time = ISO8601DateFormatter.string(from: generated, timeZone: TimeZone(identifier: "UTC")!,
                                               formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
        var lines = ["Portrait Display diagnostics, \(time) UTC", ""]
        lines += facts.map { "\($0.0): \($0.1)" }
        lines += ["", "Recent log (\(excerpt.count) lines, link key removed):", "```"] + excerpt + ["```"]
        return lines.joined(separator: "\n")
    }

    /// This Mac's model identifier, chip, memory and macOS version.
    static func machine() -> [(String, String)] {
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return [
            ("Mac", [sysctl("hw.model"), sysctl("machdep.cpu.brand_string"), "\(memory) GB"].compactMap { $0 }
                .joined(separator: " · ")),
            ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
        ]
    }

    /// The host's saved link key (`TokenStore` in PortraitHost), so it can be removed from the log.
    static func savedToken() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".portraitdisplay-token")
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
