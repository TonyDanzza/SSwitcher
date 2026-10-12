import AppKit
import Carbon
import InputMethodSupport
import SwitcherCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = KeyboardMonitor()
    private let editor = ConversionCoordinator()
    private let loginAtLaunch = LoginAtLaunch()
    private let windowMoves = WindowMoveController()
    private let windowHotKeys = WindowMoveHotKeys()
    private let functionKeys = FunctionKeyController()
    private let keepAwake = KeepAwakeController()
    private let displayController = DisplayController()
    private let nativeServices = NativeServiceProvider()
    private lazy var maxRouter = MaxConversionRouter(monitor: monitor, services: nativeServices)
    private let settings = AppSettings.shared
    private let settingsStatus = SettingsStatus()
    private var settingsWindow: SettingsWindowController?
    private var settingsTimer: Timer?
    private var isRecordingShortcut = false
    private lazy var layoutRow = MenuSwitchRow(title: "Раскладка")
    private lazy var windowsRow = MenuSwitchRow(title: "Перенос окон")
    private lazy var functionRow = MenuSwitchRow(title: "Fn")
    private var appliedConversionEnabled = AppSettings.shared.conversionEnabled
    private var windowMovementEnabled: Bool { settings.windowMovementEnabled }
    private var enabled: Bool { settings.conversionEnabled }
    private var lastAttempt = "Ещё не было"
    private var lastResult = "Ещё не срабатывало"
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var permissionRetries = 0
    private var diagnosticsWindow: DiagnosticsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = BrandIcon.menuImage()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.setAccessibilityLabel("SSwitcher — исправление раскладки")
        statusItem.button?.toolTip = "SSwitcher — \(AppSettings.shared.triggerPhrase.lowercased()) исправляет раскладку текста"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        NSApp.servicesProvider = nativeServices
        // Public refresh for this installed application's static NSServices;
        // the ready provider can receive calls immediately and rejects unarmed.
        NSUpdateDynamicServices()
        _ = InputSources.sourceChanged()
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let wasConverting = self.editor.isConverting
            let changed = InputSources.sourceChanged()
            self.monitor.keyboardLayoutChanged()
            if changed { self.monitor.focusChanged() }
            // A confirmed legacy replacement selects its target layout before
            // revealing the image. Idle built-in-layout notices preserve that
            // reveal; an active attempt still cancels.
            if changed && wasConverting { self.editor.overlay.cancel() }
        }
        windowHotKeys.onMove = { [weak self] direction in
            guard let self else { return }
            self.refreshWindowShortcuts()
            guard self.windowHotKeys.isRegistered else { return }
            self.monitor.focusChanged()
            self.editor.overlay.cancel()
            self.windowMoves.move(direction)
        }
        keepAwake.onChange = { [weak self] in self?.refreshStatusIcon(); self?.refreshSettingsStatus() }
        functionKeys.start(shortcut: settings.functionKeyShortcut)
        keepAwake.setShortcut(settings.keepAwakeShortcut)
        settings.onChange = { [weak self] in self?.settingsChanged() }
        applyDoubleShiftSettings()
        AppMainMenu.install(target: self, settings: #selector(showSettings), about: #selector(showAbout))
        windowMoves.onResult = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.toolTip = self.windowMoves.lastResult
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.nativeServices.cancelVisualShield()
            self?.refreshWindowShortcuts()
            self?.refreshSettingsStatus()
            if self?.settingsWindow?.isVisible == true { self?.displayController.refresh() }
        }
        monitor.onUserActivity = { [weak self] in
            guard let overlay = self?.editor.overlay, !overlay.isIdle else { return }
            DispatchQueue.main.async { overlay.cancel() }
            // Bare Shift taps are drained by the active MAX transaction. They
            // must not expose its intermediate selection. Typing, clicks,
            // scrolling and other modifiers cancel via onRealInput below.
        }
        monitor.onRealInput = { [weak self] in
            self?.editor.userInputChanged()
            self?.nativeServices.cancelConversion()
        }
        monitor.onWindowInteraction = { [weak self] in self?.windowMoves.userInteracted() }
        monitor.onGestureRelease = { [weak self] time in
            self?.editor.performance.gestureReleased(at: time)
            // Called inside the event tap: start the MAX snapshot afterwards.
            DispatchQueue.main.async { self?.prepareEarlyMaxShield() }
        }
        monitor.onGestureCancelled = { [weak self] in self?.editor.performance.cancelGesture() }
        monitor.onBlockedGesture = { [weak self] in
            guard let self else { return }
            self.lastResult = "Проверьте текст и выделите его заново: предыдущая замена не подтверждена"
            self.statusItem.button?.toolTip = self.lastResult
        }
        maxRouter.onResult = { [weak self] result in
            guard let self else { return }
            self.lastResult = result
            self.statusItem.button?.toolTip = result
        }
        maxRouter.suspendWindowShortcuts = { [weak self] in
            self?.windowHotKeys.stop()
            self?.windowMoves.cancel()
        }
        maxRouter.restoreWindowShortcuts = { [weak self] in self?.refreshWindowShortcuts() }
        monitor.canStartConversion = { [weak self] in
            self?.enabled == true && self?.editor.isConverting == false && self?.maxRouter.isConverting == false &&
                self?.settings.isExcluded(NSWorkspace.shared.frontmostApplication) == false
        }
        monitor.onDoubleShift = { [weak self] in
            guard let self, self.enabled, !self.editor.isConverting, !self.maxRouter.isConverting,
                  !self.settings.isExcluded(NSWorkspace.shared.frontmostApplication),
                  self.monitor.claimConversion() else { return }
            self.lastAttempt = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            // Keep a leftover experimental source from running beside legacy
            // replacement. The utility no longer starts or requests the IME.
            if InputMethodIdentity.currentMode != nil {
                self.lastResult = "Экспериментальный источник отключён; выберите обычную раскладку macOS"
                self.editor.performance.cancelGesture()
                self.monitor.conversionFinished(unverified: false)
                self.statusItem.button?.toolTip = self.lastResult
                return
            }
            self.lastResult = "Проверяю поле ввода…"
            let generation = self.monitor.inputGeneration
            let activity = self.monitor.activityGeneration
            if let max = NSWorkspace.shared.frontmostApplication, MaxConversionRouter.isMax(max) {
                self.editor.performance.cancelGesture()
                self.maxRouter.convert(in: max, generation: generation)
                return
            }
            self.editor.convertAtCursor(releaseTime: self.monitor.lastGestureRelease, isInputUnchanged: { [weak self] in
                self?.monitor.inputGeneration == generation
            }, isActivityUnchanged: { [weak self] in self?.monitor.activityGeneration == activity },
               modifiersClear: { [weak self] in self?.monitor.physicalModifiersClear == true },
               observedModifiersClear: { [weak self] in self?.monitor.observedModifiersClear == true }) { [weak self] outcome in
                guard let self else { return }
                if case .unverified = outcome { self.monitor.conversionFinished(unverified: true) }
                else { self.monitor.conversionFinished(unverified: false) }
                switch outcome {
                case .ignored: self.lastResult = "Курсор должен стоять в конце слова"
                case .cancelled: self.lastResult = "Замена отменена: ввод или активное поле изменились"
                case .converted: self.lastResult = "Текст заменён — подтверждено редактором"
                case .unverified: self.lastResult = "Результат замены не подтверждён; проверьте текст и выделите его заново"
                case .failure(let message):
                    self.lastResult = message
                    if self.settings.beepOnFailure { NSSound.beep() }
                }
                self.statusItem.button?.toolTip = self.lastResult
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.monitor.focusChanged()
            self.nativeServices.cancelVisualShield()
            self.windowMoves.cancel()
            self.editor.overlay.cancel()
            self.refreshPermissions()
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.functionKeys.frontmostChanged(app)
            self.refreshTypedWordTracking(frontmost: app)
            if InputMethodIdentity.currentMode == nil, let app { self.editor.prepareAccessibility(for: app) }
        }
        DiagnosticReports.shared.removeObsoleteReports()
        refreshTypedWordTracking()
        if InputMethodIdentity.currentMode == nil, let app = NSWorkspace.shared.frontmostApplication { editor.prepareAccessibility(for: app) }
        refreshPermissions()
        rebuildMenu()
        if CommandLine.arguments.contains("--check") { presentDiagnostics(activateApplication: false) }
    }

    private func refreshStatusIcon() {
        statusItem.button?.image = BrandIcon.menuImage(keepingAwake: keepAwake.isActive)
        let label = ["SSwitcher — исправление раскладки", keepAwake.iconDescription].compactMap { $0 }.joined(separator: ", ")
        statusItem.button?.setAccessibilityLabel(label)
    }

    /// The MAX snapshot for a direct word request starts at the gesture
    /// release, during the Shift quiet interval.
    private func prepareEarlyMaxShield() {
        guard enabled, !editor.isConverting else { return }
        maxRouter.prepareEarlyShield()
    }

    /// Typed characters are kept only for MAX and only while conversion is on.
    private func refreshTypedWordTracking(frontmost: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        monitor.tracksTypedWord = enabled && MaxConversionRouter.isMax(frontmost)
    }

    func applicationDidBecomeActive(_ notification: Notification) { refreshPermissions() }
    func menuWillOpen(_ menu: NSMenu) { refreshPermissions(); rebuildMenu() }

    /// Only retry while permissions/startup are missing, for at most 30 seconds.
    /// Menu/app activation/open are recovery points after that bounded window.
    private func refreshPermissions(startRetry: Bool = true) {
        guard enabled || windowMovementEnabled else {
            if monitor.isRunning { monitor.stop() }
            refreshWindowShortcuts()
            permissionTimer?.invalidate(); permissionTimer = nil
            return
        }
        if CGPreflightListenEventAccess() { if !monitor.isRunning { monitor.start() } }
        else if monitor.isRunning { monitor.stop() }
        refreshWindowShortcuts()
        if monitor.isRunning && AXIsProcessTrusted() {
            permissionTimer?.invalidate(); permissionTimer = nil; permissionRetries = 0
        } else if startRetry && permissionTimer == nil {
            permissionRetries = 0
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.permissionRetries += 1
                self.refreshPermissions(startRetry: false)
                if self.permissionRetries >= 15 { timer.invalidate(); self.permissionTimer = nil }
            }
            permissionTimer?.tolerance = 0.5
        }
    }

    /// Arrows follow the display arrangement unless Settings choose them;
    /// nothing registers with one display, so every arrow keeps its meaning.
    private var windowShortcutDirections: Set<WindowMoveDirection> {
        WindowShortcutDirections.resolve(settings.windowDirectionChoice, displays: WindowMoveController.currentDisplays())
    }

    private var displayCount: Int {
        NSScreen.screens.map(\.frame).reduce(into: [CGRect]()) { unique, frame in
            if !unique.contains(frame) { unique.append(frame) }
        }.count
    }

    private func refreshWindowShortcuts() {
        let directions = windowShortcutDirections
        if windowMovementEnabled && !nativeServices.isConverting && AXIsProcessTrusted() &&
            CGPreflightListenEventAccess() && monitor.isRunning && displayCount >= 2 && !directions.isEmpty {
            windowHotKeys.start(directions: directions, modifiers: settings.windowModifiers)
        } else {
            windowHotKeys.stop()
            windowMoves.cancel()
        }
    }

    /// Why window shortcuts are not registered, or nil when they work.
    private var windowShortcutWaitingReason: String? {
        guard windowMovementEnabled, !windowHotKeys.isRegistered else { return nil }
        if !AXIsProcessTrusted() { return "Нужен Универсальный доступ" }
        if !CGPreflightListenEventAccess() { return "Нужен Мониторинг ввода" }
        if !monitor.isRunning { return "Слежение за вводом не запущено" }
        if displayCount < 2 { return "Ждёт второго дисплея" }
        if windowShortcutDirections.isEmpty { return "Стрелки не выбраны" }
        if windowHotKeys.lastError != nil { return "Сочетания заняты другой программой" }
        return nil
    }

    /// Short by design (HIG menu bar extras): problems, frequent toggles,
    /// Settings and Quit. Everything else lives in Settings.
    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        // Switches replace checkmarks, so the checkmark column would only
        // push ordinary items away from the switch rows' text.
        menu.showsStateColumn = false
        let problems = menuProblems
        for (title, tab) in problems {
            let item = add(title, action: #selector(openSettingsTab(_:)), to: menu)
            item.tag = tab.rawValue
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Внимание")
        }
        if !problems.isEmpty { menu.addItem(.separator()) }
        updateMenuRows()
        for row in [layoutRow, windowsRow, functionRow] { menu.addItem(row.item) }
        for item in keepAwake.menuItems() { menu.addItem(item) }
        menu.addItem(.separator())
        let settingsItem = add("Настройки…", action: #selector(showSettings), to: menu)
        settingsItem.keyEquivalent = ","
        let quit = add("Завершить SSwitcher", action: #selector(quit), to: menu)
        quit.keyEquivalent = "q"
    }

    /// Switch rows: the second line says what the switch does right now.
    private func updateMenuRows() {
        layoutRow.onToggle = { [weak self] on in self?.settings.conversionEnabled = on }
        layoutRow.update(isOn: enabled, details: ["\(settings.triggerPhrase) исправляет текст"])
        windowsRow.onToggle = { [weak self] on in self?.settings.windowMovementEnabled = on }
        let registered = windowHotKeys.isRegistered ? windowHotKeys.directions : []
        let windowDetail = windowShortcutWaitingReason
            ?? (registered.isEmpty ? "Между дисплеями" : "\(windowHotKeys.modifiers.symbols)\(WindowShortcutDirections.arrows(registered)) переносит окно")
        windowsRow.update(isOn: windowMovementEnabled, details: [windowDetail])
        // "Fn on" means the fn layer is in effect without holding fn:
        // brightness and sound (the macOS default). Off: plain F1–F12.
        functionRow.onToggle = { [weak self] on in
            self?.functionKeys.baseMode = on ? .media : .standard
            self?.updateMenuRows()
        }
        var functionDetails = [functionKeys.baseMode == .media ? "Яркость и звук без fn" : "F1–F12 без fn, яркость с fn"]
        if let shortcut = functionKeys.shortcut, !functionKeys.isShortcutBlocked { functionDetails.append(KeyNames.string(shortcut)) }
        functionRow.update(isOn: functionKeys.baseMode == .media, details: functionDetails)
    }

    /// One line per problem; each opens the Settings pane that fixes it.
    private var menuProblems: [(String, SettingsTab)] {
        var problems: [(String, SettingsTab)] = []
        if (enabled || windowMovementEnabled) && (!monitor.isRunning || !AXIsProcessTrusted()) {
            problems.append(("Нужны разрешения macOS…", .general))
        }
        if windowMovementEnabled, windowHotKeys.lastError != nil, !windowHotKeys.isRegistered, displayCount >= 2,
           AXIsProcessTrusted(), monitor.isRunning {
            problems.append(("Сочетания переноса окон заняты…", .windows))
        }
        if functionKeys.isShortcutBlocked, let shortcut = functionKeys.shortcut {
            problems.append(("Сочетание \(KeyNames.string(shortcut)) занято…", .keyboard))
        }
        if functionKeys.lastError != nil { problems.append(("Верхний ряд не переключается…", .keyboard)) }
        if keepAwake.isShortcutBlocked, let shortcut = settings.keepAwakeShortcut {
            problems.append(("Сочетание \(KeyNames.string(shortcut)) занято…", .keepAwake))
        }
        return problems
    }

    @discardableResult
    private func add(_ title: String, action: Selector? = nil, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        menu.addItem(item)
        return item
    }


    private func applyDoubleShiftSettings() {
        monitor.configureDoubleTap(trigger: settings.triggerKey, side: settings.triggerSide, interval: settings.doubleShiftInterval)
    }

    /// Applies any Settings change: listener, shortcuts, typed-word tracking.
    private func settingsChanged() {
        if appliedConversionEnabled != settings.conversionEnabled {
            appliedConversionEnabled = settings.conversionEnabled
            monitor.focusChanged()
        }
        applyDoubleShiftSettings()
        if !settings.smoothReplacement { editor.overlay.cancel() }
        if !isRecordingShortcut {
            functionKeys.setShortcut(settings.functionKeyShortcut)
            keepAwake.setShortcut(settings.keepAwakeShortcut)
        }
        refreshTypedWordTracking()
        refreshPermissions()
        refreshSettingsStatus()
        // An open menu keeps its rows; only their text and switches change.
        updateMenuRows()
    }

    // MARK: Settings window

    @objc private func showSettings() { presentSettings(nil) }
    /// The standard About panel, with the source link in its credits.
    @objc private func showAbout() {
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
    @objc private func openSettingsTab(_ sender: NSMenuItem) { presentSettings(SettingsTab(rawValue: sender.tag)) }

    private func presentSettings(_ tab: SettingsTab?) {
        refreshPermissions()
        if settingsWindow == nil {
            let actions = SettingsActions(
                requestAccessibility: { [weak self] in self?.requestAccessibility() },
                requestInputMonitoring: { [weak self] in self?.requestPermission() },
                requestScreenCapture: { [weak self] in self?.requestScreenCapture() },
                toggleLogin: { [weak self] in self?.toggleLoginAtLaunch() },
                openLoginSettings: { [weak self] in self?.openLoginSettings() },
                openTestWindow: { [weak self] in self?.presentDiagnostics(activateApplication: true) },
                copyReport: { [weak self] in self?.copyReport() },
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
                                                  displays: displayController, actions: actions)
            window.onVisibilityChange = { [weak self] visible in self?.settingsVisibilityChanged(visible) }
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

    private func refreshSettingsStatus() {
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
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return SettingsStatus.Display(id: number.uint32Value, name: screen.localizedName, frame: screen.frame, isMain: screen == main)
        })
        set(\.availableDirections, WindowShortcutDirections.available(in: WindowMoveController.currentDisplays()))
        set(\.registeredDirections, windowHotKeys.isRegistered ? windowHotKeys.directions : [])
        set(\.windowShortcutProblem, windowShortcutWaitingReason.flatMap { $0 == "Ждёт второго дисплея" ? nil : $0 })
        set(\.lastWindowResult, windowMoves.lastResult)
        set(\.functionShortcutBlocked, !isRecordingShortcut && functionKeys.isShortcutBlocked)
        set(\.keepAwakeShortcutBlocked, !isRecordingShortcut && keepAwake.isShortcutBlocked)
        set(\.keepAwakeActive, keepAwake.isActive)
        set(\.keepAwakeStatus, keepAwake.statusDescription)
        set(\.hasBattery, keepAwake.hasBattery)
        set(\.lastAttempt, lastAttempt)
        set(\.lastResult, lastResult)
        set(\.diagnostics, diagnosticsText())
    }

    private func copyReport() { DiagnosticsWindow.copyReport(diagnosticsText()) }

    @objc private func requestPermission() {
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        if !monitor.start(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        refreshPermissions()
        rebuildMenu()
    }

    private func requestScreenCapture() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !CGPreflightScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        rebuildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLoginAtLaunch() {
        loginAtLaunch.toggle { [weak self] in
            guard let self else { return }
            self.statusItem.button?.toolTip = self.loginAtLaunch.lastError ?? self.loginAtLaunch.statusDescription
            self.refreshSettingsStatus()
        }
        refreshSettingsStatus()
    }
    @objc private func openLoginSettings() { loginAtLaunch.openSettings() }

    @objc private func showDiagnostics() {
        presentDiagnostics(activateApplication: true)
    }

    private func presentDiagnostics(activateApplication: Bool) {
        refreshPermissions()
        if diagnosticsWindow == nil {
            diagnosticsWindow = DiagnosticsWindow(readStatus: { [weak self] in self?.diagnosticsText() ?? "" },
                runCheck: { [weak self] in self?.monitor.triggerForDiagnostics() },
                requestCapture: { [weak self] in self?.requestScreenCapture() })
        }
        diagnosticsWindow?.present(activateApplication: activateApplication)
    }

    private func diagnosticsText() -> String {
        [
            "Универсальный доступ: \(AXIsProcessTrusted() ? "разрешён" : "не выдан")",
            "Мониторинг ввода: \(CGPreflightListenEventAccess() ? "разрешён" : "не выдан")",
            "Отправка клавиш: \(CGPreflightPostEventAccess() ? "разрешена" : "не разрешена")",
            "Слежение за клавишами: \(monitor.isRunning ? "работает" : "не запущено")",
            "Событий Shift: \(monitor.shiftEventCount); двойных нажатий: \(monitor.doubleShiftCount)",
            "Синтетических событий клавиатуры: \(monitor.syntheticEventCount)",
            loginAtLaunch.statusDescription,
            "Последняя попытка: \(lastAttempt)",
            lastResult,
            editor.diagnosticDetails,
            windowMoves.lastResult,
            windowMoves.lastDetails,
            functionKeys.statusDescription,
            keepAwake.statusDescription,
            editor.overlay.lastStatus,
            editor.performance.diagnosticStatus,
            nativeServices.conversionStatus
        ].joined(separator: "\n")
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshPermissions()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        nativeServices.cancel()
        NSApp.servicesProvider = nil
        windowHotKeys.stop()
        windowMoves.cancel()
        functionKeys.restoreBase()
        keepAwake.stop()
        keepAwake.setShortcut(nil)
        settingsTimer?.invalidate()
        permissionTimer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let inputSourceObserver { DistributedNotificationCenter.default().removeObserver(inputSourceObserver) }
        monitor.stop()
        editor.shutdown()
        DiagnosticReports.shared.flushNow()
    }
}

// Keep the lease alive globally; a refused second launch never constructs the
// delegate, installs an observer, creates an icon or starts a keyboard tap.
guard let instanceClaim = SingleInstance.claim() else { exit(EXIT_SUCCESS) }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(instanceClaim) { app.run() }
