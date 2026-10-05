/// Small capability caches must recover from transient failures and editor
/// context changes. Keys include process session/version and element identity.
public struct ExpiringCache<Key: Hashable, Value> {
    private struct Entry { let value: Value; let expires: Double; let inserted: Double }
    private var entries: [Key: Entry] = [:]
    public let capacity: Int
    public init(capacity: Int = 32) { self.capacity = max(1, capacity) }
    public var count: Int { entries.count }
    public mutating func value(for key: Key, at time: Double) -> Value? {
        entries = entries.filter { $0.value.expires > time }
        return entries[key]?.value
    }
    public mutating func insert(_ value: Value, for key: Key, at time: Double, lifetime: Double) {
        entries = entries.filter { $0.value.expires > time }
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.inserted < $1.value.inserted })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(value: value, expires: time + lifetime, inserted: time)
    }
    public mutating func removeAll() { entries.removeAll() }
}
