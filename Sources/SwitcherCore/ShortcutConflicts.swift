/// Finds what already uses a shortcut or a double tap before Settings apply
/// it: macOS keyboard shortcuts (System Settings → Keyboard → Keyboard
/// Shortcuts, stored in `com.apple.symbolichotkeys`), the usual application
/// commands, and SSwitcher's own shortcuts. Probing other applications'
/// registrations happens in the app.
public enum ShortcutConflicts {
    public struct SystemShortcut: Equatable {
        public let id: Int
        public let shortcut: KeyShortcut
        public let enabled: Bool
    }

    /// A double-tap ("modifier") system shortcut, such as Dictation set to
    /// "Press Control Key Twice".
    public struct SystemDoubleTap: Equatable {
        public let id: Int
        public let modifiers: KeyShortcut.Modifiers
    }

    /// Parses `AppleSymbolicHotKeys`. Parameters are (character, key code,
    /// NSEvent modifier flags); 65535 means none. The Fn flag that macOS adds
    /// to function keys is ignored.
    public static func parse(_ plist: [String: Any]?) -> (shortcuts: [SystemShortcut], doubleTaps: [SystemDoubleTap]) {
        var shortcuts: [SystemShortcut] = [], taps: [SystemDoubleTap] = []
        for (key, raw) in plist ?? [:] {
            guard let id = Int(key), let entry = raw as? [String: Any] else { continue }
            let enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int).map { $0 != 0 } ?? false)
            guard let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [Int],
                  parameters.count >= 3 else {
                shortcuts.append(SystemShortcut(id: id, shortcut: KeyShortcut(keyCode: 0xFFFF, modifiers: []), enabled: false))
                continue
            }
            let modifiers = modifiers(fromEventFlags: parameters[2])
            if value["type"] as? String == "modifier" {
                if enabled && !modifiers.isEmpty { taps.append(SystemDoubleTap(id: id, modifiers: modifiers)) }
                continue
            }
            let code = parameters[1]
            shortcuts.append(SystemShortcut(id: id, shortcut: KeyShortcut(keyCode: UInt32(clamping: code == 65535 ? 0xFFFF : code),
                                                                           modifiers: modifiers), enabled: enabled && code != 65535))
        }
        return (shortcuts, taps)
    }

    public static func modifiers(fromEventFlags flags: Int) -> KeyShortcut.Modifiers {
        var result: KeyShortcut.Modifiers = []
        if flags & 0x20000 != 0 { result.insert(.shift) }
        if flags & 0x40000 != 0 { result.insert(.control) }
        if flags & 0x80000 != 0 { result.insert(.option) }
        if flags & 0x100000 != 0 { result.insert(.command) }
        return result
    }

    /// The name of the macOS shortcut `shortcut` collides with, or nil.
    /// Entries in the preference override the built-in defaults by id; a
    /// disabled entry frees its shortcut.
    public static func systemConflict(_ shortcut: KeyShortcut, stored: [SystemShortcut]) -> String? {
        var active: [Int: KeyShortcut] = [:]
        for (id, value) in defaults { active[id] = value.shortcut }
        for entry in stored { active[entry.id] = entry.enabled ? entry.shortcut : nil }
        if let id = active.filter({ $0.value == shortcut }).keys.min() {
            return names[id] ?? defaults[id]?.name ?? "сочетание macOS №\(id)"
        }
        return fixed.first { $0.shortcut == shortcut }?.name
    }

    /// Standard commands that applications reserve (⌘S, ⇧⌘Z and so on).
    public static func applicationConflict(_ shortcut: KeyShortcut) -> String? {
        if let name = applicationCommands[shortcut] { return name }
        if shortcut.modifiers.isSubset(of: [.command, .shift]) && shortcut.modifiers.contains(.command) && shortcut.keyCode < 51 {
            return "команды программ: сочетания с одной ⌘ заняты почти везде"
        }
        return nil
    }

    /// A double tap of `trigger` that macOS also listens for.
    public static func doubleTapConflict(_ trigger: TriggerKey, stored: [SystemDoubleTap]) -> String? {
        guard let tap = stored.first(where: { $0.modifiers.contains(trigger.modifier) }) else { return nil }
        return names[tap.id] ?? "двойное нажатие в macOS (№\(tap.id))"
    }

    /// What modifiers + arrow already do: a macOS shortcut first, then the
    /// text-editing meaning in ordinary editors.
    public static func arrowConflict(_ modifiers: KeyShortcut.Modifiers, _ direction: WindowMoveDirection,
                                     stored: [SystemShortcut]) -> String? {
        let code: UInt32
        switch direction { case .left: code = 123; case .right: code = 124; case .down: code = 125; case .up: code = 126 }
        if let system = systemConflict(KeyShortcut(keyCode: code, modifiers: modifiers), stored: stored) { return system }
        let horizontal = direction == .left || direction == .right
        switch modifiers {
        case [.option]: return horizontal ? "переход по словам в тексте" : "переход по абзацам в тексте"
        case [.option, .shift]: return horizontal ? "выделение по словам в тексте" : "выделение по абзацам в тексте"
        case [.command]: return horizontal ? "переход к началу и концу строки" : "переход к началу и концу текста"
        case [.command, .shift]: return horizontal ? "выделение до начала и конца строки" : "выделение до начала и конца текста"
        default: return nil
        }
    }

    // MARK: Data

    private static func s(_ key: UInt32, _ modifiers: KeyShortcut.Modifiers) -> KeyShortcut { KeyShortcut(keyCode: key, modifiers: modifiers) }

    /// Default macOS shortcuts by symbolic id, for entries the preference omits.
    static let defaults: [Int: (shortcut: KeyShortcut, name: String)] = [
        7: (s(120, .control), "Фокус на строку меню"),
        8: (s(99, .control), "Фокус на Dock"),
        9: (s(118, .control), "Фокус на активное окно"),
        12: (s(122, .control), "Управление с клавиатуры"),
        15: (s(28, [.option, .command]), "Увеличение"),
        27: (s(50, .command), "Следующее окно"),
        28: (s(20, [.shift, .command]), "Снимок экрана"),
        29: (s(20, [.control, .shift, .command]), "Снимок экрана в буфер"),
        30: (s(21, [.shift, .command]), "Снимок области"),
        31: (s(21, [.control, .shift, .command]), "Снимок области в буфер"),
        32: (s(126, .control), "Mission Control"),
        33: (s(125, .control), "Окна программы"),
        52: (s(2, [.option, .command]), "Скрыть Dock"),
        59: (s(96, .command), "VoiceOver"),
        60: (s(49, .control), "Предыдущий источник ввода"),
        61: (s(49, [.control, .option]), "Следующий источник ввода"),
        64: (s(49, .command), "Поиск Spotlight"),
        65: (s(49, [.option, .command]), "Поиск в Finder"),
        79: (s(123, .control), "Рабочий стол слева"),
        81: (s(124, .control), "Рабочий стол справа"),
        162: (s(96, [.option, .command]), "Универсальный доступ"),
        184: (s(23, [.shift, .command]), "Снимки и запись экрана")
    ]

    static let names: [Int: String] = [
        7: "Фокус на строку меню", 8: "Фокус на Dock", 9: "Фокус на активное окно", 10: "Фокус на панель окна",
        11: "Фокус на плавающее окно", 12: "Управление с клавиатуры", 13: "Переход по Tab", 15: "Увеличение",
        17: "Увеличить масштаб", 19: "Уменьшить масштаб", 21: "Инверсия цвета", 25: "Больше контраста", 26: "Меньше контраста",
        27: "Следующее окно", 28: "Снимок экрана", 29: "Снимок экрана в буфер", 30: "Снимок области", 31: "Снимок области в буфер",
        32: "Mission Control", 33: "Окна программы", 36: "Показать рабочий стол", 52: "Скрыть Dock", 57: "Фокус на меню статуса",
        59: "VoiceOver", 60: "Предыдущий источник ввода", 61: "Следующий источник ввода", 64: "Поиск Spotlight",
        65: "Поиск в Finder", 79: "Рабочий стол слева", 81: "Рабочий стол справа", 118: "Рабочий стол 1", 119: "Рабочий стол 2",
        120: "Рабочий стол 3", 121: "Рабочий стол 4", 160: "Launchpad", 162: "Универсальный доступ", 163: "Центр уведомлений",
        164: "Диктовка", 175: "Не беспокоить", 184: "Снимки и запись экрана", 190: "Быстрая заметка"
    ]

    /// Built into macOS and not listed in the preference.
    static let fixed: [(shortcut: KeyShortcut, name: String)] = [
        (s(12, [.control, .command]), "Заблокировать экран"),
        (s(49, [.control, .command]), "Эмодзи и символы"),
        (s(53, [.option, .command]), "Завершить принудительно"),
        (s(12, [.shift, .command]), "Завершить сеанс"),
        (s(3, [.control, .command]), "Полноэкранный режим"),
        (s(44, [.shift, .command]), "Поиск в меню «Справка»"),
        (s(48, .command), "Переключение программ")
    ]

    static let applicationCommands: [KeyShortcut: String] = [
        s(6, [.shift, .command]): "Повторить",
        s(1, [.shift, .command]): "Сохранить как",
        s(45, [.shift, .command]): "Новая папка",
        s(31, [.option, .command]): "Открыть в программе",
        s(4, [.option, .command]): "Скрыть остальные",
        s(46, [.option, .command]): "Свернуть все",
        s(13, [.option, .command]): "Закрыть все окна",
        s(9, [.option, .shift, .command]): "Вставить без оформления",
        s(3, [.control, .command]): "Полноэкранный режим"
    ]
}
