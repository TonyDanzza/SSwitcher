/// Coalesces Shift bursts and refuses requests during/after an active attempt.
/// A running attempt never accumulates a second command. Its tail is drained
/// until a complete quiet interval, even if the editor finishes between taps.
public struct ShiftBurstGate {
    public enum State: Equatable { case idle, pending, running, draining, blocked }
    public let quietInterval: Double
    private var lastChange = -Double.infinity
    private var shiftDown = false
    private var drainUntil = -Double.infinity
    private var inputDuringRun = false
    public private(set) var state: State = .idle
    public var pending: Bool { state == .pending }

    public init(quietInterval: Double = 0.09) { self.quietInterval = quietInterval }
    public mutating func shiftChanged(down: Bool, at time: Double) {
        if state == .draining, time >= drainUntil { state = .idle }
        shiftDown = down
        lastChange = time
        if state == .draining { drainUntil = time + quietInterval }
    }
    public mutating func request() {
        if state == .idle || state == .pending { state = .pending }
    }
    public mutating func cancel() {
        if state == .pending { state = .idle }
    }
    public mutating func realInput() {
        if state == .running { inputDuringRun = true } else { state = .idle }
    }
    public mutating func beginConversion() -> Bool {
        guard state == .idle else { return false }
        state = .running
        inputDuringRun = false
        return true
    }
    public mutating func complete(at time: Double, unverified: Bool) {
        guard state == .running else { return }
        if unverified && !inputDuringRun { state = .blocked; return }
        state = .draining
        drainUntil = max(time, lastChange) + quietInterval
    }
    public mutating func consume(at time: Double) -> Bool {
        guard pending, !shiftDown, time - lastChange >= quietInterval else { return false }
        state = .idle
        return true
    }
}
