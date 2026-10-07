import AppKit
import SwitcherCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = KeyboardMonitor()
    private let editor = ConversionCoordinator()
    private let loginAtLaunch = LoginAtLaunch()
    private let windowMoves = WindowMoveController()
    private let windowHotKeys = WindowMoveHotKeys()
    private var windowMovementEnabled = !UserDefaults.standard.bool(forKey: "windowMovementDisabled")
    private var enabled = !UserDefaults.standard.bool(forKey: "paused")
    private var lastAttempt = "Ещё не срабатывал"
    private var lastResult = "Ожидание двойного Shift"
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var permissionRetries = 0
    private var diagnosticsWindow: DiagnosticsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = BrandIcon.menuImage()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.setAccessibilityLabel("SSwitcher — исправление раскладки")
        statusItem.button?.toolTip = "SSwitcher — двойной Shift исправляет раскладку текста"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        windowHotKeys.onMove = { [weak self] direction in
            guard let self else { return }
            self.refreshWindowShortcuts()
            guard self.windowHotKeys.isRegistered else { return }
            self.monitor.focusChanged()
            self.editor.overlay.cancel()
            self.windowMoves.move(direction)
        }
        windowMoves.onResult = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.toolTip = self.windowMoves.lastResult
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshWindowShortcuts()
            self?.rebuildMenu()
        }
        monitor.onUserActivity = { [weak self] in self?.editor.overlay.cancel() }
        monitor.onRealInput = { [weak self] in self?.editor.userInputChanged() }
        monitor.onWindowInteraction = { [weak self] in self?.windowMoves.userInteracted() }
        monitor.onGestureRelease = { [weak self] time in self?.editor.performance.gestureReleased(at: time) }
        monitor.onGestureCancelled = { [weak self] in self?.editor.performance.cancelGesture() }
        monitor.onBlockedGesture = { [weak self] in
            guard let self else { return }
            self.lastResult = "Проверьте текст и выделите его заново: предыдущая замена не подтверждена"
            self.statusItem.button?.toolTip = self.lastResult
        }
        monitor.canStartConversion = { [weak self] in self?.enabled == true && self?.editor.isConverting == false }
        monitor.onDoubleShift = { [weak self] in
            guard let self, self.enabled, !self.editor.isConverting, self.monitor.claimConversion() else { return }
            self.lastAttempt = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.lastResult = "Проверяю поле ввода…"
            let generation = self.monitor.inputGeneration
            let activity = self.monitor.activityGeneration
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
                    NSSound.beep()
                }
                self.statusItem.button?.toolTip = self.lastResult
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.monitor.focusChanged()
            self.windowMoves.cancel()
            self.editor.overlay.cancel()
            self.refreshPermissions()
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self.editor.prepareAccessibility(for: app)
            }
        }
        if let app = NSWorkspace.shared.frontmostApplication { editor.prepareAccessibility(for: app) }
        refreshPermissions()
        rebuildMenu()
        if CommandLine.arguments.contains("--check") { showDiagnostics() }
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

    private func refreshWindowShortcuts() {
        let frames = NSScreen.screens.map(\.frame).reduce(into: [CGRect]()) { unique, frame in
            if !unique.contains(frame) { unique.append(frame) }
        }
        if windowMovementEnabled && AXIsProcessTrusted() && CGPreflightListenEventAccess() && monitor.isRunning && frames.count >= 2 {
            windowHotKeys.start()
        } else {
            windowHotKeys.stop()
            windowMoves.cancel()
        }
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        add("SSwitcher \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")", to: menu)
        add("Раскладка: \(InputSources.currentName)", to: menu)
        add(enabled ? (monitor.isRunning && AXIsProcessTrusted() ? "Двойной Shift включён" : "Нужны разрешения macOS") : "На паузе", to: menu)
        menu.addItem(.separator())
        add("Двойной Shift: слово или выделенный текст", to: menu)
        add("Последний двойной Shift: \(lastAttempt)", to: menu)
        add(lastResult, to: menu)
        let toggle = add("Исправлять по двойному Shift", action: #selector(toggleEnabled), to: menu)
        toggle.state = enabled ? .on : .off
        let smooth = add("Плавная замена", action: #selector(toggleSmoothReplacement), to: menu)
        smooth.state = ReplacementOverlay.enabled ? .on : .off
        if ReplacementOverlay.enabled && !CGPreflightScreenCaptureAccess() {
            add("Разрешить запись экрана для анимации…", action: #selector(requestScreenCapture), to: menu)
        }
        if !monitor.isRunning && (enabled || windowMovementEnabled) {
            add("Разрешить мониторинг ввода…", action: #selector(requestPermission), to: menu)
        }
        if !AXIsProcessTrusted() {
            add("Разрешить универсальный доступ…", action: #selector(requestAccessibility), to: menu)
        }
        menu.addItem(.separator())
        let windowToggle = add("Переносить окно: ⌥⇧ + стрелки", action: #selector(toggleWindowMovement), to: menu)
        windowToggle.state = windowMovementEnabled ? .on : .off
        windowToggle.toolTip = "Выключите, чтобы Option+Shift+стрелки снова выделяли текст"
        if windowMovementEnabled && !windowHotKeys.isRegistered {
            if !AXIsProcessTrusted() { add("Для переноса нужен Универсальный доступ", to: menu) }
            else if !CGPreflightListenEventAccess() { add("Для переноса нужен Мониторинг ввода", to: menu) }
            else if !monitor.isRunning { add("Слежение за вводом не запущено", to: menu) }
            else if NSScreen.screens.map(\.frame).reduce(into: [CGRect](), { if !$0.contains($1) { $0.append($1) } }).count < 2 { add("Перенос ждёт второго дисплея", to: menu) }
            else if windowHotKeys.lastError != nil { add("Горячие клавиши переноса недоступны", to: menu) }
            else { add("Перенос ждёт второго дисплея", to: menu) }
        }
        menu.addItem(.separator())
        let login = add("Запускать при входе в macOS", action: #selector(toggleLoginAtLaunch), to: menu)
        login.state = loginAtLaunch.state
        login.isEnabled = !loginAtLaunch.isChanging
        login.toolTip = loginAtLaunch.statusDescription
        if loginAtLaunch.state == .mixed {
            add("Подтвердить автозапуск в настройках macOS…", action: #selector(openLoginSettings), to: menu)
        }
        if let error = loginAtLaunch.lastError { add(error, to: menu) }
        menu.addItem(.separator())
        add("Проверить работу…", action: #selector(showDiagnostics), to: menu)
        add("Завершить SSwitcher", action: #selector(quit), to: menu)
    }

    @discardableResult
    private func add(_ title: String, action: Selector? = nil, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        menu.addItem(item)
        return item
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        UserDefaults.standard.set(!enabled, forKey: "paused")
        monitor.focusChanged()
        refreshPermissions()
        rebuildMenu()
    }

    @objc private func toggleWindowMovement() {
        windowMovementEnabled.toggle()
        UserDefaults.standard.set(!windowMovementEnabled, forKey: "windowMovementDisabled")
        refreshPermissions()
        rebuildMenu()
    }

    @objc private func requestPermission() {
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        if !monitor.start(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        refreshPermissions()
        rebuildMenu()
    }

    @objc private func toggleSmoothReplacement() {
        ReplacementOverlay.enabled.toggle()
        if !ReplacementOverlay.enabled { editor.overlay.cancel() }
        rebuildMenu()
    }

    @objc private func requestScreenCapture() {
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
            self.rebuildMenu()
        }
        rebuildMenu()
    }
    @objc private func openLoginSettings() { loginAtLaunch.openSettings() }

    @objc private func showDiagnostics() {
        refreshPermissions()
        if diagnosticsWindow == nil {
            diagnosticsWindow = DiagnosticsWindow(readStatus: { [weak self] in
                guard let self else { return "" }
                return [
                    "Универсальный доступ: \(AXIsProcessTrusted() ? "разрешён" : "не выдан")",
                    "Мониторинг ввода: \(CGPreflightListenEventAccess() ? "разрешён" : "не выдан")",
                    "Отправка клавиш: \(CGPreflightPostEventAccess() ? "разрешена" : "не разрешена")",
                    "Слежение за клавишами: \(self.monitor.isRunning ? "работает" : "не запущено")",
                    "Событий Shift: \(self.monitor.shiftEventCount); двойных нажатий: \(self.monitor.doubleShiftCount)",
                    "Синтетических событий клавиатуры: \(self.monitor.syntheticEventCount)",
                    self.loginAtLaunch.statusDescription,
                    "Последняя попытка: \(self.lastAttempt)",
                    self.lastResult,
                    self.editor.diagnosticDetails,
                    self.windowMoves.lastResult,
                    self.editor.overlay.lastStatus,
                    self.editor.performance.diagnosticStatus
                ].joined(separator: "\n")
            }, runCheck: { [weak self] in self?.monitor.triggerForDiagnostics() },
               requestCapture: { [weak self] in self?.requestScreenCapture() })
        }
        diagnosticsWindow?.present()
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
        windowHotKeys.stop()
        windowMoves.cancel()
        permissionTimer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        monitor.stop()
        editor.shutdown()
    }
}

// Keep the lease alive globally; a refused second launch never constructs the
// delegate, installs an observer, creates an icon or starts a keyboard tap.
guard let instanceClaim = SingleInstance.claim() else { exit(EXIT_SUCCESS) }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(instanceClaim) { app.run() }
