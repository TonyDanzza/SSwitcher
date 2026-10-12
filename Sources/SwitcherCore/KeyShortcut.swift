/// A global shortcut: a virtual key code plus modifier bits that match
/// Carbon's `cmdKey`, `shiftKey`, `optionKey` and `controlKey`.
public struct KeyShortcut: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 0x0100)
        public static let shift = Modifiers(rawValue: 0x0200)
        public static let option = Modifiers(rawValue: 0x0800)
        public static let control = Modifiers(rawValue: 0x1000)
        public static let all: Modifiers = [.control, .option, .shift, .command]

        /// Apple's order: ⌃⌥⇧⌘.
        public var symbols: String {
            [(Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                .filter { contains($0.0) }.map(\.1).joined()
        }
        /// Shift alone changes typed characters; a shortcut needs ⌃, ⌥ or ⌘.
        public var hasShortcutModifier: Bool { !intersection([.command, .option, .control]).isEmpty }
    }

    public enum Problem: Equatable { case needsModifier, reserved, modifierKey }

    public let keyCode: UInt32
    public let modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.all)
    }

    /// Control+Option+Command+F.
    public static let functionKeyToggle = KeyShortcut(keyCode: 3, modifiers: [.control, .option, .command])

    /// F13–F20 exist only on extended keyboards, so they work without modifiers.
    public static let extendedFunctionKeys: Set<UInt32> = [105, 107, 113, 106, 64, 79, 80, 90]
    static let modifierKeys: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    /// System and standard application shortcuts a global registration would break.
    static let reserved: Set<KeyShortcut> = [
        KeyShortcut(keyCode: 12, modifiers: .command),             // ⌘Q
        KeyShortcut(keyCode: 13, modifiers: .command),             // ⌘W
        KeyShortcut(keyCode: 4, modifiers: .command),              // ⌘H
        KeyShortcut(keyCode: 46, modifiers: .command),             // ⌘M
        KeyShortcut(keyCode: 43, modifiers: .command),             // ⌘,
        KeyShortcut(keyCode: 48, modifiers: .command),             // ⌘Tab
        KeyShortcut(keyCode: 48, modifiers: [.command, .shift]),   // ⇧⌘Tab
        KeyShortcut(keyCode: 50, modifiers: .command),             // ⌘`
        KeyShortcut(keyCode: 49, modifiers: .command),             // ⌘Space
        KeyShortcut(keyCode: 49, modifiers: .control),             // ⌃Space
        KeyShortcut(keyCode: 49, modifiers: [.control, .option]),  // ⌃⌥Space
        KeyShortcut(keyCode: 53, modifiers: [.command, .option])   // ⌥⌘Esc
    ]

    public var problem: Problem? {
        if Self.modifierKeys.contains(keyCode) { return .modifierKey }
        if !modifiers.hasShortcutModifier && !Self.extendedFunctionKeys.contains(keyCode) { return .needsModifier }
        if Self.reserved.contains(self) { return .reserved }
        return nil
    }

    public var storage: [String: Int] { ["keyCode": Int(keyCode), "modifiers": Int(modifiers.rawValue)] }

    public init?(storage: [String: Any]?) {
        guard let storage, let key = storage["keyCode"] as? Int, let flags = storage["modifiers"] as? Int,
              (0...0xFF).contains(key), flags >= 0 else { return nil }
        self.init(keyCode: UInt32(key), modifiers: Modifiers(rawValue: UInt32(flags)))
        guard problem == nil else { return nil }
    }
}
