import AppKit
import SwitcherCore

/// Every user choice, stored in UserDefaults. Keys from earlier builds keep
/// their names and meaning, so an update changes nothing. Views bind to the
/// published values; `onChange` lets the app apply them.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let intervalRange = 0.2...0.5
    var onChange: (() -> Void)?
    private let defaults = UserDefaults.standard

    // Double Shift
    @Published var conversionEnabled: Bool { didSet { save(!conversionEnabled, "paused") } }
    @Published var smoothReplacement: Bool { didSet { save(!smoothReplacement, "disableSmoothReplacement") } }
    @Published var triggerKey: TriggerKey { didSet { save(triggerKey.rawValue, "doubleTapKey") } }
    /// Stored under the build 179 key, when only Shift could be chosen.
    @Published var triggerSide: TriggerSide { didSet { save(triggerSide.rawValue, "doubleShiftKeys") } }
    @Published var doubleShiftInterval: Double { didSet { save(doubleShiftInterval, "doubleShiftInterval") } }
    @Published var excludedApplications: [String] { didSet { save(excludedApplications, "conversionExcludedApplications") } }
    @Published var beepOnFailure: Bool { didSet { save(!beepOnFailure, "beepOnFailureDisabled") } }

    // General
    @Published var showNotices: Bool { didSet { save(!showNotices, "noticesDisabled") } }

    // Windows
    @Published var windowMovementEnabled: Bool { didSet { save(!windowMovementEnabled, "windowMovementDisabled") } }
    @Published var windowDirectionsManual: Bool { didSet { save(windowDirectionsManual, "windowDirectionsManual") } }
    @Published var windowDirections: Set<WindowMoveDirection> {
        didSet { save(windowDirections.map { Int($0.rawValue) }.sorted(), "windowDirections") }
    }
    @Published var windowModifiers: KeyShortcut.Modifiers { didSet { save(Int(windowModifiers.rawValue), "windowModifiers") } }

    // Top row
    @Published var functionKeyShortcut: KeyShortcut? { didSet { saveShortcut(functionKeyShortcut, "functionKeyShortcut") } }

    // Keep awake
    @Published var keepAwakeSystemOnly: Bool { didSet { save(keepAwakeSystemOnly, "keepAwakeSystemOnly") } }
    @Published var keepAwakeBatteryPercent: Int { didSet { save(keepAwakeBatteryPercent, "keepAwakeBatteryPercent") } }
    @Published var keepAwakeStopOnUnplug: Bool { didSet { save(keepAwakeStopOnUnplug, "keepAwakeStopOnUnplug") } }
    @Published var keepAwakeShortcut: KeyShortcut? { didSet { saveShortcut(keepAwakeShortcut, "keepAwakeShortcut") } }
    /// 0 means "until turned off".
    @Published var keepAwakeShortcutMinutes: Int { didSet { save(keepAwakeShortcutMinutes, "keepAwakeShortcutMinutes") } }

    // Mouse
    @Published var mouseWheelReversed: Bool { didSet { save(mouseWheelReversed, "mouseWheelReversed") } }
    @Published var mouseButtons: [MouseButtonBinding] { didSet { save(mouseButtons.map(\.storage), "mouseButtonBindings") } }

    var windowDirectionChoice: WindowDirectionChoice { windowDirectionsManual ? .manual(windowDirections) : .automatic }

    private init() {
        let d = UserDefaults.standard
        conversionEnabled = !d.bool(forKey: "paused")
        smoothReplacement = !d.bool(forKey: "disableSmoothReplacement")
        triggerKey = TriggerKey(rawValue: d.integer(forKey: "doubleTapKey")) ?? .shift
        triggerSide = TriggerSide(rawValue: d.integer(forKey: "doubleShiftKeys")) ?? .any
        let interval = d.double(forKey: "doubleShiftInterval")
        doubleShiftInterval = Self.intervalRange.contains(interval) ? interval : 0.3
        excludedApplications = d.stringArray(forKey: "conversionExcludedApplications") ?? []
        beepOnFailure = !d.bool(forKey: "beepOnFailureDisabled")
        showNotices = !d.bool(forKey: "noticesDisabled")
        windowMovementEnabled = !d.bool(forKey: "windowMovementDisabled")
        windowDirectionsManual = d.bool(forKey: "windowDirectionsManual")
        let directions = (d.array(forKey: "windowDirections") as? [Int] ?? [1, 2, 3, 4])
            .compactMap { WindowMoveDirection(rawValue: UInt32(clamping: $0)) }
        windowDirections = Set(directions)
        let modifiers = KeyShortcut.Modifiers(rawValue: UInt32(clamping: d.object(forKey: "windowModifiers") as? Int ?? 0))
        windowModifiers = modifiers.hasShortcutModifier ? modifiers : [.option, .shift]
        functionKeyShortcut = d.object(forKey: "functionKeyShortcut") == nil
            ? .functionKeyToggle : KeyShortcut(storage: d.dictionary(forKey: "functionKeyShortcut"))
        keepAwakeSystemOnly = d.bool(forKey: "keepAwakeSystemOnly")
        let percent = d.integer(forKey: "keepAwakeBatteryPercent")
        keepAwakeBatteryPercent = KeepAwakeBatteryRule.percentRange.contains(percent) ? percent : KeepAwakeBatteryRule.minimumPercent
        keepAwakeStopOnUnplug = d.bool(forKey: "keepAwakeStopOnUnplug")
        keepAwakeShortcut = KeyShortcut(storage: d.dictionary(forKey: "keepAwakeShortcut"))
        keepAwakeShortcutMinutes = d.object(forKey: "keepAwakeShortcutMinutes") as? Int ?? 60
        mouseWheelReversed = d.bool(forKey: "mouseWheelReversed")
        mouseButtons = MouseButtonBinding.list(from: d.array(forKey: "mouseButtonBindings") as? [[String: Any]] ?? [])
    }

    /// "Двойной Shift", "Двойной левый ⌥".
    var triggerPhrase: String { triggerSide.phrase(triggerKey) }

    func isExcluded(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return excludedApplications.contains(id)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }

    /// An explicitly cleared shortcut is stored as an empty dictionary, so the
    /// default does not come back on the next launch.
    private func saveShortcut(_ shortcut: KeyShortcut?, _ key: String) {
        save(shortcut?.storage ?? [:], key)
    }
}

/// Names for shortcut fields and menus: "⌃⌥⌘F", "⌥⇧↑".
enum KeyNames {
    static func string(_ shortcut: KeyShortcut) -> String { shortcut.modifiers.symbols + key(shortcut.keyCode) }

    static func isFunctionKey(_ code: UInt32) -> Bool { functionKeys[code] != nil }

    static func key(_ code: UInt32) -> String {
        if let name = special[code] { return name }
        if let function = functionKeys[code] { return "F\(function)" }
        return InputSources.asciiCharacter(forKeyCode: UInt16(code))?.uppercased() ?? "#\(code)"
    }

    private static let special: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Пробел", 51: "⌫", 53: "⎋", 117: "⌦", 76: "⌤",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟"
    ]
    private static let functionKeys: [UInt32: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12,
        105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20
    ]
}
