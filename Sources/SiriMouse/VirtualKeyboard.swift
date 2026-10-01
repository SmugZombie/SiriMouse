import AppKit

/// An on-screen keyboard for Keyboard mode. Sliding on the touch surface moves the highlight,
/// clicking types the highlighted key into the frontmost app. The panel never becomes key,
/// so typing goes to whatever app was in front; its keys can also be clicked with a mouse.
final class VirtualKeyboard {
    static let shared = VirtualKeyboard()

    enum Action {
        case character(String, shifted: String)
        case key(EventPoster.Key, label: String)
        case shift
    }

    struct Key {
        let action: Action
        /// Width in key units.
        let width: CGFloat
        var frame = CGRect.zero
    }

    /// Normalized touch travel that moves the highlight by one key.
    private static let step = 0.09
    private static let unit: CGFloat = 46
    private static let gap: CGFloat = 6
    private static let inset: CGFloat = 14

    private(set) var rows: [[Key]] = VirtualKeyboard.layout()
    private(set) var selected = (row: 2, column: 5)  // "g"
    private(set) var shift = false
    private(set) var flashing: (row: Int, column: Int)?

    private let panel: KeyboardPanel
    private let view: KeyboardView
    private var travel = (x: 0.0, y: 0.0)

    var isVisible: Bool { panel.isVisible }

    private init() {
        let width = rows.map { row in row.reduce(0) { $0 + $1.width } }.max()! * Self.unit
        let size = NSSize(width: width + Self.inset * 2, height: CGFloat(rows.count) * Self.unit + Self.inset * 2)
        panel = KeyboardPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true

        view = KeyboardView(frame: background.bounds)
        view.autoresizingMask = [.width, .height]
        background.addSubview(view)
        panel.contentView = background

        layoutKeys()
        view.keyboard = self
    }

    // MARK: Showing

    func show() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            // Sits above the HUD so mode changes stay readable.
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 150))
        }
        travel = (0, 0)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    // MARK: Remote input

    func touchBegan() { travel = (0, 0) }

    /// Moves the highlight one key for every `step` of travel along the dominant axis.
    /// `dy` grows downward, like the screen.
    func touchMoved(dx: Double, dy: Double) {
        travel.x += dx
        travel.y += dy
        while abs(travel.x) >= Self.step || abs(travel.y) >= Self.step {
            if abs(travel.x) >= abs(travel.y) {
                let right = travel.x > 0
                travel.x -= right ? Self.step : -Self.step
                travel.y = 0
                moveHorizontally(right ? 1 : -1)
            } else {
                let down = travel.y > 0
                travel.y -= down ? Self.step : -Self.step
                travel.x = 0
                moveVertically(down ? 1 : -1)
            }
        }
    }

    func pressSelected() { press(row: selected.row, column: selected.column) }

    func select(row: Int, column: Int) {
        selected = (row, column)
        view.needsDisplay = true
    }

    func press(row: Int, column: Int) {
        select(row: row, column: column)
        switch rows[row][column].action {
        case let .character(normal, shifted):
            EventPoster.type(shift ? shifted : normal)
            shift = false
        case let .key(key, _):
            EventPoster.tap(key)
        case .shift:
            shift.toggle()
        }
        flashing = (row, column)
        view.needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.flashing = nil
            self?.view.needsDisplay = true
        }
    }

    func label(for key: Key) -> String {
        switch key.action {
        case let .character(normal, shifted): return shift ? shifted : normal
        case let .key(_, label): return label
        case .shift: return "⇧"
        }
    }

    private func moveHorizontally(_ delta: Int) {
        let column = min(max(selected.column + delta, 0), rows[selected.row].count - 1)
        select(row: selected.row, column: column)
    }

    /// Moves to the key in the next row whose center is closest to the current key's center.
    private func moveVertically(_ delta: Int) {
        let row = selected.row + delta
        guard rows.indices.contains(row) else { return }
        let x = rows[selected.row][selected.column].frame.midX
        let column = rows[row].indices.min { abs(rows[row][$0].frame.midX - x) < abs(rows[row][$1].frame.midX - x) }!
        select(row: row, column: column)
    }

    // MARK: Layout

    private func layoutKeys() {
        let height = CGFloat(rows.count) * Self.unit
        for r in rows.indices {
            var x = Self.inset
            let y = Self.inset + height - CGFloat(r + 1) * Self.unit
            for c in rows[r].indices {
                let width = rows[r][c].width * Self.unit
                rows[r][c].frame = CGRect(x: x, y: y, width: width, height: Self.unit)
                    .insetBy(dx: Self.gap / 2, dy: Self.gap / 2)
                x += width
            }
        }
    }

    private static func layout() -> [[Key]] {
        func chars(_ normal: String, _ shifted: String) -> [Key] {
            zip(normal, shifted).map { Key(action: .character(String($0), shifted: String($1)), width: 1) }
        }
        func special(_ key: EventPoster.Key, _ label: String, _ width: CGFloat = 1) -> Key {
            Key(action: .key(key, label: label), width: width)
        }
        let shift = Key(action: .shift, width: 2.25)
        return [
            chars("`1234567890-=", "~!@#$%^&*()_+") + [special(.delete, "⌫", 1.5)],
            [special(.tab, "⇥", 1.5)] + chars("qwertyuiop[]\\", "QWERTYUIOP{}|"),
            [special(.escape, "esc", 1.75)] + chars("asdfghjkl;'", "ASDFGHJKL:\"") + [special(.returnKey, "⏎", 1.75)],
            [shift] + chars("zxcvbnm,./", "ZXCVBNM<>?") + [shift],
            [special(.space, "space", 10.5), special(.left, "←"), special(.up, "↑"), special(.down, "↓"),
             special(.right, "→")],
        ]
    }
}

private final class KeyboardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class KeyboardView: NSView {
    weak var keyboard: VirtualKeyboard?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let keyboard else { return }
        let point = convert(event.locationInWindow, from: nil)
        for (r, row) in keyboard.rows.enumerated() {
            if let c = row.firstIndex(where: { $0.frame.contains(point) }) {
                keyboard.press(row: r, column: c)
                return
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let keyboard else { return }
        for (r, row) in keyboard.rows.enumerated() {
            for (c, key) in row.enumerated() {
                let isSelected = keyboard.selected == (r, c)
                let isFlashing = keyboard.flashing.map { $0 == (r, c) } ?? false
                let isShiftOn = keyboard.shift && { if case .shift = key.action { return true }; return false }()

                let fill: NSColor
                if isFlashing {
                    fill = .controlAccentColor.blended(withFraction: 0.35, of: .white) ?? .controlAccentColor
                } else if isSelected {
                    fill = .controlAccentColor
                } else if isShiftOn {
                    fill = .controlAccentColor.withAlphaComponent(0.35)
                } else {
                    fill = .labelColor.withAlphaComponent(0.12)
                }
                fill.setFill()
                NSBezierPath(roundedRect: key.frame, xRadius: 7, yRadius: 7).fill()

                let text = keyboard.label(for: key)
                let font = NSFont.systemFont(ofSize: text.count > 1 ? 14 : 19, weight: .medium)
                let color: NSColor = isSelected || isFlashing ? .white : .labelColor
                let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                let size = string.size()
                string.draw(at: NSPoint(x: key.frame.midX - size.width / 2, y: key.frame.midY - size.height / 2))
            }
        }
    }
}
