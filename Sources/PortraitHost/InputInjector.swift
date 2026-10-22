import AppKit
import CoreGraphics

/// Turns touch and Apple Pencil input from the iPad into mouse and scroll events on the virtual
/// display. Positions arrive normalised to 0–1 across the stream, so they survive any scaling.
/// macOS silently drops posted events unless the app running this has Accessibility permission.
///
/// Messages (space-separated, from the viewer page):
///   c x y button            tap: click (button 0 left, 1 right)
///   p d x y pressure tiltX tiltY button   Pencil/mouse down
///   p m x y pressure tiltX tiltY          Pencil/mouse drag
///   p u x y                 Pencil/mouse up
///   p h x y                 Pencil/mouse hover
///   s b x y dx dy | s c dx dy | s e       scroll (finger drag), deltas as fractions of the stream
///   s mb dx dy | s mc dx dy | s me        momentum after the fingers lift
final class InputInjector {
    private let queue = DispatchQueue(label: "portrait.input")
    private let source = CGEventSource(stateID: .hidSystemState)
    // Only touched on `queue`.
    private var penButton: CGMouseButton?
    private var lastClick: (time: TimeInterval, point: CGPoint, button: CGMouseButton, count: Int64)?
    private var scrollRemainder = CGPoint.zero
    private var scrolling = false, coasting = false   // a scroll / momentum phase is open
    private var displayID: CGDirectDisplayID?        // nil while there is no virtual display

    /// The display changes ID every time it is created (--on-demand).
    func setDisplay(_ id: CGDirectDisplayID?) {
        queue.async { self.displayID = id }
    }

    private var bounds: CGRect { displayID.map(CGDisplayBounds) ?? .zero }

    /// True if events will be delivered. Otherwise asks macOS to show the permission prompt.
    static func ensurePermission() -> Bool {
        if CGPreflightPostEventAccess() { return true }
        CGRequestPostEventAccess()
        return false
    }

    func handle(_ message: String) {
        queue.async { self.process(message) }
    }

    /// The iPad went away. If it was mid-drag or mid-scroll, the "up" / "ended" will never come,
    /// and macOS would keep the button held (every later mouse move becomes a drag).
    func release() {
        queue.async {
            if let button = self.penButton {
                self.penButton = nil
                let at = CGEvent(source: nil)?.location ?? .zero
                self.post(self.upType(button), at: at, button: button)
            }
            if self.scrolling { self.scroll(0, 0, phase: .ended) }
            if self.coasting { self.scroll(0, 0, momentum: .end) }
        }
    }

    private func process(_ message: String) {
        let f = message.split(separator: " ").map(String.init)
        // Untrusted input: Double("NaN") parses, and NaN or a huge value would trap when converted to Int32.
        func n(_ i: Int) -> Double {
            guard i < f.count, let v = Double(f[i]), v.isFinite else { return 0 }
            return min(max(v, -100), 100)
        }
        guard f.count >= 2, displayID != nil else { return }

        switch f[0] {
        case "c":
            let at = point(n(1), n(2))
            let button: CGMouseButton = n(3) == 1 ? .right : .left
            post(.mouseMoved, at: at, button: .left)
            let count = clickCount(at: at, button: button)
            post(downType(button), at: at, button: button, clicks: count)
            post(upType(button), at: at, button: button, clicks: count)
        case "p":
            let at = point(n(2), n(3))
            switch f[1] {
            case "d":
                let button: CGMouseButton = n(7) == 1 ? .right : .left
                penButton = button
                post(downType(button), at: at, button: button, clicks: clickCount(at: at, button: button),
                     pen: (n(4), n(5), n(6)))
            case "m":
                guard let button = penButton else { return }
                post(button == .right ? .rightMouseDragged : .leftMouseDragged, at: at, button: button,
                     clicks: lastClick?.count ?? 1, pen: (n(4), n(5), n(6)))
            case "u":
                guard let button = penButton else { return }
                penButton = nil
                post(upType(button), at: at, button: button, clicks: lastClick?.count ?? 1)
            case "h":
                if penButton == nil { post(.mouseMoved, at: at, button: .left) }
            default:
                break
            }
        case "s":
            switch f[1] {
            case "b":
                // Scroll events go to the window under the cursor, so put it under the finger first.
                post(.mouseMoved, at: point(n(2), n(3)), button: .left)
                scrollRemainder = .zero
                scroll(n(4), n(5), phase: .began)
            case "c": scroll(n(2), n(3), phase: .changed)
            case "e": scroll(0, 0, phase: .ended)
            case "mb": scroll(n(2), n(3), momentum: .begin)
            case "mc": scroll(n(2), n(3), momentum: .continuous)
            case "me": scroll(0, 0, momentum: .end)
            default: break
            }
        default:
            break
        }
    }

    // MARK: Helpers

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        let b = bounds
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        return CGPoint(x: min(b.minX + cx * b.width, b.maxX - 1), y: min(b.minY + cy * b.height, b.maxY - 1))
    }

    /// macOS needs the click count on the event itself; double-clicks aren't inferred.
    private func clickCount(at point: CGPoint, button: CGMouseButton) -> Int64 {
        let now = ProcessInfo.processInfo.systemUptime
        var count: Int64 = 1
        if let last = lastClick, last.button == button,
           now - last.time < NSEvent.doubleClickInterval,
           hypot(point.x - last.point.x, point.y - last.point.y) < 8 {
            count = last.count + 1
        }
        lastClick = (now, point, button, count)
        return count
    }

    private func downType(_ button: CGMouseButton) -> CGEventType {
        button == .right ? .rightMouseDown : .leftMouseDown
    }

    private func upType(_ button: CGMouseButton) -> CGEventType {
        button == .right ? .rightMouseUp : .leftMouseUp
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clicks: Int64 = 1,
                      pen: (pressure: Double, tiltX: Double, tiltY: Double)? = nil) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clicks)
        if let pen = pen {
            event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
            event.setDoubleValueField(.mouseEventPressure, value: pen.pressure)
            event.setDoubleValueField(.tabletEventPointPressure, value: pen.pressure)
            event.setDoubleValueField(.tabletEventTiltX, value: pen.tiltX)
            event.setDoubleValueField(.tabletEventTiltY, value: pen.tiltY)
        }
        event.post(tap: .cghidEventTap)
    }

    private func scroll(_ dx: Double, _ dy: Double, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase? = nil) {
        if let phase = phase { scrolling = phase != .ended }
        if let momentum = momentum { coasting = momentum != .end }
        // Deltas arrive as fractions of the stream; convert to points, carrying the sub-point rest.
        let b = bounds
        let x = dx * b.width + scrollRemainder.x, y = dy * b.height + scrollRemainder.y
        let ix = Int32(x.rounded(.towardZero)), iy = Int32(y.rounded(.towardZero))
        scrollRemainder = CGPoint(x: x - Double(ix), y: y - Double(iy))

        // Content follows the finger, as on the iPad: finger down = scroll up = positive wheel1.
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: iy, wheel2: ix, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum?.rawValue ?? 0))
        event.post(tap: .cghidEventTap)
    }
}
