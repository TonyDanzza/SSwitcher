import AppKit
import Carbon
import SwitcherCore

/// Looks for what already uses a shortcut, an arrow combination or a double
/// tap, and asks before Settings take it over.
enum ShortcutChecks {
    static func systemEntries() -> (shortcuts: [ShortcutConflicts.SystemShortcut], doubleTaps: [ShortcutConflicts.SystemDoubleTap]) {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        return ShortcutConflicts.parse(CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any])
    }

    /// Another running program registered it exclusively. SSwitcher's own
    /// shortcuts are unregistered while a field records, so they never count.
    static func isTakenByAnotherProgram(_ shortcut: KeyShortcut) -> Bool {
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers.rawValue,
                                         EventHotKeyID(signature: 0x53535052, id: 99), // SSPR
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        if result == noErr, let reference { UnregisterEventHotKey(reference); return false }
        return true
    }

    static func conflicts(for shortcut: KeyShortcut) -> [String] {
        var found: [String] = []
        if let name = ShortcutConflicts.systemConflict(shortcut, stored: systemEntries().shortcuts) { found.append("В macOS: «\(name)».") }
        if let name = ShortcutConflicts.applicationConflict(shortcut) { found.append("В программах: \(name).") }
        if isTakenByAnotherProgram(shortcut) { found.append("Его уже заняла другая запущенная программа.") }
        return found
    }

    static func conflicts(forArrows modifiers: KeyShortcut.Modifiers, directions: Set<WindowMoveDirection>) -> [String] {
        let stored = systemEntries().shortcuts
        return WindowMoveDirection.allCases.filter(directions.contains).compactMap { direction in
            ShortcutConflicts.arrowConflict(modifiers, direction, stored: stored).map {
                "\(modifiers.symbols)\(WindowShortcutDirections.arrow(direction)): \($0)."
            }
        }
    }

    static func conflicts(forDoubleTap trigger: TriggerKey) -> [String] {
        var found: [String] = []
        if let name = ShortcutConflicts.doubleTapConflict(trigger, stored: systemEntries().doubleTaps) {
            found.append("В macOS: «\(name)» тоже включается двойным \(trigger.symbol).")
        }
        let watchers = ["com.raycast.macos": "Raycast", "com.runningwithcrayons.Alfred": "Alfred", "com.lwouis.alt-tab-macos": "AltTab"]
        if trigger != .shift {
            for app in NSWorkspace.shared.runningApplications {
                if let id = app.bundleIdentifier, let name = watchers[id] {
                    found.append("Запущен \(name): в нём можно назначить двойное нажатие \(trigger.symbol), проверьте его настройки.")
                }
            }
        }
        return found
    }

    /// true when nothing is in the way or the user chose to take it anyway.
    static func confirm(_ subject: String, conflicts: [String], in window: NSWindow?) -> Bool {
        guard !conflicts.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(subject) уже используется"
        alert.informativeText = conflicts.joined(separator: "\n") + "\n\nЕсли назначить, там оно может перестать работать, пока запущен SSwitcher."
        alert.addButton(withTitle: "Выбрать другое")
        alert.addButton(withTitle: "Всё равно назначить")
        window?.makeKeyAndOrderFront(nil)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
