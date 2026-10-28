@testable import PortraitHost
import XCTest

final class ConfigTests: XCTestCase {
    func testDefaultsAreTheIPadPro12_9HomeScreenApp() {
        let c = Config.parse([])
        XCTAssertEqual([c.widthPoints, c.heightPoints, c.fps], [1024, 1334, 60])
        XCTAssertEqual([c.streamWidth, c.streamHeight], [2048, 2668])
        XCTAssertEqual(c.codec, .h264)
        XCTAssertFalse(c.onDemand)
        XCTAssertEqual(c.lingerSeconds, 15)
        XCTAssertTrue(c.usb)
        XCTAssertTrue(c.direct)
    }

    /// What the menu bar app passes; see PortraitMenuTests for how Settings builds it.
    func testMenuBarAppArguments() {
        let c = Config.parse(["--status-lines", "--width", "820", "--height", "1180", "--scale", "1.5",
                              "--codec", "hevc", "--on-demand", "--linger", "120", "--no-direct"])
        XCTAssertEqual([c.widthPoints, c.heightPoints], [820, 1180])
        XCTAssertEqual([c.streamWidth, c.streamHeight], [1230, 1770])
        XCTAssertEqual(c.codec, .hevc)
        XCTAssertTrue(c.statusLines && c.onDemand)
        XCTAssertEqual(c.lingerSeconds, 120)
        XCTAssertFalse(c.direct)
    }

    func testStreamSizeIsAlwaysEven() {
        let c = Config.parse(["--width", "821", "--height", "1181", "--scale", "1.5"])
        XCTAssertEqual(c.streamWidth % 2, 0)
        XCTAssertEqual(c.streamHeight % 2, 0)
    }

    func testLaterOptionsWin() {
        XCTAssertEqual(Config.parse(["--fps", "60", "--fps", "90"]).fps, 90)
    }

    func testPortsFollowTheBasePort() {
        let c = Config.parse(["--port", "9090"])
        XCTAssertEqual([c.httpPort, c.pagePort, c.wsPort], [9090, 9091, 9092])
    }
}

final class HelloTests: XCTestCase {
    func testSafari() throws {
        let hello = try XCTUnwrap(Hello("hello 3f9a1c2b7d4e hevc"))
        XCTAssertEqual(hello.key, "3f9a1c2b7d4e")
        XCTAssertTrue(hello.decodesHEVC)
        XCTAssertNil(hello.size)
    }

    func testAppReportsItsScreenSize() throws {
        let hello = try XCTUnwrap(Hello("hello native size=1024x1366"))
        XCTAssertEqual(hello.key, "native")
        XCTAssertFalse(hello.decodesHEVC)
        XCTAssertEqual(hello.size?.width, 1024)
        XCTAssertEqual(hello.size?.height, 1366)
    }

    func testMalformedSizeIsIgnoredAndOtherMessagesAreNotHellos() {
        XCTAssertNil(Hello("hello native size=1024x")?.size)
        XCTAssertNil(Hello("hello"))
        XCTAssertNil(Hello("ack"))
    }
}

extension HelloTests {
    func testAppReportsWhenItsInstallExpires() {
        XCTAssertEqual(Hello("hello native hevc size=1024x1366 expires=1793000000")?.expires, 1_793_000_000)
        XCTAssertNil(Hello("hello native expires=soon")?.expires)
    }
}
