import Foundation
import IOKit
import IOKit.hid

enum RemoteButton: String {
    case menu, tv, select, playPause, volumeUp, volumeDown, siri
}

/// Reads the Siri Remote's buttons through IOHIDManager.
///
/// macOS splits one Bluetooth remote into several HID interfaces (one per top-level collection),
/// and a press can be mirrored on more than one of them, so button edges are de-duplicated here.
/// Interfaces are seized when possible so macOS does not also act on the press.
final class HIDRemote {
    var onButton: ((RemoteButton, Bool) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?

    private(set) var productName: String?
    var isConnected: Bool { !openDevices.isEmpty }

    private var manager: IOHIDManager?
    private var openDevices: [IOHIDDevice] = []
    private var buttonState: [RemoteButton: Bool] = [:]

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let pages = [0x01, 0x09, 0x0B, 0x0C, 0x0D, 0xFF00, 0xFF01, 0xFF02]
        let matching = pages.map { [kIOHIDVendorIDKey: 0x004C, kIOHIDPrimaryUsagePageKey: $0] as [String: Any] }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDRemote>.fromOpaque(context).takeUnretainedValue().deviceAdded(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDRemote>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        // The aggregate result fails if any unrelated Apple device refuses to open; the remote's
        // interfaces are opened individually below, so only a permission denial matters here.
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        Log.info(String(format: "HID manager opened (IOReturn=0x%X)", result))
    }

    func stop() {
        guard let manager else { return }
        for device in openDevices { close(device) }
        openDevices.removeAll()
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    func restart() {
        stop()
        start()
    }

    // MARK: - Devices

    private static let knownProductIDs: Set<Int> = [
        0x0221, 0x0255, 0x0266, 0x0267, 0x026D, 0x0C4E, 0x0C4F, 0x030D, 0x030E, 0x0314, 0x0315,
    ]

    private static func isSiriRemote(_ device: IOHIDDevice) -> Bool {
        guard intProperty(device, kIOHIDVendorIDKey) == 0x004C else { return false }
        let name = stringProperty(device, kIOHIDProductKey)?.lowercased() ?? ""
        // Never seize a Magic Mouse, keyboard or trackpad, even if an ID overlaps.
        if ["mouse", "keyboard", "trackpad"].contains(where: name.contains) { return false }
        if name.contains("remote") || name.contains("siri") || name.contains("apple tv") { return true }
        // Some remotes report their serial number as the product name (seen: "DNCQN1MEGQQT",
        // product 0x0266), so fall back to the product ID for Bluetooth devices.
        let transport = stringProperty(device, kIOHIDTransportKey)?.lowercased() ?? ""
        return transport.contains("bluetooth") && knownProductIDs.contains(intProperty(device, kIOHIDProductIDKey) ?? -1)
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        guard Self.isSiriRemote(device), !openDevices.contains(where: { $0 === device }) else { return }
        let page = Self.intProperty(device, kIOHIDPrimaryUsagePageKey) ?? -1
        let usage = Self.intProperty(device, kIOHIDPrimaryUsageKey) ?? -1
        let name = Self.stringProperty(device, kIOHIDProductKey) ?? "Siri Remote"

        var mode = "seized"
        var result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if result != kIOReturnSuccess {
            mode = "shared"
            result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard result == kIOReturnSuccess else {
            Log.info(String(format: "Could not open %@ page=0x%X usage=0x%X (IOReturn=0x%X)", name, page, usage, result))
            return
        }
        Log.info(String(format: "Opened %@ interface page=0x%X usage=0x%X product=0x%X (%@)",
                        name, page, usage, Self.intProperty(device, kIOHIDProductIDKey) ?? 0, mode))

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HIDRemote>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let wasConnected = isConnected
        openDevices.append(device)
        productName = name
        if !wasConnected { onConnectionChange?(true, name) }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        guard let index = openDevices.firstIndex(where: { $0 === device }) else { return }
        close(device)
        openDevices.remove(at: index)
        if openDevices.isEmpty {
            Log.info("Siri Remote disconnected")
            // Release anything held so a disconnect mid-press cannot leave a key or button down.
            for (button, pressed) in buttonState where pressed { onButton?(button, false) }
            buttonState.removeAll()
            onConnectionChange?(false, nil)
        }
    }

    private func close(_ device: IOHIDDevice) {
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - Input

    private func handle(_ value: IOHIDValue) {
        // Microphone frames share an interface with buttons on the 1st-gen remote; buttons are
        // never wider than a few bytes.
        guard IOHIDValueGetLength(value) <= 8 else { return }
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        guard let button = Self.button(page: page, usage: usage) else {
            if intValue != 0 {
                Log.info(String(format: "Unmapped HID usage page=0x%X usage=0x%X value=%ld", page, usage, intValue))
            }
            return
        }
        let pressed = intValue != 0
        guard buttonState[button, default: false] != pressed else { return }
        buttonState[button] = pressed
        Log.debug("Button \(button.rawValue) \(pressed ? "down" : "up")")
        onButton?(button, pressed)
    }

    /// Usage table from VibeRemote's hardware-verified mapping, limited to the buttons a
    /// 1st-gen remote has. Anything else is logged as unmapped.
    private static func button(page: UInt32, usage: UInt32) -> RemoteButton? {
        switch (page, usage) {
        case (0x01, 0x86), (0x01, 0x40), (0x0C, 0x40), (0x0C, 0x46), (0x0C, 0x224): return .menu
        case (0x0C, 0x60), (0x0C, 0x223), (0x0C, 0x88), (0x0C, 0x89): return .tv
        case (0x0C, 0x80), (0x0C, 0x41), (0x09, 0x01): return .select
        case (0x0C, 0xCD), (0x0C, 0xB0), (0x0C, 0xB1): return .playPause
        case (0x0C, 0xE9): return .volumeUp
        case (0x0C, 0xEA): return .volumeDown
        case (0x0C, 0x04), (0x0C, 0xCF), (0x0C, 0x221), (0xFF00, 0x01...0x03): return .siri
        default: return nil
        }
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
