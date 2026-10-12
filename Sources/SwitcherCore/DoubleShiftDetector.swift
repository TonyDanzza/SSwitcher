/// The modifier whose double tap converts text. Shift by default.
public enum TriggerKey: Int, CaseIterable, Sendable {
    case shift, control, option, command

    public var left: UInt16 {
        switch self { case .shift: return 56; case .control: return 59; case .option: return 58; case .command: return 55 }
    }
    public var right: UInt16 {
        switch self { case .shift: return 60; case .control: return 62; case .option: return 61; case .command: return 54 }
    }
    public var codes: Set<UInt16> { [left, right] }
    public var symbol: String {
        switch self { case .shift: return "⇧"; case .control: return "⌃"; case .option: return "⌥"; case .command: return "⌘" }
    }
    public var name: String {
        switch self { case .shift: return "Shift"; case .control: return "Control"; case .option: return "Option"; case .command: return "Command" }
    }
    public var modifier: KeyShortcut.Modifiers {
        switch self { case .shift: return .shift; case .control: return .control; case .option: return .option; case .command: return .command }
    }
}

/// Which physical key of the pair counts.
public enum TriggerSide: Int, CaseIterable, Sendable {
    case any, left, right
    public func keys(of trigger: TriggerKey) -> Set<UInt16> {
        switch self {
        case .any: return trigger.codes
        case .left: return [trigger.left]
        case .right: return [trigger.right]
        }
    }
    /// "Двойной Shift", "двойной левый ⌥": menu subtitles and labels.
    public func phrase(_ trigger: TriggerKey) -> String {
        let name = trigger == .shift ? trigger.name : trigger.symbol
        switch self {
        case .any: return "Двойной \(name)"
        case .left: return "Двойной левый \(name)"
        case .right: return "Двойной правый \(name)"
        }
    }
}

/// Recognizes two short, isolated presses of the same trigger modifier
/// (Shift unless Settings choose Control, Option or Command).
/// Times are monotonic seconds; no typed text is retained.
public struct DoubleShiftDetector {
    public var interval: Double = 0.3
    /// Both keys of the trigger modifier (56 and 60 for Shift).
    public var pair: Set<UInt16> = TriggerKey.shift.codes
    /// The keys of `pair` that count. A tap of the other one never counts
    /// and breaks a pending pair.
    public var keys: Set<UInt16> = TriggerKey.shift.codes
    private var heldKeys: Set<UInt16> = []
    private var pressTime: Double?
    private var previousTap: (key: UInt16, time: Double)?

    public init() {}

    public mutating func reset() {
        heldKeys.removeAll()
        pressTime = nil
        previousTap = nil
    }

    /// Cancel a gesture when a letter, shortcut modifier, or mouse button is used.
    public mutating func cancelGesture() {
        pressTime = nil
        previousTap = nil
    }

    public mutating func shiftChanged(key: UInt16, anyShiftDown: Bool, otherModifierDown: Bool, time: Double) -> Bool {
        guard pair.contains(key) else {
            cancelGesture()
            return false
        }

        if otherModifierDown { cancelGesture() }

        if anyShiftDown {
            // An event for an already held key means it was released while
            // the other Shift remains down. Such a chord never counts as a tap.
            if heldKeys.contains(key) {
                heldKeys.remove(key)
                cancelGesture()
            } else {
                let wasEmpty = heldKeys.isEmpty
                heldKeys.insert(key)
                if wasEmpty && !otherModifierDown {
                    pressTime = time
                } else {
                    cancelGesture()
                }
            }
            return false
        }

        let isSingleRelease = heldKeys == [key]
        let startedAt = pressTime
        heldKeys.removeAll()
        pressTime = nil
        guard keys.contains(key), isSingleRelease, !otherModifierDown, let startedAt,
              time >= startedAt, time - startedAt <= interval else {
            previousTap = nil
            return false
        }

        if let previousTap, previousTap.key == key,
           startedAt >= previousTap.time, time - previousTap.time <= interval {
            self.previousTap = nil
            return true
        }
        previousTap = (key, time)
        return false
    }
}
