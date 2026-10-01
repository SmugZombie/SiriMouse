import AppKit
import CoreGraphics

/// Posts keyboard, mouse, scroll and media-key events into the session.
/// Requires the Accessibility permission.
enum EventPoster {
    /// Tag on every event this app posts, so the media-key guard never swallows our own keys.
    static let marker: Int64 = 0x5349_524D_4F55

    enum Key: CGKeyCode {
        case left = 123, right = 124, down = 125, up = 126
        case escape = 53, space = 49, b = 11, returnKey = 36, delete = 51, tab = 48
    }

    /// NX_KEYTYPE_* values from IOKit/hidsystem/ev_keymap.h.
    enum MediaKey: Int {
        case volumeUp = 0, volumeDown = 1, mute = 7, playPause = 16, next = 17, previous = 18
    }

    private static let source = CGEventSource(stateID: .hidSystemState)

    private static func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    static func tap(_ key: Key, flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: down)
            event?.flags = flags
            post(event)
        }
    }

    static func type(_ text: String) {
        let units = Array(text.utf16)
        // Unicode keyboard events carry at most ~20 UTF-16 units each.
        for start in stride(from: 0, to: units.count, by: 20) {
            let chunk = Array(units[start..<min(start + 20, units.count)])
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(event)
            }
        }
    }

    static func media(_ key: MediaKey) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (key.rawValue << 16) | ((down ? 0xA : 0xB) << 8)
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: 8, data1: data1, data2: -1)
            post(event?.cgEvent)
        }
    }

    // MARK: Mouse

    static var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func moveCursor(dx: Double, dy: Double, dragging: Bool) {
        let target = clampToDisplays(CGPoint(x: cursor.x + dx, y: cursor.y + dy), from: cursor)
        let event = CGEvent(mouseEventSource: source, mouseType: dragging ? .leftMouseDragged : .mouseMoved,
                            mouseCursorPosition: target, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        post(event)
    }

    static func mouseButton(_ button: CGMouseButton, down: Bool, clickCount: Int = 1) {
        let type: CGEventType
        switch (button, down) {
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        case (_, true): type = .leftMouseDown
        case (_, false): type = .leftMouseUp
        }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: cursor, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        post(event)
    }

    static func scroll(dx: Int32, dy: Int32) {
        post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
    }

    /// Keeps the cursor on a display; when it leaves every display, it stays on the one it was on.
    private static func clampToDisplays(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        let bounds = displays.map { CGDisplayBounds($0) }
        if bounds.contains(where: { $0.contains(point) }) { return point }
        guard let home = bounds.first(where: { $0.contains(origin) }) ?? bounds.first else { return point }
        return CGPoint(x: min(max(point.x, home.minX), home.maxX - 1),
                       y: min(max(point.y, home.minY), home.maxY - 1))
    }
}
