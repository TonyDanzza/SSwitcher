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
    private let nativeServices = NativeServiceProvider()
    private var windowMovementEnabled = !UserDefaults.standard.bool(forKey: "windowMovementDisabled")
    private var enabled = !UserDefaults.standard.bool(forKey: "paused")
    private var lastAttempt = "Ещё не срабатывал"
    private var lastResult = "Ожидание двойного Shift"
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var permissionRetries = 0
    private var diagnosticsWindow: DiagnosticsWindow?
    private var typedReplacementActive = false
    private static let maxBundleID = "ru.oneme.desktop"

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
        windowMoves.onResult = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.toolTip = self.windowMoves.lastResult
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.nativeServices.cancelVisualShield()
            self?.refreshWindowShortcuts()
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
        monitor.canStartConversion = { [weak self] in
            self?.enabled == true && self?.editor.isConverting == false && self?.nativeServices.isConverting == false &&
                self?.typedReplacementActive == false
        }
        monitor.onDoubleShift = { [weak self] in
            guard let self, self.enabled, !self.editor.isConverting, !self.nativeServices.isConverting,
                  !self.typedReplacementActive, self.monitor.claimConversion() else { return }
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
            if let max = NSWorkspace.shared.frontmostApplication, max.bundleIdentifier == Self.maxBundleID {
                self.editor.performance.cancelGesture()
                let candidate = self.monitor.typedWordCandidate
                let kind: String
                switch candidate { case .unknown: kind = "unknown"; case .afterSpace: kind = "afterSpace"; case .word: kind = "word" }
                DiagnosticReports.shared.record("TypedWordStateReport", ["candidate": kind, "tracking": self.monitor.tracksTypedWord,
                    "lastReset": self.monitor.typedWordReset, "keysSinceReset": self.monitor.typedKeysSinceReset,
                    "translatedKeys": self.monitor.translatedKeysSinceReset, "timestamp": Date().timeIntervalSince1970])
                if case .word(let word, let boundedStart) = candidate,
                   self.retypeMaxWord(word, boundedStart: boundedStart, pid: max.processIdentifier, generation: generation) { return }
                // A typed word after a space may have been autocorrected, so
                // the editor's own text is read with one native request.
                let direct = self.monitor.selectionKnownEmpty
                // Option-Shift-Left is also Qt's word-selection command.
                // Exclusive Carbon registrations consume it even when their
                // callback declines the move. Release them for this finite
                // transaction, then restore the user's current preference.
                self.windowHotKeys.stop()
                self.windowMoves.cancel()
                let started = ProcessInfo.processInfo.systemUptime
                self.nativeServices.convertAtCursor(valid: { [weak self] in
                    self?.monitor.inputGeneration == generation
                }, knownNoSelection: direct) { [weak self] outcome, target in
                    guard let self else { return }
                    self.refreshWindowShortcuts()
                    self.monitor.conversionFinished(unverified: outcome == .unverified)
                    DiagnosticReports.shared.record("MaxServiceRouteReport", ["direct": direct, "outcome": String(describing: outcome),
                        "elapsedMS": Int((ProcessInfo.processInfo.systemUptime - started) * 1000)])
                    switch outcome {
                    case .submitted:
                        if let target { InputSources.selectAfterConversion(target) }
                        if let text = self.nativeServices.lastDirectConversion { self.monitor.assumeTypedWord(text) }
                        self.lastResult = "Текст передан нативному редактору MAX"
                    case .unavailable: self.lastResult = self.nativeServices.conversionStatus
                    case .cancelled: self.lastResult = "Замена отменена: ввод или активное окно изменились"
                    case .unverified: self.lastResult = "Результат замены MAX не подтверждён; проверьте текст"
                    }
                    self.statusItem.button?.toolTip = self.lastResult
                }
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
            self.nativeServices.cancelVisualShield()
            self.windowMoves.cancel()
            self.editor.overlay.cancel()
            self.refreshPermissions()
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
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

    /// A direct MAX word request will need a snapshot; start it during the
    /// Shift quiet interval instead of after it.
    private func prepareEarlyMaxShield() {
        guard enabled, monitor.tracksTypedWord, monitor.selectionKnownEmpty, !editor.isConverting,
              !nativeServices.isConverting, !typedReplacementActive,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.maxBundleID else { return }
        if case .word = monitor.typedWordCandidate { return }
        let generation = monitor.inputGeneration
        nativeServices.prepareEarlyShield(valid: { [weak self] in self?.monitor.inputGeneration == generation })
    }

    /// Typed characters are kept only for MAX and only while conversion is on.
    private func refreshTypedWordTracking(frontmost: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        monitor.tracksTypedWord = enabled && frontmost?.bundleIdentifier == Self.maxBundleID
    }

    /// MAX path for a word the user has just typed, as layout switchers do:
    /// delete exactly its characters and type the converted text. No
    /// selection, Services call, Accessibility read or clipboard. Returns false
    /// before any key is sent when the native Services route must decide.
    private func retypeMaxWord(_ word: String, boundedStart: Bool, pid: pid_t, generation: UInt64) -> Bool {
        guard let count = TypedWordTracker.backspaceCount(for: word), let conversion = InputSources.prepare(word),
              !IsSecureEventInputEnabled(), CGPreflightPostEventAccess() else { return false }
        guard conversion.text != word else {
            lastResult = "Слово не требует замены"
            monitor.conversionFinished(unverified: false)
            statusItem.button?.toolTip = lastResult
            return true
        }
        let asOneWord = TypedWordTracker.deletesAsOneWord(word, boundedStart: boundedStart)
        guard let input = UnicodeTextInput(text: conversion.text),
              let batches = input.makeEventBatches(deletingCharacters: count, asOneWord: asOneWord) else { return false }
        typedReplacementActive = true
        let release = monitor.lastGestureRelease
        KeyboardEvents.postTextReplacement(batches, targetPID: pid, interval: 0, valid: { [weak self] in
            guard let self else { return false }
            return self.monitor.inputGeneration == generation && !IsSecureEventInputEnabled() &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }, modifiersClear: { [weak self] in self?.monitor.observedModifiersClear == true }) { [weak self] delivered in
            guard let self else { return }
            self.typedReplacementActive = false
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - release) * 1000)
            if delivered {
                self.monitor.replaceTypedWord(word, with: conversion.text)
                self.monitor.assumeSelectionEmpty()
                InputSources.selectAfterConversion(conversion.target)
                self.lastResult = "Слово MAX перепечатано без выделения (\(elapsed) мс)"
            } else {
                self.monitor.forgetTypedWord("interrupted")
                self.lastResult = "Замена в MAX прервана вводом; проверьте текст"
            }
            DiagnosticReports.shared.record("TypedWordReplacementReport", ["delivered": delivered, "oneWordDeletion": asOneWord,
                "characters": count, "elapsedMS": elapsed])
            self.monitor.conversionFinished(unverified: !delivered)
            self.statusItem.button?.toolTip = self.lastResult
        }
        return true
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
        if windowMovementEnabled && !nativeServices.isConverting && AXIsProcessTrusted() &&
            CGPreflightListenEventAccess() && monitor.isRunning && frames.count >= 2 {
            windowHotKeys.start()
        } else {
            windowHotKeys.stop()
            windowMoves.cancel()
        }
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        add("SSwitcher \(DiagnosticReports.version)", to: menu)
        add("Раскладка: \(InputSources.currentName)", to: menu)
        add(enabled ? (monitor.isRunning && AXIsProcessTrusted() ? "Двойной Shift включён" : "Нужны разрешения macOS") : "На паузе", to: menu)
        menu.addItem(.separator())
        add("Двойной Shift: выделение или слово при курсоре в его конце", to: menu)
        add("Последний двойной Shift: \(lastAttempt)", to: menu)
        add(lastResult, to: menu)
        let toggle = add("Исправлять по двойному Shift", action: #selector(toggleEnabled), to: menu)
        toggle.state = enabled ? .on : .off
        let smooth = add("Плавная замена", action: #selector(toggleSmoothReplacement), to: menu)
        smooth.state = ReplacementOverlay.enabled ? .on : .off
        if !CGPreflightScreenCaptureAccess() {
            add("Разрешить запись экрана для плавной замены…", action: #selector(requestScreenCapture), to: menu)
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
        refreshTypedWordTracking()
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
        presentDiagnostics(activateApplication: true)
    }

    private func presentDiagnostics(activateApplication: Bool) {
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
                    self.editor.performance.diagnosticStatus,
                    self.nativeServices.conversionStatus
                ].joined(separator: "\n")
            }, runCheck: { [weak self] in self?.monitor.triggerForDiagnostics() },
               requestCapture: { [weak self] in self?.requestScreenCapture() })
        }
        diagnosticsWindow?.present(activateApplication: activateApplication)
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
