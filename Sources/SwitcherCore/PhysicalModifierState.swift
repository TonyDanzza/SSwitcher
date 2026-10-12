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
    public mutating func changed(key: UInt16, groupDown: Bool) {
        guard Self.unsafeKeys.contains(key) else { return }
        if groupDown && !held.contains(key) { held.insert(key) }
        else { held.remove(key) }
    }
    public func permitsMutation(hardwareKeysDown: Set<UInt16>) -> Bool {
        observedModifiersClear && hardwareKeysDown.isDisjoint(with: Self.unsafeKeys)
    }
}
