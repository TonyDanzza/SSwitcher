/// Recognizes two short, isolated presses of the same Shift key.
/// Times are monotonic seconds; no typed text is retained.
public struct DoubleShiftDetector {
    public var interval: Double = 0.3
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
        guard key == 56 || key == 60 else {
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
        guard isSingleRelease, !otherModifierDown, let startedAt,
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
