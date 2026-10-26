import AppKit
import Carbon
import InputMethodSupport
import SwitcherCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // Internal members are shared with the AppDelegate+Menu, +Settings and
    // +Permissions extensions.
    private(set) var statusItem: NSStatusItem!
    let monitor = KeyboardMonitor()
    private let editor = ConversionCoordinator()
    let loginAtLaunch = LoginAtLaunch()
    let windowMoves = WindowMoveController()
    let windowHotKeys = WindowMoveHotKeys()
    let functionKeys = FunctionKeyController()
    let keepAwake = KeepAwakeController()
    let keyboardLock = KeyboardLock()
    let displayController = DisplayController()
    let mouse = MouseController()
    private let nativeServices = NativeServiceProvider()
    private lazy var maxRouter = MaxConversionRouter(monitor: monitor, services: nativeServices)
    let settings = AppSettings.shared
    let settingsStatus = SettingsStatus()
    var settingsWindow: SettingsWindowController?
    var settingsTimer: Timer?
    var isRecordingShortcut = false
    lazy var layoutRow = MenuSwitchRow(title: "Раскладка")
    lazy var windowsRow = MenuSwitchRow(title: "Перенос окон")
    lazy var functionRow = MenuSwitchRow(title: "Fn")
    private var appliedConversionEnabled = AppSettings.shared.conversionEnabled
    var windowMovementEnabled: Bool { settings.windowMovementEnabled }
    var enabled: Bool { settings.conversionEnabled }
    private(set) var lastAttempt = "Ещё не было"
    private(set) var lastResult = "Ещё не срабатывало"
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    var permissionTimer: Timer?
    var permissionRetries = 0
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
            let changed = InputSources.sourceChanged()
            self.monitor.keyboardLayoutChanged()
            if changed { self.monitor.focusChanged() }
        }
        windowHotKeys.onMove = { [weak self] direction in
            guard let self else { return }
            self.refreshWindowShortcuts()
            guard self.windowHotKeys.isRegistered else { return }
            self.monitor.focusChanged()
            self.windowMoves.move(direction)
        }
        keepAwake.onChange = { [weak self] in self?.refreshStatusIcon(); self?.refreshSettingsStatus() }
        functionKeys.setShortcut(settings.functionKeyShortcut)
        functionKeys.frontmostChanged()
        keepAwake.setShortcut(settings.keepAwakeShortcut)
        settings.onChange = { [weak self] in self?.settingsChanged() }
        applyDoubleShiftSettings()
        applyMouseSettings()
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
        monitor.onGestureDropped = { reason in
            DiagnosticReports.shared.appendHistory(["result": "dropped", "reason": reason])
        }
        monitor.canStartConversion = { [weak self] in
            self?.enabled == true && self?.editor.isConverting == false && self?.maxRouter.isConverting == false &&
                self?.settings.isExcluded(NSWorkspace.shared.frontmostApplication) == false
        }
        monitor.onDoubleShift = { [weak self] in
            guard let self, self.enabled, !self.editor.isConverting, !self.maxRouter.isConverting,
                  !self.settings.isExcluded(NSWorkspace.shared.frontmostApplication),
                  self.monitor.claimConversion() else {
                DiagnosticReports.shared.appendHistory(["result": "dropped", "reason": "notClaimed"])
                return
            }
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
            if let max = NSWorkspace.shared.frontmostApplication, MaxConversionRouter.isMax(max) {
                self.editor.performance.cancelGesture()
                self.maxRouter.convert(in: max, generation: generation)
                return
            }
            self.editor.convertAtCursor(releaseTime: self.monitor.lastGestureRelease, isInputUnchanged: { [weak self] in
                self?.monitor.inputGeneration == generation
            }, modifiersClear: { [weak self] in self?.monitor.physicalModifiersClear == true },
               observedModifiersClear: { [weak self] in self?.monitor.observedModifiersClear == true }) { [weak self] outcome in
                guard let self else { return }
                var entry = self.editor.lastSummary
                switch outcome {
                case .ignored: entry["result"] = "ignored"
                case .cancelled: entry["result"] = "cancelled"
                case .converted: entry["result"] = "converted"
                case .unverified: entry["result"] = "unverified"
                case .failure: entry["result"] = "failure"
                }
                DiagnosticReports.shared.appendHistory(entry)
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

    /// Arrows follow the display arrangement unless Settings choose them;
    /// nothing registers with one display, so every arrow keeps its meaning.
    var windowShortcutDirections: Set<WindowMoveDirection> {
        WindowShortcutDirections.resolve(settings.windowDirectionChoice, displays: WindowMoveController.currentDisplays())
    }

    var displayCount: Int {
        NSScreen.screens.map(\.frame).reduce(into: [CGRect]()) { unique, frame in
            if !unique.contains(frame) { unique.append(frame) }
        }.count
    }

    func refreshWindowShortcuts() {
        let directions = windowShortcutDirections
        if windowMovementEnabled && !nativeServices.isConverting && AXIsProcessTrusted() &&
            CGPreflightListenEventAccess() && monitor.isRunning && displayCount >= 2 && !directions.isEmpty {
            windowHotKeys.start(directions: directions, modifiers: settings.windowModifiers)
        } else {
            windowHotKeys.stop()
            windowMoves.cancel()
        }
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
        applyMouseSettings()
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

    private func applyMouseSettings() {
        mouse.configure(reverseWheel: settings.mouseWheelReversed, bindings: settings.mouseButtons)
    }

    // MARK: Diagnostics

    func presentDiagnostics(activateApplication: Bool) {
        refreshPermissions()
        if diagnosticsWindow == nil {
            diagnosticsWindow = DiagnosticsWindow(readStatus: { [weak self] in self?.diagnosticsText() ?? "" },
                runCheck: { [weak self] in self?.monitor.triggerForDiagnostics() })
        }
        diagnosticsWindow?.present(activateApplication: activateApplication)
    }

    func diagnosticsText() -> String {
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
            mouse.statusDescription,
            editor.performance.diagnosticStatus,
            nativeServices.conversionStatus
        ].joined(separator: "\n")
    }


    func applicationWillTerminate(_ notification: Notification) {
        nativeServices.cancel()
        NSApp.servicesProvider = nil
        windowHotKeys.stop()
        windowMoves.cancel()
        mouse.shutdown()
        functionKeys.restoreBase()
        keepAwake.stop()
        keepAwake.setShortcut(nil)
        keyboardLock.stop(notice: false)
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
