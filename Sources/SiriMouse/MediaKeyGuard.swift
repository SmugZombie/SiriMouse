import AppKit
import CoreGraphics

/// When a remote interface cannot be seized, macOS also turns its Play/Pause and volume presses
/// into system media keys, which would double every action. This event tap drops media-key
/// events that arrive right after a remote button edge, unless this app posted them.
final class MediaKeyGuard {
    private var tap: CFMachPort?
    private var lastRemoteEdge: TimeInterval = 0
    private let window: TimeInterval = 0.35

    func noteRemoteButton() { lastRemoteEdge = ProcessInfo.processInfo.systemUptime }

    @discardableResult
    func start() -> Bool {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let guardian = Unmanaged<MediaKeyGuard>.fromOpaque(refcon).takeUnretainedValue()
            return guardian.filter(type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.info("Media-key guard unavailable (needs Accessibility)")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("Media-key guard installed")
        return true
    }

    private func filter(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != EventPoster.marker,
              ProcessInfo.processInfo.systemUptime - lastRemoteEdge < window,
              let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let key = (ns.data1 & 0xFFFF_0000) >> 16
        let handled: Set<Int> = [0, 1, 7, 16, 17, 18, 19, 20]
        guard handled.contains(key) else { return Unmanaged.passUnretained(event) }
        Log.debug("Suppressed native media key \(key) from remote")
        return nil
    }
}
