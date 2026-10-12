import AppKit
import SwitcherCore

/// Why window shortcuts are not registered, in the order they are checked.
enum WindowShortcutWaitingReason {
    case accessibility, inputMonitoring, monitorStopped, singleDisplay, noDirections, taken

    var message: String {
        switch self {
        case .accessibility: return "Нужен Универсальный доступ"
        case .inputMonitoring: return "Нужен Мониторинг ввода"
        case .monitorStopped: return "Слежение за вводом не запущено"
        case .singleDisplay: return "Ждёт второго дисплея"
        case .noDirections: return "Стрелки не выбраны"
        case .taken: return "Сочетания заняты другой программой"
        }
    }
}

// MARK: Status menu

extension AppDelegate {
    /// Why window shortcuts are not registered, or nil when they work.
    var windowShortcutWaitingReason: WindowShortcutWaitingReason? {
        guard windowMovementEnabled, !windowHotKeys.isRegistered else { return nil }
        if !AXIsProcessTrusted() { return .accessibility }
        if !CGPreflightListenEventAccess() { return .inputMonitoring }
        if !monitor.isRunning { return .monitorStopped }
        if displayCount < 2 { return .singleDisplay }
        if windowShortcutDirections.isEmpty { return .noDirections }
        if windowHotKeys.lastError != nil { return .taken }
        return nil
    }

    /// Short by design (HIG menu bar extras): problems, frequent toggles,
    /// Settings and Quit. Everything else lives in Settings.
    func rebuildMenu() {
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
    func updateMenuRows() {
        layoutRow.onToggle = { [weak self] on in self?.settings.conversionEnabled = on }
        layoutRow.update(isOn: enabled, details: ["\(settings.triggerPhrase) исправляет текст"])
        windowsRow.onToggle = { [weak self] on in self?.settings.windowMovementEnabled = on }
        let registered = windowHotKeys.isRegistered ? windowHotKeys.directions : []
        let windowDetail = windowShortcutWaitingReason?.message
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

    @objc private func quit() { NSApp.terminate(nil) }
}
