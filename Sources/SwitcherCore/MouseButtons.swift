import Foundation

/// What an extra mouse button does instead of its own click.
public enum MouseAction: Hashable, Sendable {
    case back, forward
    case missionControl, applicationWindows, desktop
    case spaceLeft, spaceRight
    /// Any key combination, including ones a global shortcut may not use
    /// (⌘W, a single key). nil until one is recorded; the button then does nothing.
    case shortcut(KeyShortcut?)

    /// The choices in the order Settings lists them.
    public enum Kind: String, CaseIterable, Sendable {
        case back, forward, missionControl, applicationWindows, desktop, spaceLeft, spaceRight, shortcut
    }

    public var kind: Kind {
        switch self {
        case .back: .back
        case .forward: .forward
        case .missionControl: .missionControl
        case .applicationWindows: .applicationWindows
        case .desktop: .desktop
        case .spaceLeft: .spaceLeft
        case .spaceRight: .spaceRight
        case .shortcut: .shortcut
        }
    }

    public init(kind: Kind) {
        switch kind {
        case .back: self = .back
        case .forward: self = .forward
        case .missionControl: self = .missionControl
        case .applicationWindows: self = .applicationWindows
        case .desktop: self = .desktop
        case .spaceLeft: self = .spaceLeft
        case .spaceRight: self = .spaceRight
        case .shortcut: self = .shortcut(nil)
        }
    }

    /// Back and Forward are ⌘[ and ⌘], which browsers, Finder and most
    /// document windows understand; a recorded shortcut is its own.
    public var keys: KeyShortcut? {
        switch self {
        case .back: KeyShortcut(keyCode: 33, modifiers: .command)
        case .forward: KeyShortcut(keyCode: 30, modifiers: .command)
        case .shortcut(let shortcut): shortcut
        default: nil
        }
    }
}

/// One extra mouse button, optionally held with modifiers, and its action.
/// Buttons use CoreGraphics numbering: 2 is the middle button, 3 and 4 the
/// side buttons. The left and right buttons (0 and 1) are never taken.
public struct MouseButtonBinding: Hashable, Identifiable, Sendable {
    public let button: Int
    public let modifiers: KeyShortcut.Modifiers
    public var action: MouseAction

    public init?(button: Int, modifiers: KeyShortcut.Modifiers = [], action: MouseAction) {
        guard Self.bindableButtons.contains(button) else { return nil }
        self.button = button
        self.modifiers = modifiers.intersection(.all)
        self.action = action
    }

    public static let bindableButtons = 2...31
    public var id: String { "\(button)-\(modifiers.rawValue)" }

    public func matches(button: Int, modifiers: KeyShortcut.Modifiers) -> Bool {
        self.button == button && self.modifiers == modifiers.intersection(.all)
    }

    /// Side buttons usually mean back and forward; anything else starts as
    /// Mission Control.
    public static func suggestedAction(for button: Int) -> MouseAction {
        switch button {
        case 3: .back
        case 4: .forward
        default: .missionControl
        }
    }

    /// "Средняя кнопка", "⌘ + кнопка «Назад»".
    public var title: String {
        let name: String
        switch button {
        case 2: name = "средняя кнопка"
        case 3: name = "кнопка «Назад»"
        case 4: name = "кнопка «Вперёд»"
        default: name = "кнопка \(button + 1)"
        }
        if modifiers.isEmpty { return name.prefix(1).uppercased() + name.dropFirst() }
        return modifiers.symbols + " + " + name
    }

    // MARK: Storage

    public var storage: [String: Any] {
        var value: [String: Any] = ["button": button, "modifiers": Int(modifiers.rawValue), "action": action.kind.rawValue]
        if case .shortcut(let shortcut?) = action { value["keyCode"] = Int(shortcut.keyCode); value["keyModifiers"] = Int(shortcut.modifiers.rawValue) }
        return value
    }

    public init?(storage: [String: Any]) {
        guard let button = storage["button"] as? Int, let rawFlags = storage["modifiers"] as? Int, let flags = UInt32(exactly: rawFlags),
              let raw = storage["action"] as? String, let kind = MouseAction.Kind(rawValue: raw) else { return nil }
        var action = MouseAction(kind: kind)
        if kind == .shortcut, storage["keyCode"] != nil || storage["keyModifiers"] != nil {
            guard let key = storage["keyCode"] as? Int, (0...0xFF).contains(key),
                  let rawKeyFlags = storage["keyModifiers"] as? Int,
                  let keyFlags = UInt32(exactly: rawKeyFlags) else { return nil }
            action = .shortcut(KeyShortcut(keyCode: UInt32(key), modifiers: .init(rawValue: keyFlags)))
        }
        self.init(button: button, modifiers: .init(rawValue: flags), action: action)
    }

    /// Unreadable entries are dropped and a repeated button keeps its first action.
    public static func list(from storage: [[String: Any]]) -> [MouseButtonBinding] {
        var seen = Set<String>()
        return storage.compactMap(MouseButtonBinding.init(storage:)).filter { seen.insert($0.id).inserted }
    }
}

/// Natural scrolling turns both the trackpad and the mouse wheel. Only a
/// wheel's line-based events are reversed: trackpads and Magic Mouse send
/// continuous scrolling and keep the system direction.
public enum ScrollWheelReversal {
    public static func applies(enabled: Bool, isContinuous: Bool) -> Bool { enabled && !isContinuous }
}
