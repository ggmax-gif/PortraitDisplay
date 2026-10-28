import CoreGraphics
import Shared
import XCTest

final class GesturesTests: XCTestCase {
    private let origin = CGPoint(x: 500, y: 500)

    private func decide(fingers: Int = 2, move: CGVector = .zero, from start: Gestures.Pair? = nil,
                        to now: Gestures.Pair? = nil) -> Gestures.Decision {
        Gestures.decide(fingers: fingers, fingersDown: fingers, start: origin,
                        centroid: CGPoint(x: origin.x + move.dx, y: origin.y + move.dy), pairStart: start, pair: now)
    }

    func testSmallMovementsStayUndecided() {
        XCTAssertEqual(decide(fingers: 1, move: CGVector(dx: 6, dy: 6)), .undecided)   // 8.5 pt
    }

    func testOneFingerDragScrolls() {
        XCTAssertEqual(decide(fingers: 1, move: CGVector(dx: 0, dy: 12)), .scroll)
    }

    func testTwoFingersMovingTogetherScroll() {
        let pair = Gestures.Pair(distance: 120, angle: 0)
        XCTAssertEqual(decide(move: CGVector(dx: 0, dy: -30), from: pair, to: pair), .scroll)
    }

    func testFingersSpreadingApartZoom() {
        XCTAssertEqual(decide(move: CGVector(dx: 2, dy: 2), from: Gestures.Pair(distance: 120, angle: 0),
                              to: Gestures.Pair(distance: 150, angle: 0)), .zoom)
    }

    func testFingersTwistingRotate() {
        // 20° at 120 pt apart: each finger moves about 21 pt along the arc, more than the centroid.
        XCTAssertEqual(decide(move: CGVector(dx: 1, dy: 0), from: Gestures.Pair(distance: 120, angle: 0),
                              to: Gestures.Pair(distance: 121, angle: 20 * .pi / 180)), .rotate)
    }

    func testThreeFingerSwipesNeedSixtyPointsAndPickTheMainAxis() {
        XCTAssertEqual(decide(fingers: 3, move: CGVector(dx: 0, dy: -50)), .undecided)
        XCTAssertEqual(decide(fingers: 3, move: CGVector(dx: 10, dy: -70)), .swipe(.up))
        XCTAssertEqual(decide(fingers: 3, move: CGVector(dx: 0, dy: 70)), .swipe(.down))
        XCTAssertEqual(decide(fingers: 3, move: CGVector(dx: -80, dy: 20)), .swipe(.left))
        XCTAssertEqual(decide(fingers: 3, move: CGVector(dx: 80, dy: 0)), .swipe(.right))
    }

    func testAThreeFingerGestureWithAFingerLiftedDoesNotSwipe() {
        let decision = Gestures.decide(fingers: 3, fingersDown: 2, start: origin, centroid: CGPoint(x: 500, y: 400),
                                       pairStart: nil, pair: nil)
        XCTAssertEqual(decision, .undecided)
    }

    func testTurnTakesTheShortWayRound() {
        XCTAssertEqual(Gestures.turn(from: 170 * .pi / 180, to: -170 * .pi / 180), 20 * .pi / 180, accuracy: 1e-9)
        XCTAssertEqual(Gestures.turn(from: -170 * .pi / 180, to: 170 * .pi / 180), -20 * .pi / 180, accuracy: 1e-9)
    }

    func testPencilTiltMatchesPointerEvents() {
        let upright = Gestures.tilt(altitude: .pi / 2, azimuth: 0)
        XCTAssertEqual(upright.x, 0, accuracy: 1e-6)
        XCTAssertEqual(upright.y, 0, accuracy: 1e-6)
        // Leaning 45° towards +x: tiltX is 45°, half of 90°.
        let leaning = Gestures.tilt(altitude: .pi / 4, azimuth: 0)
        XCTAssertEqual(leaning.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(leaning.y, 0, accuracy: 1e-6)
    }
}

final class TapSnapperTests: XCTestCase {
    func testASecondTapCloseInTimeAndPlaceLandsOnTheFirst() {
        var taps = TapSnapper()
        let first = taps.place(CGPoint(x: 100, y: 100), at: 0)
        XCTAssertEqual(taps.place(CGPoint(x: 125, y: 110), at: 300), first)
        XCTAssertEqual(taps.place(CGPoint(x: 90, y: 95), at: 600), first)   // a triple tap stays put too
    }

    func testTapsTooFarApartOrTooLateStayWhereTheyAre() {
        var taps = TapSnapper()
        _ = taps.place(CGPoint(x: 100, y: 100), at: 0)
        XCTAssertEqual(taps.place(CGPoint(x: 150, y: 100), at: 200), CGPoint(x: 150, y: 100))   // 50 pt away
        XCTAssertEqual(taps.place(CGPoint(x: 150, y: 100), at: 700), CGPoint(x: 150, y: 100))   // 500 ms later
    }
}
