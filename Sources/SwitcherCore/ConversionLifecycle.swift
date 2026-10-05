/// Exactly one mutation and one completion belong to each attempt. A cancelled
/// capture/read callback cannot resume an attempt, including after mutation.
public struct ConversionLifecycle {
    public enum Phase: Equatable { case preparing, mutated, cancelled, finished }
    public private(set) var phase: Phase = .preparing
    public private(set) var hasMutated = false
    public var canContinue: Bool { phase == .preparing || phase == .mutated }
    public init() {}
    public mutating func commitMutation() -> Bool {
        guard phase == .preparing else { return false }
        phase = .mutated
        hasMutated = true
        return true
    }
    public mutating func cancel() -> Bool {
        guard canContinue else { return false }
        phase = .cancelled
        return true
    }
    public mutating func finish() -> Bool {
        guard phase != .finished else { return false }
        phase = .finished
        return true
    }
}

/// Temporary polling never extends the original readiness deadline. A read
/// merely checks editor evidence; reaching its time does not establish success.
public struct ReadinessDeadline {
    public let expiresAt: Double
    public let pollInterval: Double
    private var nextPoll: Double
    public init(start: Double, timeout: Double, pollInterval: Double = 0.02) {
        expiresAt = start + timeout
        self.pollInterval = pollInterval
        nextPoll = start
    }
    public func expired(at time: Double) -> Bool { time >= expiresAt }
    public mutating func shouldRead(at time: Double) -> Bool {
        guard !expired(at: time), time >= nextPoll else { return false }
        nextPoll = time + pollInterval
        return true
    }
    public func delay(at time: Double) -> Double { max(0, min(nextPoll, expiresAt) - time) }
}
