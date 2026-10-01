import AppKit

/// Maps remote buttons and touch gestures to actions for the current mode.
///
/// | Input              | Presenter               | Mouse                 | Media                  |
/// |--------------------|-------------------------|-----------------------|------------------------|
/// | Click surface      | Next (left third: Prev) | Left click / drag     | Play / Pause           |
/// | Swipe left / right | Previous / Next slide   | —  (moves pointer)    | Previous / Next track  |
/// | Swipe up / down    | Up / Down arrow         | —  (right edge scrolls)| Volume up / down      |
/// | Play/Pause         | Play / Pause            | Right click           | Play / Pause           |
/// | Menu               | Esc (hold: next mode)   | Esc (hold: next mode) | Esc (hold: next mode)  |
/// | TV                 | Next mode               | Next mode             | Next mode              |
/// | Volume + / −       | Volume                  | Volume                | Volume                 |
/// | Siri               | Siri / dictation        | Siri / dictation      | Siri / dictation       |
///
/// Keyboard mode shows an on-screen keyboard: slide to move the highlight, click to type it,
/// Play/Pause deletes. Menu, TV, Volume and Siri work as in the other modes.
final class ActionEngine {
    var onModeChange: ((Mode) -> Void)?

    private let touch: TouchSurface
    private let voice = Voice()

    private var longPressTimers: [RemoteButton: Timer] = [:]
    private var longPressFired: Set<RemoteButton> = []
    private var repeatTimer: Timer?

    private var leftButtonDown = false
    private var lastClick: (time: TimeInterval, location: CGPoint, count: Int)?
    private var scrolling = false
    private var remainder = (x: 0.0, y: 0.0)
    /// While the surface is clicked in Keyboard mode, finger movement does not move the highlight.
    private var keyboardClickHeld = false

    init(touch: TouchSurface) {
        self.touch = touch
        touch.onBegan = { [weak self] point in self?.touchBegan(point) }
        touch.onMoved = { [weak self] dx, dy, dt in self?.touchMoved(dx: dx, dy: dy, dt: dt) }
        touch.onEnded = { [weak self] swipe in self?.touchEnded(swipe) }
    }

    var mode: Mode { Settings.shared.mode }

    func setMode(_ mode: Mode, announce: Bool = true) {
        releaseHeldMouse()
        Settings.shared.mode = mode
        mode == .keyboard ? VirtualKeyboard.shared.show() : VirtualKeyboard.shared.hide()
        onModeChange?(mode)
        if announce { HUD.shared.show("\(mode.title) Mode", symbol: mode.symbol) }
    }

    /// The keyboard is only on screen while a remote can drive it.
    func remoteConnectionChanged(_ connected: Bool) {
        connected && mode == .keyboard ? VirtualKeyboard.shared.show() : VirtualKeyboard.shared.hide()
    }

    // MARK: - Buttons

    func button(_ button: RemoteButton, pressed: Bool) {
        switch button {
        case .menu:
            withLongPress(button, pressed: pressed, short: { EventPoster.tap(.escape) },
                          long: { [weak self] in self.map { $0.setMode($0.mode.next) } })
        case .tv:
            if !pressed { setMode(mode.next) }
        case .volumeUp:
            repeating(pressed: pressed) { EventPoster.media(.volumeUp) }
        case .volumeDown:
            repeating(pressed: pressed) { EventPoster.media(.volumeDown) }
        case .siri:
            voice.siriButton(pressed: pressed)
        case .playPause:
            if mode == .mouse {
                EventPoster.mouseButton(.right, down: pressed)
            } else if mode == .keyboard {
                repeating(pressed: pressed) { EventPoster.tap(.delete) }
            } else if pressed {
                EventPoster.media(.playPause)
            }
        case .select:
            select(pressed: pressed)
        }
    }

    private func select(pressed: Bool) {
        if pressed { touch.cancelGesture() }
        switch mode {
        case .presenter:
            guard pressed else { return }
            // Clicking the left third of the surface goes back, anywhere else advances.
            if let x = touch.current?.x, x < 0.33 {
                EventPoster.tap(.left)
            } else {
                EventPoster.tap(.right)
            }
        case .mouse:
            if pressed {
                let now = ProcessInfo.processInfo.systemUptime
                let location = EventPoster.cursor
                var count = 1
                if let last = lastClick, now - last.time < NSEvent.doubleClickInterval,
                   hypot(location.x - last.location.x, location.y - last.location.y) < 6 {
                    count = last.count + 1
                }
                lastClick = (now, location, count)
                leftButtonDown = true
                EventPoster.mouseButton(.left, down: true, clickCount: count)
            } else if leftButtonDown {
                leftButtonDown = false
                EventPoster.mouseButton(.left, down: false, clickCount: lastClick?.count ?? 1)
            }
        case .media:
            if pressed { EventPoster.media(.playPause) }
        case .keyboard:
            keyboardClickHeld = pressed
            if pressed { VirtualKeyboard.shared.pressSelected() }
        }
    }

    private func withLongPress(_ button: RemoteButton, pressed: Bool, short: @escaping () -> Void,
                               long: @escaping () -> Void) {
        if pressed {
            longPressFired.remove(button)
            longPressTimers[button]?.invalidate()
            longPressTimers[button] = Timer.onMainCommon(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
                self?.longPressFired.insert(button)
                long()
            }
        } else {
            longPressTimers.removeValue(forKey: button)?.invalidate()
            if !longPressFired.contains(button) { short() }
            longPressFired.remove(button)
        }
    }

    private func repeating(pressed: Bool, action: @escaping () -> Void) {
        repeatTimer?.invalidate()
        repeatTimer = nil
        guard pressed else { return }
        action()
        repeatTimer = Timer.onMainCommon(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            action()
            self?.repeatTimer = Timer.onMainCommon(withTimeInterval: 0.12, repeats: true) { _ in action() }
        }
    }

    private func releaseHeldMouse() {
        if leftButtonDown {
            leftButtonDown = false
            EventPoster.mouseButton(.left, down: false)
        }
    }

    // MARK: - Touch

    private func touchBegan(_ point: TouchSurface.Point) {
        remainder = (0, 0)
        // In Mouse mode, a touch that starts on the right edge scrolls instead of moving.
        scrolling = mode == .mouse && point.x > 0.85 && !leftButtonDown
        if mode == .keyboard { VirtualKeyboard.shared.touchBegan() }
    }

    private func touchMoved(dx: Double, dy: Double, dt: Double) {
        if mode == .keyboard {
            if !keyboardClickHeld { VirtualKeyboard.shared.touchMoved(dx: dx, dy: dy) }
            return
        }
        guard mode == .mouse else { return }
        if scrolling {
            let lines = dy * 2400 + remainder.y
            let whole = lines.rounded(.towardZero)
            remainder.y = lines - whole
            if whole != 0 { EventPoster.scroll(dx: 0, dy: Int32(whole)) }
            return
        }
        // Pointer acceleration: slow movements are precise, flicks cross the screen.
        let speed = (dx * dx + dy * dy).squareRoot() / dt
        let gain = Settings.shared.pointerSpeed.gain * (1 + min(speed * 0.9, 3.5))
        let px = dx * gain + remainder.x
        let py = dy * gain + remainder.y
        let wx = px.rounded(.towardZero), wy = py.rounded(.towardZero)
        remainder = (px - wx, py - wy)
        if wx != 0 || wy != 0 { EventPoster.moveCursor(dx: wx, dy: wy, dragging: leftButtonDown) }
    }

    private func touchEnded(_ swipe: SwipeDirection?) {
        scrolling = false
        guard let swipe else { return }
        switch (mode, swipe) {
        case (.presenter, .right): EventPoster.tap(.right)
        case (.presenter, .left): EventPoster.tap(.left)
        case (.presenter, .up): EventPoster.tap(.up)
        case (.presenter, .down): EventPoster.tap(.down)
        case (.media, .right): EventPoster.media(.next)
        case (.media, .left): EventPoster.media(.previous)
        case (.media, .up): EventPoster.media(.volumeUp)
        case (.media, .down): EventPoster.media(.volumeDown)
        case (.mouse, _), (.keyboard, _): break
        }
    }
}

extension Timer {
    /// Like `scheduledTimer`, but also fires while a menu is open (event-tracking run loop mode),
    /// so long presses and volume repeat keep working over SiriMouse's own menu.
    @discardableResult
    static func onMainCommon(withTimeInterval interval: TimeInterval, repeats: Bool,
                             block: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
