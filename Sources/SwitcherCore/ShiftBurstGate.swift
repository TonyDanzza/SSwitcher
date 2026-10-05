/// Coalesces rapid Shift taps into one action after the modifier is released.
/// Pure monotonic-time state; the app schedules a timer only while pending.
public struct ShiftBurstGate {
    public let quietInterval: Double
    private var lastChange = -Double.infinity
    private var shiftDown = false
    public private(set) var pending = false

    public init(quietInterval: Double = 0.14) { self.quietInterval = quietInterval }
    public mutating func shiftChanged(down: Bool, at time: Double) {
        shiftDown = down
        lastChange = time
    }
    public mutating func request() { pending = true }
    public mutating func cancel() { pending = false }
    public mutating func consume(at time: Double) -> Bool {
        guard pending, !shiftDown, time - lastChange >= quietInterval else { return false }
        pending = false
        return true
    }
}
