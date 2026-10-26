import Foundation

/// The unlock chord of the cleaning lock: left and right Option+Command held
/// together for `holdDuration`, with no other key down. The space bar sits
/// between them, so a cloth wiped along the bottom row presses it as well.
public struct KeyboardLockUnlock {
    /// Device-dependent modifier bits of CGEventFlags (IOLLEvent.h).
    public enum Device {
        public static let leftControl: UInt64 = 0x01, leftShift: UInt64 = 0x02, rightShift: UInt64 = 0x04
        public static let leftCommand: UInt64 = 0x08, rightCommand: UInt64 = 0x10
        public static let leftOption: UInt64 = 0x20, rightOption: UInt64 = 0x40, rightControl: UInt64 = 0x2000
        public static let all: UInt64 = leftControl | leftShift | rightShift | leftCommand | rightCommand | leftOption | rightOption | rightControl
    }
    public static let chord = Device.leftCommand | Device.rightCommand | Device.leftOption | Device.rightOption
    public static let holdDuration = 5.0

    private var keys = Set<Int64>()
    private var modifiers: UInt64 = 0
    private var fn = false
    private var heldSince: Double?

    public init() {}

    public mutating func keyChanged(code: Int64, down: Bool, at time: Double) {
        if down { keys.insert(code) } else { keys.remove(code) }
        update(at: time)
    }

    /// `deviceFlags` is the raw CGEventFlags value of a flagsChanged event.
    public mutating func modifiersChanged(deviceFlags: UInt64, fnDown: Bool, at time: Double) {
        modifiers = deviceFlags & Device.all
        fn = fnDown
        update(at: time)
    }

    public var isHoldingChord: Bool { heldSince != nil }
    /// When the current hold completes, nil when the chord is not held.
    public var unlockTime: Double? { heldSince.map { $0 + Self.holdDuration } }

    /// 0…1 while the chord is held.
    public func progress(at time: Double) -> Double {
        guard let heldSince else { return 0 }
        return min(1, max(0, (time - heldSince) / Self.holdDuration))
    }

    public func shouldUnlock(at time: Double) -> Bool { progress(at: time) >= 1 }

    private mutating func update(at time: Double) {
        let exact = modifiers == Self.chord && keys.isEmpty && !fn
        if !exact { heldSince = nil } else if heldSince == nil { heldSince = time }
    }
}
