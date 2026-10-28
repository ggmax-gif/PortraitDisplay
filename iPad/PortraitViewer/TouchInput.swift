import QuartzCore
import Shared
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

    private weak var view: UIView?
    private var fingers: [ObjectIdentifier: CGPoint] = [:]
    private var gesture: Gesture?
    private var momentum: Momentum?
    private var displayLink: CADisplayLink?
    private var pointerDown = false
    private var taps = TapSnapper()

    private struct Gesture {
        enum Kind { case pending, scroll, zoom, rotate, done }
        var kind = Kind.pending
        var start: CGPoint
        let startTime: Double
        var fingers = 1
        var last: CGPoint
        var samples: [(t: Double, dx: CGFloat, dy: CGFloat)] = []
        // With two fingers down: their distance and angle when the pair formed, and at the last step.
        var pairStart: Gestures.Pair?
        var pairLast: Gestures.Pair?
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
    private func pair() -> Gestures.Pair? {
        guard fingers.count == 2 else { return nil }
        let p = Array(fingers.values)
        return Gestures.Pair(p[0], p[1])
    }

    /// Pressure 0–1 and tilt as fractions of 90°, as Pointer Events report them.
    private func pen(_ touch: UITouch, in view: UIView) -> String {
        let pressure = touch.maximumPossibleForce > 0 && touch.type == .pencil ? touch.force / touch.maximumPossibleForce : 0.5
        let tilt = touch.type == .pencil ? Gestures.tilt(altitude: touch.altitudeAngle, azimuth: touch.azimuthAngle(in: view)) : (x: 0, y: 0)
        return "\(Self.f(pressure)) \(Self.f(tilt.x)) \(Self.f(tilt.y))"
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
            send?("g r c \(Self.f(-Gestures.turn(from: last.angle, to: pair.angle) * 180 / .pi))")
            g.pairLast = pair
        case .done:
            break
        }
    }

    /// Asks Gestures.decide which gesture the movement so far is, and starts it.
    private func decide(_ g: inout Gesture, centroid c: CGPoint) {
        let decision = Gestures.decide(fingers: g.fingers, fingersDown: fingers.count, start: g.start, centroid: c,
                                       pairStart: g.pairStart, pair: pair())
        guard decision != .undecided, let pos = at(c) else { return }
        switch decision {
        case .swipe(let direction):
            send?("w \(direction.rawValue)")
            g.kind = .done
        case .zoom:
            g.kind = .zoom
            send?("g z b \(pos)")
            if let start = g.pairStart, let pair = pair(), start.distance > 0 {
                send?("g z c \(Self.f(pair.distance / start.distance - 1))")
            }
            g.pairLast = pair()
        case .rotate:
            g.kind = .rotate
            send?("g r b \(pos)")
            g.pairLast = pair()
        case .scroll:
            g.kind = .scroll
            if let startPos = at(g.start), let d = delta(c.x - g.last.x, c.y - g.last.y) { send?("s b \(startPos) \(d)") }
            g.last = c
        case .undecided:
            break
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

    /// A one-finger tap; TapSnapper keeps double and triple taps on the same spot.
    private func tap(at point: CGPoint) {
        if let pos = at(taps.place(point, at: Self.now)) { send?("c \(pos) 0") }
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
