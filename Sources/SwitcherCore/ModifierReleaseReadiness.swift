/// A second physical Shift may release between text batches or before a caret correction without
/// invalidating the running attempt. Waiting never authorizes changed input or
/// extends its original deadline, and never queues another text mutation.
public struct ModifierReleaseReadiness {
    public enum Decision: Equatable { case ready, wait(Double), cancelled, timedOut }
    public let expiresAt: Double
    public let pollInterval: Double
    public init(start: Double, timeout: Double, pollInterval: Double = 0.02) {
        expiresAt = start + timeout
        self.pollInterval = pollInterval
    }
    public func decision(at time: Double, inputUnchanged: Bool, modifiersClear: Bool) -> Decision {
        guard inputUnchanged else { return .cancelled }
        guard time < expiresAt else { return .timedOut }
        return modifiersClear ? .ready : .wait(min(pollInterval, expiresAt - time))
    }
}
