import AppKit
import SwitcherCore

// MARK: Settings window

extension AppDelegate {
    @objc func showSettings() { presentSettings(nil) }
    /// The standard About panel, with the source link in its credits.
    @objc func showAbout() {
        let credits = NSMutableAttributedString(string: "Двойной Shift исправляет раскладку, окна переезжают между дисплеями, верхний ряд и сон Mac под рукой.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "Исходный код на GitHub", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .link: URL(string: "https://github.com/TonyDanzza/SSwitcher") as Any]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
    @objc func openSettingsTab(_ sender: NSMenuItem) { presentSettings(SettingsTab(rawValue: sender.tag)) }

    private func presentSettings(_ tab: SettingsTab?) {
        refreshPermissions()
        if settingsWindow == nil {
            let actions = SettingsActions(
                requestAccessibility: { [weak self] in self?.requestAccessibility() },
                requestInputMonitoring: { [weak self] in self?.requestPermission() },
                requestScreenCapture: { [weak self] in self?.requestScreenCapture() },
                toggleLogin: { [weak self] in self?.toggleLoginAtLaunch() },
                openLoginSettings: { [weak self] in self?.openLoginSettings() },
                stopKeepAwake: { [weak self] in self?.keepAwake.stop() },
                recordingShortcut: { [weak self] recording in self?.recordingShortcut(recording) },
                confirmShortcut: { [weak self] shortcut in
                    ShortcutChecks.confirm("Сочетание \(KeyNames.string(shortcut))", conflicts: ShortcutChecks.conflicts(for: shortcut),
                                           in: self?.settingsWindow?.window)
                },
                confirmTrigger: { [weak self] trigger in
                    ShortcutChecks.confirm("Двойное нажатие \(trigger.symbol)", conflicts: ShortcutChecks.conflicts(forDoubleTap: trigger),
                                           in: self?.settingsWindow?.window)
                },
                confirmWindowModifiers: { [weak self] modifiers in
                    guard let self else { return true }
                    let available = WindowShortcutDirections.available(in: WindowMoveController.currentDisplays())
                    let directions = self.settings.windowDirectionsManual ? self.settings.windowDirections
                        : (available.isEmpty ? Set(WindowMoveDirection.allCases) : available)
                    return ShortcutChecks.confirm("Сочетание \(modifiers.symbols) + стрелки",
                                                  conflicts: ShortcutChecks.conflicts(forArrows: modifiers, directions: directions),
                                                  in: self.settingsWindow?.window)
                })
            let window = SettingsWindowController(settings: settings, status: settingsStatus, functionKeys: functionKeys,
                                                  displays: displayController, mouse: mouse, actions: actions)
            window.onVisibilityChange = { [weak self] visible in self?.settingsVisibilityChanged(visible) }
            window.onTabChange = { [weak self] _ in self?.refreshSettingsStatus() }
            settingsWindow = window
        }
        refreshSettingsStatus()
        displayController.refresh()
        settingsWindow?.show(tab)
    }

    /// While Settings are open SSwitcher sits in the Dock and Command-Tab, so
    /// the window cannot get lost behind others; closing returns it to the menu bar.
    private func settingsVisibilityChanged(_ visible: Bool) {
        settingsTimer?.invalidate(); settingsTimer = nil
        if visible {
            NSApp.setActivationPolicy(.regular)
            settingsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.refreshPermissions(startRetry: false)
                self?.refreshSettingsStatus()
            }
            settingsTimer?.tolerance = 0.3
        } else {
            if isRecordingShortcut { recordingShortcut(false) }
            mouse.cancelRecording()
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func recordingShortcut(_ recording: Bool) {
        isRecordingShortcut = recording
        if recording {
            functionKeys.setShortcut(nil)
            keepAwake.setShortcut(nil)
        } else {
            functionKeys.setShortcut(settings.functionKeyShortcut)
            keepAwake.setShortcut(settings.keepAwakeShortcut)
            refreshSettingsStatus()
        }
    }

    func refreshSettingsStatus() {
        guard settingsWindow?.isVisible == true else { return }
        let status = settingsStatus
        func set<T: Equatable>(_ path: ReferenceWritableKeyPath<SettingsStatus, T>, _ value: T) {
            if status[keyPath: path] != value { status[keyPath: path] = value }
        }
        set(\.accessibility, AXIsProcessTrusted())
        set(\.inputMonitoring, CGPreflightListenEventAccess())
        set(\.screenCapture, CGPreflightScreenCaptureAccess())
        set(\.loginStatus, loginAtLaunch.status)
        set(\.loginChanging, loginAtLaunch.isChanging)
        set(\.loginError, loginAtLaunch.lastError)
        let main = NSScreen.screens.first
        set(\.displays, NSScreen.screens.compactMap { screen in
            screen.displayID.map { SettingsStatus.Display(id: $0, name: screen.localizedName, frame: screen.frame, isMain: screen == main) }
        })
        set(\.availableDirections, WindowShortcutDirections.available(in: WindowMoveController.currentDisplays()))
        set(\.windowShortcutProblem, windowShortcutWaitingReason.flatMap { $0 == .singleDisplay ? nil : $0.message })
        set(\.lastWindowResult, windowMoves.lastResult)
        set(\.functionShortcutBlocked, !isRecordingShortcut && functionKeys.isShortcutBlocked)
        set(\.keepAwakeShortcutBlocked, !isRecordingShortcut && keepAwake.isShortcutBlocked)
        set(\.keepAwakeActive, keepAwake.isActive)
        set(\.keepAwakeStatus, keepAwake.statusDescription)
        set(\.hasBattery, keepAwake.hasBattery)
    }

    @objc private func toggleLoginAtLaunch() {
        loginAtLaunch.toggle { [weak self] in
            guard let self else { return }
            self.statusItem.button?.toolTip = self.loginAtLaunch.lastError ?? self.loginAtLaunch.statusDescription
            self.refreshSettingsStatus()
        }
        refreshSettingsStatus()
    }
    @objc private func openLoginSettings() { loginAtLaunch.openSettings() }
}
