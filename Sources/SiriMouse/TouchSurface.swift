import CMultitouch
import Foundation

enum SwipeDirection: String {
    case left, right, up, down
}

/// Turns raw touch-surface frames into touch begin / move / end events and swipe gestures.
/// Coordinates are normalized 0...1 with the origin at the bottom-left of the surface.
final class TouchSurface {
    struct Point { var x: Double; var y: Double }

    var onBegan: ((Point) -> Void)?
    /// Delta in normalized units (y grows downward, like the screen) and seconds since last frame.
    var onMoved: ((_ dx: Double, _ dy: Double, _ dt: Double) -> Void)?
    var onEnded: ((SwipeDirection?) -> Void)?

    private(set) var attachedSurfaces = 0
    /// Where the finger is now, or nil when nothing is touching.
    private(set) var current: Point?

    private var start: Point?
    private var startTime: Double = 0
    private var lastTime: Double = 0
    /// Set when the surface is clicked during a touch, so the click is not also read as a swipe.
    private var suppressGesture = false

    private static weak var shared: TouchSurface?

    @discardableResult
    func attach() -> Int {
        TouchSurface.shared = self
        let count = Int(sm_touch_start { _, count, x, y, timestamp in
            DispatchQueue.main.async {
                TouchSurface.shared?.frame(count: Int(count), x: Double(x), y: Double(y), time: timestamp)
            }
        })
        attachedSurfaces = max(count, 0)
        Log.info(count < 0 ? "MultitouchSupport unavailable" : "Attached to \(count) remote touch surface(s)")
        return count
    }

    func detach() {
        sm_touch_stop()
        attachedSurfaces = 0
        if current != nil { finish(gesture: false) }
    }

    func cancelGesture() { suppressGesture = true }

    private func frame(count: Int, x: Double, y: Double, time: Double) {
        guard count > 0 else {
            if current != nil { finish(gesture: true, time: time) }
            return
        }
        let point = Point(x: x, y: y)
        guard let previous = current else {
            current = point
            start = point
            startTime = time
            lastTime = time
            suppressGesture = false
            onBegan?(point)
            return
        }
        let dt = max(time - lastTime, 0.001)
        current = point
        lastTime = time
        onMoved?(point.x - previous.x, previous.y - point.y, dt)
    }

    private func finish(gesture: Bool, time: Double = 0) {
        defer { current = nil; start = nil }
        guard gesture, !suppressGesture, let start, let end = current else {
            onEnded?(nil)
            return
        }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let duration = time - startTime
        let distance = (dx * dx + dy * dy).squareRoot()
        var swipe: SwipeDirection?
        if duration < 0.6, distance > 0.22 {
            if abs(dx) > abs(dy) * 1.3 {
                swipe = dx > 0 ? .right : .left
            } else if abs(dy) > abs(dx) * 1.3 {
                swipe = dy > 0 ? .up : .down
            }
        }
        Log.debug("Touch ended dx=\(dx) dy=\(dy) t=\(duration) swipe=\(swipe?.rawValue ?? "-")")
        onEnded?(swipe)
    }
}
