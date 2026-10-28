/// Synthetic shortcut flags may outlive their key-up, even in a HID state
/// table. Physical key transitions and sampled key-down states are authoritative.
public struct PhysicalModifierState {
    public static let unsafeKeys: [UInt16] = [54, 55, 56, 60, 58, 61, 59, 62, 63]
    private var held: Set<UInt16> = []
    public init() {}
    public var observedModifiersClear: Bool { held.isEmpty }
    public func holds(any keys: Set<UInt16>) -> Bool { !held.isDisjoint(with: keys) }
    public func holdsOther(than keys: Set<UInt16>) -> Bool { held.contains { !keys.contains($0) } }
    public mutating func reset() { held.removeAll() }
    /// Device-dependent bit of each side's key in CGEventFlags (IOLLEvent.h).
    private static let deviceBits: [UInt16: UInt64] = [59: 0x01, 56: 0x02, 60: 0x04, 55: 0x08, 54: 0x10, 58: 0x20, 61: 0x40, 62: 0x2000]
    private static let siblings: [UInt16: UInt16] = [59: 62, 62: 59, 56: 60, 60: 56, 55: 54, 54: 55, 58: 61, 61: 58]

    /// `deviceFlags` is the raw flags value of the flagsChanged event. With
    /// the other side still down the group flag stays set, so a release of a
    /// key never seen pressed (pressed while another tap swallowed it, such as
    /// the cleaning lock) would read as a press and stay held for good; the
    /// device bit tells the two apart when the keyboard reports it.
    public mutating func changed(key: UInt16, groupDown: Bool, deviceFlags: UInt64? = nil) {
        guard Self.unsafeKeys.contains(key) else { return }
        if groupDown && !held.contains(key) {
            if let deviceFlags, let bit = Self.deviceBits[key], let sibling = Self.siblings[key], let siblingBit = Self.deviceBits[sibling],
               deviceFlags & (bit | siblingBit) != 0, deviceFlags & bit == 0 { return }
            held.insert(key)
        }
        else { held.remove(key) }
    }

    /// A real key press carries the group flags of everything held; a key
    /// whose group flag is absent there is up, whatever was missed before.
    public mutating func released(key: UInt16) { held.remove(key) }
    public func permitsMutation(hardwareKeysDown: Set<UInt16>) -> Bool {
        observedModifiersClear && hardwareKeysDown.isDisjoint(with: Self.unsafeKeys)
    }
}
