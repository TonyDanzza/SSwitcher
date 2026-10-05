import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = KeyboardMonitor()
    private var enabled = !UserDefaults.standard.bool(forKey: "paused")
    private var lastError: String?
    private var lastAttempt = "Ещё не срабатывал"
    private var lastResult = "Ожидание двойного Shift"
    private var activationObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var diagnosticsWindow: DiagnosticsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⇧⇧"
        statusItem.button?.toolTip = "SSwitcher — двойной Shift исправляет раскладку текста"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        monitor.onDoubleShift = { [weak self] in
            guard let self, self.enabled else { return }
            self.lastAttempt = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.lastResult = "Проверяю поле ввода…"
            let generation = self.monitor.inputGeneration
            TextEditor.convertAtCursor(isInputUnchanged: { [weak self] in
                self?.monitor.inputGeneration == generation
            }) { [weak self] outcome in
                guard let self else { return }
                self.lastError = nil
                switch outcome {
                case .converted: self.lastResult = "Текст заменён — подтверждено редактором"
                case .unverified: self.lastResult = "Вставка отправлена; редактор не подтвердил результат"
                case .failure(let message):
                    self.lastError = message
                    self.lastResult = message
                    NSSound.beep()
                }
                self.statusItem.button?.toolTip = self.lastResult
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                TextEditor.prepareAccessibility(for: app)
            }
        }
        if let app = NSWorkspace.shared.frontmostApplication { TextEditor.prepareAccessibility(for: app) }
        if enabled { monitor.start() }
        rebuildMenu()
        // Also pick up permission granted while System Settings is open.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.enabled else { return }
            if !CGPreflightListenEventAccess() {
                self.monitor.stop()
            } else if !self.monitor.isRunning {
                self.monitor.start()
            }
        }
        if CommandLine.arguments.contains("--check") { showDiagnostics() }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

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
        if !monitor.isRunning && enabled {
            add("Разрешить мониторинг ввода…", action: #selector(requestPermission), to: menu)
        }
        if !AXIsProcessTrusted() {
            add("Разрешить универсальный доступ…", action: #selector(requestAccessibility), to: menu)
        }
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
        lastError = nil
        if enabled { monitor.start() } else { monitor.stop() }
        rebuildMenu()
    }

    @objc private func requestPermission() {
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        if !monitor.start(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        rebuildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showDiagnostics() {
        if diagnosticsWindow == nil {
            diagnosticsWindow = DiagnosticsWindow(readStatus: { [weak self] in
                guard let self else { return "" }
                return [
                    "Универсальный доступ: \(AXIsProcessTrusted() ? "разрешён" : "не выдан")",
                    "Мониторинг ввода: \(CGPreflightListenEventAccess() ? "разрешён" : "не выдан")",
                    "Отправка клавиш: \(CGPreflightPostEventAccess() ? "разрешена" : "не разрешена")",
                    "Слежение за клавишами: \(self.monitor.isRunning ? "работает" : "не запущено")",
                    "Событий Shift: \(self.monitor.shiftEventCount); двойных нажатий: \(self.monitor.doubleShiftCount)",
                    "Доставленных событий вставки: \(self.monitor.syntheticEventCount)",
                    "Последняя попытка: \(self.lastAttempt)",
                    self.lastResult,
                    TextEditor.diagnosticDetails
                ].joined(separator: "\n")
            }, runCheck: { [weak self] in self?.monitor.onDoubleShift?() })
        }
        diagnosticsWindow?.present()
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        monitor.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
