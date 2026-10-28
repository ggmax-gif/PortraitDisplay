import CoreGraphics
import Foundation

/// The iPad app's gesture decisions, kept free of UIKit so they can be tested on the Mac.
public enum Gestures {
    /// Points of movement before a gesture is decided.
    public static let decideDistance: CGFloat = 10
    /// Points a three-finger swipe has to travel.
    public static let swipeDistance: CGFloat = 60

    public enum Swipe: String { case up, down, left, right }

    public enum Decision: Equatable {
        case undecided, scroll, zoom, rotate
        case swipe(Swipe)
    }

    /// Two fingers' distance and the angle (radians) of the line through them.
    public struct Pair: Equatable {
        public let distance: CGFloat
        public let angle: CGFloat
        public init(distance: CGFloat, angle: CGFloat) { self.distance = distance; self.angle = angle }
        public init(_ a: CGPoint, _ b: CGPoint) {
            self.init(distance: hypot(b.x - a.x, b.y - a.y), angle: atan2(b.y - a.y, b.x - a.x))
        }
    }

    /// Picks the gesture from the first movement past `decideDistance`: a scroll when the fingers
    /// move together, a pinch when their distance changes, a rotation when their angle changes.
    /// With three fingers (`fingers` is the most seen so far), a swipe once the centroid has moved
    /// `swipeDistance`.
    public static func decide(fingers: Int, fingersDown: Int, start: CGPoint, centroid: CGPoint,
                              pairStart: Pair?, pair: Pair?) -> Decision {
        let dx = centroid.x - start.x, dy = centroid.y - start.y
        let move = hypot(dx, dy)
        if fingers >= 3 {
            guard fingersDown >= 3, move > swipeDistance else { return .undecided }
            return .swipe(abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down))
        }
        var spread: CGFloat = 0, twist: CGFloat = 0
        if let pair, let pairStart {
            spread = abs(pair.distance - pairStart.distance)
            twist = abs(turn(from: pairStart.angle, to: pair.angle)) * pair.distance / 2   // arc each finger moved
        }
        guard max(move, spread, twist) > decideDistance else { return .undecided }
        if spread >= move && spread >= twist { return .zoom }
        return twist > move ? .rotate : .scroll
    }

    /// The smallest signed difference between two angles, in radians.
    public static func turn(from: CGFloat, to: CGFloat) -> CGFloat {
        var d = to - from
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }

    /// Apple Pencil tilt (altitude above the screen and azimuth, in radians) as Pointer Events'
    /// tiltX / tiltY, as fractions of 90°: what the Safari page sends for the same Pencil.
    public static func tilt(altitude: CGFloat, azimuth: CGFloat) -> (x: CGFloat, y: CGFloat) {
        let a = max(altitude, 0.0001)
        return (atan(cos(azimuth) / tan(a)) * 2 / .pi, atan(sin(azimuth) / tan(a)) * 2 / .pi)
    }
}

/// Makes double and triple taps reliable. The Mac counts a double-click only if both clicks land
/// within 24 pt of each other, and a fingertip often misses by more, so a tap soon after and near
/// the previous one is moved to exactly the same spot.
public struct TapSnapper {
    public static let window: Double = 450     // milliseconds
    public static let radius: CGFloat = 40     // points
    private var last: (time: Double, point: CGPoint)?

    public init() {}

    /// Where to send a tap made at `point` at `time` (milliseconds).
    public mutating func place(_ point: CGPoint, at time: Double) -> CGPoint {
        var point = point
        if let last, time - last.time < Self.window, hypot(point.x - last.point.x, point.y - last.point.y) < Self.radius {
            point = last.point
        }
        last = (time, point)
        return point
    }
}
