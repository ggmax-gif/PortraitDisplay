@testable import PortraitMenu
import XCTest

/// Settings → host options. Every list here is one the host's parser accepts (ranges match
/// Config.parse), which an earlier manual check ran through the real binary.
final class SettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "PortraitMenuTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        Settings.register(defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func value(after option: String) -> String? {
        let args = Settings.hostArguments(defaults)
        guard let i = args.lastIndex(of: option), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func testDefaults() {
        XCTAssertEqual(Settings.hostArguments(defaults), [
            "--width", "1024", "--height", "1334", "--fps", "60", "--scale", "2.0", "--bitrate", "20.0",
            "--codec", "h264", "--port", "8080", "--on-demand", "--linger", "120",
        ])
    }

    func testRetinaOffHalvesTheScaleSoFullMeansTheDisplaysOwnPixels() {
        defaults.set(false, forKey: Settings.Key.hiDPI)
        XCTAssertEqual(value(after: "--scale"), "1.0")
        XCTAssertTrue(Settings.hostArguments(defaults).contains("--no-hidpi"))
        defaults.set(1.0, forKey: Settings.Key.scale)
        XCTAssertEqual(value(after: "--scale"), "0.5")
    }

    func testOutOfRangeAndWrongTypesAreClamped() {
        defaults.set(5, forKey: Settings.Key.width)
        defaults.set(99_999, forKey: Settings.Key.height)
        defaults.set("fast", forKey: Settings.Key.bitrate)
        defaults.set(80, forKey: Settings.Key.port)
        defaults.set("vp9", forKey: Settings.Key.codec)
        XCTAssertEqual(value(after: "--width"), "200")
        XCTAssertEqual(value(after: "--height"), "4000")
        XCTAssertEqual(value(after: "--bitrate"), "2.0")
        XCTAssertEqual(value(after: "--port"), "1024")
        XCTAssertEqual(value(after: "--codec"), "h264")
    }

    func testOnDemandOffDropsTheGracePeriod() {
        defaults.set(false, forKey: Settings.Key.onDemand)
        XCTAssertFalse(Settings.hostArguments(defaults).contains("--on-demand"))
        XCTAssertNil(value(after: "--linger"))
    }

    func testExtraArgumentsComeLastSoTheyWin() {
        defaults.set(["--fps", "90"], forKey: Settings.Key.extraArguments)
        XCTAssertEqual(Array(Settings.hostArguments(defaults).suffix(2)), ["--fps", "90"])
    }

    func testIPadSizeIsAdoptedOnceAndOnlyWhenMatchingIsOn() {
        XCTAssertTrue(Settings.adoptIPadSize(width: 1024, height: 1366, defaults))
        XCTAssertEqual(value(after: "--height"), "1366")
        XCTAssertFalse(Settings.adoptIPadSize(width: 1024, height: 1366, defaults), "same size: no restart")
        defaults.set(false, forKey: Settings.Key.matchIPad)
        XCTAssertFalse(Settings.adoptIPadSize(width: 744, height: 1133, defaults))
        XCTAssertEqual(value(after: "--width"), "1024")
    }

    func testRestoreDefaultsUndoesChanges() {
        defaults.set(800, forKey: Settings.Key.width)
        Settings.restoreDefaults(defaults)
        XCTAssertEqual(value(after: "--width"), "1024")
    }
}
