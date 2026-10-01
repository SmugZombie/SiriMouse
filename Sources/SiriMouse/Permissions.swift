import ApplicationServices
import IOKit.hid

enum Permissions {
    /// Needed to post keyboard / mouse events and to install the media-key guard.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Needed to read (and seize) the remote's HID interfaces.
    static var inputMonitoring: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
