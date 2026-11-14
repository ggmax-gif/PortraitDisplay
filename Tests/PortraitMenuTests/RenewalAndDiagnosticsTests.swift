@testable import PortraitMenu
import XCTest

final class RenewalReminderTests: XCTestCase {
    private let expires = Date(timeIntervalSince1970: 1_794_427_005)   // an install's expiry, 11 Nov 2026

    func testRemindsADayBefore() {
        let twoDaysBefore = expires.addingTimeInterval(-2 * 86_400)
        XCTAssertEqual(RenewalReminder.plan(expires: expires, now: twoDaysBefore, reminded: nil),
                       .at(expires.addingTimeInterval(-86_400)))
    }

    func testInsideTheLastDayOrAfterItRemindsAtOnce() {
        XCTAssertEqual(RenewalReminder.plan(expires: expires, now: expires.addingTimeInterval(-3600), reminded: nil),
                       .now(expired: false))
        XCTAssertEqual(RenewalReminder.plan(expires: expires, now: expires.addingTimeInterval(60), reminded: nil),
                       .now(expired: true))
    }

    func testOncePerExpiryDateAndAgainAfterRenewing() {
        let now = expires.addingTimeInterval(-3600)
        XCTAssertEqual(RenewalReminder.plan(expires: expires, now: now, reminded: expires), .none)
        let renewed = expires.addingTimeInterval(7 * 86_400)
        XCTAssertEqual(RenewalReminder.plan(expires: renewed, now: now, reminded: expires),
                       .at(renewed.addingTimeInterval(-86_400)))
    }
}

final class DiagnosticsTests: XCTestCase {
    private let token = "0123456789ab"
    private let log = """
        ────────────────────────────────────────────────────────
         Portrait display is running. On the iPad, open Safari and go to:
           http://192.168.1.23:8080/?t=0123456789ab    [en0]
        @url http://192.168.1.23:8080/#t=0123456789ab
        Couldn't open http://192.168.1.23:8080/#t=feedfacefeed
        iPad connected (USB, iPad8,12, iPadOS 27.2, decodes HEVC). Viewers: 1
        Virtual display "Portrait iPad": 1024×1366 (Retina, 2048×2732 px) @ 60 Hz
        Stats (USB): Mac: captured 30/s, encoded 30/s (H.264) in 11 ms · sent 30/s, round trip 3 ms (max 6)
        Couldn't listen on port 8080 (key 0123456789ab echoed by mistake, https://x/?t=abcdef123456)
        """

    func testOnlyAllowlistedLinesAndNeverTheKey() {
        let lines = Diagnostics.excerpt(log: log, token: token)
        XCTAssertEqual(lines.count, 5)
        XCTAssertFalse(lines.joined().contains("feedfacefeed"))
        XCTAssertEqual(lines[0], "Couldn't open http://192.168.1.23:8080/#t=…")
        XCTAssertTrue(lines[1].hasPrefix("iPad connected (USB, iPad8,12"))
        for line in lines {
            XCTAssertFalse(line.contains(token), line)
            XCTAssertFalse(line.contains("t=abcdef123456"), line)
        }
        XCTAssertFalse(Diagnostics.report(facts: [("Mac", "test")], excerpt: lines).contains(token))
    }

    func testKeepsTheMostRecentLines() {
        let many = (1...60).map { "Stats (USB): line \($0)" }.joined(separator: "\n")
        let lines = Diagnostics.excerpt(log: many, token: nil, limit: 40)
        XCTAssertEqual(lines.count, 40)
        XCTAssertEqual(lines.last, "Stats (USB): line 60")
    }
}
