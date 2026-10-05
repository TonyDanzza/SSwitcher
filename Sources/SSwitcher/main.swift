import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = KeyboardMonitor()
    private var enabled = !UserDefaults.standard.bool(forKey: "paused")
    private var lastError: String?
    private var permissionTimer: Timer?

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
            self.lastError = TextEditor.convertAtCursor()
            self.statusItem.button?.toolTip = self.lastError ?? "SSwitcher — двойной Shift исправляет раскладку текста"
            if self.lastError != nil { NSSound.beep() }
        }
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
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        add("SSwitcher", to: menu)
        add("Раскладка: \(InputSources.currentName)", to: menu)
        add(enabled ? (monitor.isRunning && AXIsProcessTrusted() ? "Двойной Shift включён" : "Нужны разрешения macOS") : "На паузе", to: menu)
        menu.addItem(.separator())
        add("Двойной Shift: слово или выделенный текст", to: menu)
        if let lastError { add(lastError, to: menu) }
        let toggle = add("Исправлять по двойному Shift", action: #selector(toggleEnabled), to: menu)
        toggle.state = enabled ? .on : .off
        if !monitor.isRunning && enabled {
            add("Разрешить мониторинг ввода…", action: #selector(requestPermission), to: menu)
        }
        if !AXIsProcessTrusted() {
            add("Разрешить универсальный доступ…", action: #selector(requestAccessibility), to: menu)
        }
        menu.addItem(.separator())
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
        monitor.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
