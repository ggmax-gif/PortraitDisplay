import QuartzCore
import UIKit

/// Turns touches on the video into the input messages the Mac's InputInjector replays (format in the
/// header of Sources/PortraitHost/InputInjector.swift), with Mac trackpad gestures on top of the
/// Safari viewer page's rules:
///
/// - The Pencil or a mouse is the pointer: tap clicks, drag drags, with pressure and tilt.
/// - One finger: tap clicks (tap twice to double-click, three times to triple-click), drag scrolls with
///   momentum.
/// - Two fingers: tap right-clicks; drag scrolls; pinch zooms; twist rotates. Which one is decided
///   once per gesture, by whichever movement first passes 10 pt, so a pinch doesn't also scroll.
/// - Three fingers: swipe up for Mission Control, down for App Exposé, left / right to change Space;
///   tap toggles the overlay.
///
/// Positions are sent as fractions (0–1) across the picture.
final class TouchInput {
    var send: ((String) -> Void)?
    var onToggleOverlay: (() -> Void)?
    /// Where the picture is drawn in the view (aspect fit); nil before the first codec config.
    var pictureRect: () -> CGRect? = { nil }

    private static let decideDistance: CGFloat = 10   // points of movement before a gesture is decided
    private static let swipeDistance: CGFloat = 60

    private weak var view: UIView?
    private var fingers: [ObjectIdentifier: CGPoint] = [:]
    private var gesture: Gesture?
    private var momentum: Momentum?
    private var displayLink: CADisplayLink?
    private var pointerDown = false
    private var lastTap: (time: Double, point: CGPoint)?

    private struct Gesture {
        enum Kind { case pending, scroll, zoom, rotate, done }
        var kind = Kind.pending
        var start: CGPoint
        let startTime: Double
        var fingers = 1
        var last: CGPoint
        var samples: [(t: Double, dx: CGFloat, dy: CGFloat)] = []
        // With two fingers down: their distance and angle when the pair formed, and at the last step.
        var pairStart: (distance: CGFloat, angle: CGFloat)?
        var pairLast: (distance: CGFloat, angle: CGFloat)?
    }

    private struct Momentum {
        var vx: CGFloat, vy: CGFloat   // points per millisecond
        var last: Double
        var started = false
    }

    init(view: UIView) {
        self.view = view
        view.isMultipleTouchEnabled = true
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        view.addGestureRecognizer(hover)
    }

    private static var now: Double { CACurrentMediaTime() * 1000 }
    private static func f(_ v: CGFloat) -> String { v.isFinite ? String(format: "%.5f", Double(v)) : "0" }

    private func at(_ p: CGPoint) -> String? {
        guard let r = pictureRect(), r.width > 0, r.height > 0 else { return nil }
        return "\(Self.f((p.x - r.minX) / r.width)) \(Self.f((p.y - r.minY) / r.height))"
    }

    private func delta(_ dx: CGFloat, _ dy: CGFloat) -> String? {
        guard let r = pictureRect(), r.width > 0, r.height > 0 else { return nil }
        return "\(Self.f(dx / r.width)) \(Self.f(dy / r.height))"
    }

    private func centroid() -> CGPoint {
        let n = CGFloat(max(fingers.count, 1))
        let sum = fingers.values.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / n, y: sum.y / n)
    }

    /// Distance between the two fingers and the angle of the line through them, when exactly two are down.
    private func pair() -> (distance: CGFloat, angle: CGFloat)? {
        guard fingers.count == 2 else { return nil }
        let p = Array(fingers.values)
        return (hypot(p[1].x - p[0].x, p[1].y - p[0].y), atan2(p[1].y - p[0].y, p[1].x - p[0].x))
    }

    /// The smallest signed difference between two angles, in radians.
    private static func turn(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
        var d = to - from
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }

    /// Pressure 0–1 and tilt as fractions of 90°, as Pointer Events report them.
    private func pen(_ touch: UITouch, in view: UIView) -> String {
        let pressure = touch.maximumPossibleForce > 0 && touch.type == .pencil ? touch.force / touch.maximumPossibleForce : 0.5
        var tiltX: CGFloat = 0, tiltY: CGFloat = 0
        if touch.type == .pencil {
            let altitude = max(touch.altitudeAngle, 0.0001), azimuth = touch.azimuthAngle(in: view)
            tiltX = atan(cos(azimuth) / tan(altitude)) * 180 / .pi
            tiltY = atan(sin(azimuth) / tan(altitude)) * 180 / .pi
        }
        return "\(Self.f(pressure)) \(Self.f(tiltX / 90)) \(Self.f(tiltY / 90))"
    }

    private func isPointer(_ touch: UITouch) -> Bool { touch.type == .pencil || touch.type == .indirectPointer }

    // MARK: Touches (forwarded by the view)

    func began(_ touches: Set<UITouch>, _ event: UIEvent?) {
        guard let view else { return }
        for touch in touches {
            let p = touch.location(in: view)
            if isPointer(touch) {
                guard let pos = at(p) else { continue }
                let right = event?.buttonMask.contains(.secondary) == true ? 1 : 0
                pointerDown = true
                send?("p d \(pos) \(pen(touch, in: view)) \(right)")
                continue
            }
            stopMomentum()
            fingers[ObjectIdentifier(touch)] = p
            let c = centroid()
            if gesture == nil {
                gesture = Gesture(start: c, startTime: Self.now, last: c)
            } else {
                gesture!.fingers = max(gesture!.fingers, fingers.count)
                gesture!.last = c   // re-anchor so adding a finger doesn't jump the scroll
                if gesture!.kind == .pending { gesture!.start = c }
            }
            if gesture!.kind == .pending, let pair = pair() {
                gesture!.pairStart = pair
                gesture!.pairLast = pair
            }
        }
    }

    func moved(_ touches: Set<UITouch>, _ event: UIEvent?) {
        guard let view else { return }
        var fingerMoved = false
        for touch in touches {
            let p = touch.location(in: view)
            if isPointer(touch) {
                if let pos = at(p) { send?("p m \(pos) \(pen(touch, in: view))") }
                continue
            }
            guard fingers[ObjectIdentifier(touch)] != nil else { continue }
            fingers[ObjectIdentifier(touch)] = p
            fingerMoved = true
        }
        guard fingerMoved, var g = gesture else { return }
        defer { gesture = g }
        let c = centroid()

        switch g.kind {
        case .pending:
            decide(&g, centroid: c)
        case .scroll:
            let dx = c.x - g.last.x, dy = c.y - g.last.y
            g.last = c
            let now = Self.now
            g.samples.append((now, dx, dy))
            g.samples.removeAll { now - $0.t > 100 }
            if let d = delta(dx, dy) { send?("s c \(d)") }
        case .zoom:
            guard let pair = pair(), let last = g.pairLast, last.distance > 0 else { return }
            send?("g z c \(Self.f(pair.distance / last.distance - 1))")
            g.pairLast = pair
        case .rotate:
            guard let pair = pair(), let last = g.pairLast else { return }
            // UIKit's y axis points down, so its angles turn clockwise; AppKit's rotation is counterclockwise.
            send?("g r c \(Self.f(-Self.turn(last.angle, pair.angle) * 180 / .pi))")
            g.pairLast = pair
        case .done:
            break
        }
    }

    /// The first movement past 10 pt picks the gesture: a scroll (the fingers move together), a pinch
    /// (their distance changes) or a rotation (their angle changes); with three fingers, a swipe.
    private func decide(_ g: inout Gesture, centroid c: CGPoint) {
        let move = hypot(c.x - g.start.x, c.y - g.start.y)
        if g.fingers >= 3 {
            guard fingers.count >= 3, move > Self.swipeDistance else { return }
            let dx = c.x - g.start.x, dy = c.y - g.start.y
            send?("w " + (abs(dx) > abs(dy) ? (dx < 0 ? "left" : "right") : (dy < 0 ? "up" : "down")))
            g.kind = .done
            return
        }
        var spread: CGFloat = 0, twist: CGFloat = 0
        if let pair = pair(), let start = g.pairStart {
            spread = abs(pair.distance - start.distance)
            twist = abs(Self.turn(start.angle, pair.angle)) * pair.distance / 2   // arc length each finger moved
        }
        guard max(move, spread, twist) > Self.decideDistance, let pos = at(c) else { return }
        if spread >= move && spread >= twist {
            g.kind = .zoom
            send?("g z b \(pos)")
            if let start = g.pairStart, let pair = pair(), start.distance > 0 {
                send?("g z c \(Self.f(pair.distance / start.distance - 1))")
            }
            g.pairLast = pair()
        } else if twist > move {
            g.kind = .rotate
            send?("g r b \(pos)")
            g.pairLast = pair()
        } else {
            g.kind = .scroll
            if let startPos = at(g.start), let d = delta(c.x - g.last.x, c.y - g.last.y) { send?("s b \(startPos) \(d)") }
            g.last = c
        }
    }

    func ended(_ touches: Set<UITouch>, _ event: UIEvent?, cancelled: Bool) {
        guard let view else { return }
        for touch in touches {
            if isPointer(touch) {
                pointerDown = false
                if let pos = at(touch.location(in: view)) { send?("p u \(pos)") }
                continue
            }
            guard fingers.removeValue(forKey: ObjectIdentifier(touch)) != nil, gesture != nil else { continue }
            // A pinch or rotation ends as soon as one finger lifts, as on a trackpad.
            switch gesture!.kind {
            case .zoom: send?("g z e"); gesture!.kind = .done
            case .rotate: send?("g r e"); gesture!.kind = .done
            default: break
            }
            if !fingers.isEmpty { gesture!.last = centroid(); continue }   // wait for the last finger
            let g = gesture!
            gesture = nil
            if g.kind == .scroll {
                send?("s e")
                let now = Self.now
                let recent = g.samples.filter { now - $0.t < 100 }
                let span = recent.isEmpty ? 0 : now - recent[0].t + 8
                if span > 0, !cancelled {
                    let vx = recent.reduce(0) { $0 + $1.dx } / span, vy = recent.reduce(0) { $0 + $1.dy } / span
                    if hypot(vx, vy) > 0.3 { startMomentum(vx: vx, vy: vy) }
                }
            } else if g.kind == .pending, !cancelled, Self.now - g.startTime < 400 {
                switch g.fingers {
                case 1: tap(at: g.start)
                case 2: if let pos = at(g.start) { send?("c \(pos) 1") }
                default: onToggleOverlay?()
                }
            }
        }
    }

    /// A one-finger tap. The Mac counts a double-click only if both clicks land within 24 pt of each
    /// other, and a fingertip often misses by more, so a tap soon after and near the last one is sent at
    /// exactly the same spot. The Mac then sees a double-click (or triple-click) every time.
    private func tap(at point: CGPoint) {
        var point = point
        let now = Self.now
        if let last = lastTap, now - last.time < 450, hypot(point.x - last.point.x, point.y - last.point.y) < 40 {
            point = last.point
        }
        lastTap = (now, point)
        if let pos = at(point) { send?("c \(pos) 0") }
    }

    /// A mouse or trackpad moving over the picture without a button down.
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard let view, !pointerDown, recognizer.state == .changed || recognizer.state == .began,
              let pos = at(recognizer.location(in: view)) else { return }
        send?("p h \(pos)")
    }

    // MARK: Momentum

    private func startMomentum(vx: CGFloat, vy: CGFloat) {
        momentum = Momentum(vx: vx, vy: vy, last: Self.now)
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func stepMomentum() {
        guard var m = momentum else { return }
        let now = Self.now
        let dt = max(0, min(now - m.last, 50))
        m.last = now
        if let d = delta(m.vx * dt, m.vy * dt) { send?("s \(m.started ? "mc" : "mb") \(d)") }
        m.started = true
        let decay = pow(0.95, dt / 16.7)
        m.vx *= decay
        m.vy *= decay
        momentum = m
        if hypot(m.vx, m.vy) < 0.02 { stopMomentum() }
    }

    private func stopMomentum() {
        displayLink?.invalidate()
        displayLink = nil
        if momentum != nil { send?("s me") }
        momentum = nil
    }
}
