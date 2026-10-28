import Foundation

/// The settings window's values, saved in UserDefaults, and the PortraitHost options they map to.
/// Ranges match `Config.parse` in PortraitHost: an out-of-range value would make the host refuse to start.
enum Settings {
    enum Key {
        static let width = "width", height = "height", hiDPI = "hiDPI", fps = "fps", scale = "scale"
        static let bitrate = "bitrate", codec = "codec", port = "port", input = "input"
        static let onDemand = "onDemand", linger = "linger", startOnLaunch = "startOnLaunch"
        static let matchIPad = "matchIPad"
        /// Not a setting: when the iPad app's install expires, as it last reported.
        static let iPadAppExpires = "iPadAppExpires"
        /// Advanced: extra host options, e.g. `defaults write com.danielfung.PortraitDisplay hostArguments -array --fps 90`.
        static let extraArguments = "hostArguments"
    }

    static let sizeRange = 200...4000
    static let fpsChoices = [30, 60, 120]
    static let lingerChoices = [15, 60, 120, 300, 900]   // seconds; the host accepts 0–3600
    static let bitrateRange = 2.0...40.0
    static let portRange = 1024...65000

    /// Same as the host's own defaults, except on-demand, which the menu bar app turns on, and a
    /// longer grace period: a locked iPad or a quick app switch shouldn't move windows while reading.
    static let defaults: [String: Any] = [
        Key.width: 1024, Key.height: 1334, Key.hiDPI: true, Key.fps: 60, Key.scale: 2.0,
        Key.bitrate: 20.0, Key.codec: "h264", Key.port: 8080, Key.input: true,
        Key.onDemand: true, Key.linger: 120, Key.startOnLaunch: false, Key.matchIPad: true,
    ]

    static func register(_ d: UserDefaults = .standard) {
        d.register(defaults: defaults)
    }

    static func restoreDefaults(_ d: UserDefaults = .standard) {
        for key in defaults.keys { d.removeObject(forKey: key) }
    }

    static var startOnLaunch: Bool { UserDefaults.standard.bool(forKey: Key.startOnLaunch) }

    /// With "Match the iPad app's screen size" on, saves the size the app reported. True if that changed
    /// the size, so the host needs a restart to use it.
    static func adoptIPadSize(width: Int, height: Int, _ d: UserDefaults = .standard) -> Bool {
        guard d.bool(forKey: Key.matchIPad) else { return false }
        let w = min(max(width, sizeRange.lowerBound), sizeRange.upperBound)
        let h = min(max(height, sizeRange.lowerBound), sizeRange.upperBound)
        guard w != d.integer(forKey: Key.width) || h != d.integer(forKey: Key.height) else { return false }
        d.set(w, forKey: Key.width)
        d.set(h, forKey: Key.height)
        return true
    }

    /// Host options for the saved settings, then any extra `hostArguments` (the host lets later options win).
    static func hostArguments(_ d: UserDefaults = .standard) -> [String] {
        func int(_ key: String, _ range: ClosedRange<Int>) -> Int { min(max(d.integer(forKey: key), range.lowerBound), range.upperBound) }
        func double(_ key: String, _ range: ClosedRange<Double>) -> Double {
            min(max(d.double(forKey: key), range.lowerBound), range.upperBound)
        }
        // Stream resolution is relative to the display's pixels, but the host's --scale is stream pixels
        // per point: without Retina (1 px per point) "Full" is 1, not 2.
        let resolution = double(Key.scale, 0.5...2)
        let scale = d.bool(forKey: Key.hiDPI) ? resolution : max(0.5, resolution / 2)
        var args = [
            "--width", String(int(Key.width, sizeRange)),
            "--height", String(int(Key.height, sizeRange)),
            "--fps", String(int(Key.fps, 1...120)),
            "--scale", String(scale),
            "--bitrate", String(double(Key.bitrate, bitrateRange)),
            "--codec", d.string(forKey: Key.codec) == "hevc" ? "hevc" : "h264",
            "--port", String(int(Key.port, portRange)),
        ]
        if !d.bool(forKey: Key.hiDPI) { args.append("--no-hidpi") }
        if !d.bool(forKey: Key.input) { args.append("--no-input") }
        if d.bool(forKey: Key.onDemand) { args += ["--on-demand", "--linger", String(int(Key.linger, 0...3600))] }
        return args + (d.stringArray(forKey: Key.extraArguments) ?? [])
    }
}
