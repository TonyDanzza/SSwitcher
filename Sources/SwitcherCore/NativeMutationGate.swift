/// A missing acknowledgement never authorizes a second write. Repeated bare
/// Shift and own source reconciliation are not user intervention.
public struct NativeMutationGate {
    public enum State: Equatable { case idle, running, blocked }
    public private(set) var state: State = .idle
    private var issued = false
    private var intervened = false

    public init() {}
    public mutating func begin() -> Bool {
        guard state == .idle else { return false }
        state = .running; issued = false; intervened = false
        return true
    }
    public mutating func willWrite() { if state == .running { issued = true } }
    public mutating func realIntervention() {
        if state == .running { intervened = true }
        else { state = .idle }
    }
    public mutating func finish(confirmed: Bool) {
        guard state == .running else { return }
        state = issued && !confirmed && !intervened ? .blocked : .idle
    }
}
