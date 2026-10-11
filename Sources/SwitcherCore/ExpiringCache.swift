/// Small capability caches must recover from transient failures and editor
/// context changes. Keys include process session/version and element identity.
public struct ExpiringCache<Key: Hashable, Value> {
    private struct Entry { let value: Value; let expires: Double; let inserted: Double }
    private var entries: [Key: Entry] = [:]
    /// No entry expires before this time, so lookups skip the purge.
    private var nextExpiry = Double.infinity
    public let capacity: Int
    public init(capacity: Int = 32) { self.capacity = max(1, capacity) }
    public var count: Int { entries.count }
    public mutating func value(for key: Key, at time: Double) -> Value? {
        purge(at: time)
        return entries[key]?.value
    }
    public mutating func insert(_ value: Value, for key: Key, at time: Double, lifetime: Double) {
        purge(at: time)
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.inserted < $1.value.inserted })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(value: value, expires: time + lifetime, inserted: time)
        nextExpiry = min(nextExpiry, time + lifetime)
    }
    public mutating func removeAll() { entries.removeAll(); nextExpiry = .infinity }

    private mutating func purge(at time: Double) {
        guard time >= nextExpiry else { return }
        entries = entries.filter { $0.value.expires > time }
        nextExpiry = entries.values.lazy.map(\.expires).min() ?? .infinity
    }
}
