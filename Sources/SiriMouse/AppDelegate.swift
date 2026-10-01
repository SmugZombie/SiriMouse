import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let remote = HIDRemote()
    private let touch = TouchSurface()
    private let mediaGuard = MediaKeyGuard()
    private lazy var engine = ActionEngine(touch: touch)
    private var permissionTimer: Timer?
    private var touchRetryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("SiriMouse \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "dev") launched")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        engine.onModeChange = { [weak self] _ in self?.updateIcon() }
        remote.onButton = { [weak self] button, pressed in
            self?.mediaGuard.noteRemoteButton()
            self?.engine.button(button, pressed: pressed)
        }
        remote.onConnectionChange = { [weak self] connected, name in
            guard let self else { return }
            self.updateIcon()
            if connected {
                HUD.shared.show("\(name ?? "Siri Remote") connected", symbol: "appletvremote.gen1")
                // The touch surface registers with MultitouchSupport a moment after the HID interfaces.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.attachTouch() }
            } else {
                self.touch.detach()
            }
        }

        if !Permissions.inputMonitoring { Permissions.requestInputMonitoring() }
        if !Permissions.accessibility { Permissions.requestAccessibility() }
        startInputs()
        if !(Permissions.inputMonitoring && Permissions.accessibility) { watchPermissions() }

        // Retry the touch surface while connected but not attached (e.g. after the remote wakes).
        touchRetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.remote.isConnected, self.touch.attachedSurfaces == 0 else { return }
            self.attachTouch()
        }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            self?.mediaGuard.start()
            self?.attachTouch()
        }
    }

    private func startInputs() {
        remote.start()
        mediaGuard.start()
        attachTouch()
    }

    private func attachTouch() {
        touch.attach()
        updateIcon()
    }

    /// Input Monitoring only takes effect for HID managers created after it is granted.
    private func watchPermissions() {
        var hadInput = Permissions.inputMonitoring
        var hadAccessibility = Permissions.accessibility
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            if !hadInput, Permissions.inputMonitoring {
                hadInput = true
                Log.info("Input Monitoring granted; restarting HID")
                self.remote.restart()
            }
            if !hadAccessibility, Permissions.accessibility {
                hadAccessibility = true
                Log.info("Accessibility granted")
                self.mediaGuard.start()
            }
            if hadInput && hadAccessibility { timer.invalidate() }
        }
    }

    private func updateIcon() {
        let mode = Settings.shared.mode
        let image = NSImage(systemSymbolName: remote.isConnected ? mode.symbol : "appletvremote.gen1",
                            accessibilityDescription: "SiriMouse – \(mode.title)")
            ?? NSImage(systemSymbolName: "av.remote", accessibilityDescription: "SiriMouse")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !remote.isConnected
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = remote.isConnected ? "\(remote.productName ?? "Siri Remote") connected" : "No Siri Remote connected"
        menu.addItem(disabled(status))
        if remote.isConnected {
            menu.addItem(disabled(touch.attachedSurfaces > 0 ? "Touch surface active" : "Touch surface not found"))
        }
        menu.addItem(.separator())

        for (index, mode) in Mode.allCases.enumerated() {
            let item = item("\(mode.title) Mode", action: #selector(selectMode(_:)), key: "\(index + 1)")
            item.representedObject = mode.rawValue
            item.state = Settings.shared.mode == mode ? .on : .off
            item.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let speed = NSMenu()
        for option in PointerSpeed.allCases {
            let item = item(option.title, action: #selector(selectSpeed(_:)))
            item.representedObject = option.rawValue
            item.state = Settings.shared.pointerSpeed == option ? .on : .off
            speed.addItem(item)
        }
        menu.addItem(submenu("Pointer Speed", speed))

        let siri = NSMenu()
        for option in SiriAction.allCases {
            let item = item(option.title, action: #selector(selectSiri(_:)))
            item.representedObject = option.rawValue
            item.state = Settings.shared.siriAction == option ? .on : .off
            siri.addItem(item)
        }
        menu.addItem(submenu("Siri Button", siri))

        let permissions = NSMenu()
        permissions.addItem(permissionItem("Input Monitoring", granted: Permissions.inputMonitoring,
                                           action: #selector(grantInputMonitoring)))
        permissions.addItem(permissionItem("Accessibility", granted: Permissions.accessibility,
                                           action: #selector(grantAccessibility)))
        let allGranted = Permissions.inputMonitoring && Permissions.accessibility
        menu.addItem(submenu(allGranted ? "Permissions" : "⚠️ Permissions Needed", permissions))
        menu.addItem(.separator())

        menu.addItem(item("Button Guide…", action: #selector(showGuide)))
        menu.addItem(item("Reconnect Remote", action: #selector(reconnect)))
        let login = item("Launch at Login", action: #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let verbose = item("Verbose Logging", action: #selector(toggleVerbose))
        verbose.state = Settings.shared.verboseLogging ? .on : .off
        menu.addItem(verbose)
        menu.addItem(item("Open Log", action: #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit SiriMouse", action: #selector(quit), key: "q"))
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func permissionItem(_ name: String, granted: Bool, action: Selector) -> NSMenuItem {
        let item = item(granted ? "\(name): Granted" : "\(name): Grant…", action: action)
        item.state = granted ? .on : .off
        return item
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = Mode(rawValue: sender.representedObject as? String ?? "") else { return }
        engine.setMode(mode)
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        if let speed = PointerSpeed(rawValue: sender.representedObject as? String ?? "") {
            Settings.shared.pointerSpeed = speed
        }
    }

    @objc private func selectSiri(_ sender: NSMenuItem) {
        if let action = SiriAction(rawValue: sender.representedObject as? String ?? "") {
            Settings.shared.siriAction = action
        }
    }

    @objc private func grantInputMonitoring() {
        Permissions.requestInputMonitoring()
        openSettings("Privacy_ListenEvent")
        watchPermissions()
    }

    @objc private func grantAccessibility() {
        Permissions.requestAccessibility()
        openSettings("Privacy_Accessibility")
        watchPermissions()
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func reconnect() {
        remote.restart()
        attachTouch()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.info("Launch at login failed: \(error.localizedDescription)")
            let alert = NSAlert(error: error)
            alert.informativeText = "Move SiriMouse.app to /Applications and try again."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func toggleVerbose() { Settings.shared.verboseLogging.toggle() }

    @objc private func openLog() {
        Log.info("Log opened")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSWorkspace.shared.open(Log.url) }
    }

    @objc private func showGuide() {
        let alert = NSAlert()
        alert.messageText = "SiriMouse Button Guide"
        alert.informativeText = """
        Everywhere
          TV button / hold Menu — switch mode
          Menu — Esc (ends a slideshow)
          Volume +/− — system volume
          Siri — \(Settings.shared.siriAction.title)

        Presenter Mode
          Click or swipe right — next slide
          Click left third or swipe left — previous slide
          Swipe up/down — up/down arrow
          Play/Pause — play/pause media

        Mouse Mode
          Slide finger — move pointer
          Click — left click (hold and slide to drag)
          Play/Pause — right click
          Slide on the right edge — scroll

        Media Mode
          Click or Play/Pause — play/pause
          Swipe left/right — previous/next track
          Swipe up/down — volume
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
