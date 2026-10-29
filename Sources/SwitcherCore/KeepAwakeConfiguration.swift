import Foundation

/// A replacement assertion keeps the original deadline, including its
/// sub-minute remainder. nil duration means an untimed session.
public struct KeepAwakeConfiguration: Equatable {
    public let systemOnly: Bool
    public let timeout: TimeInterval?

    public init?(systemOnly: Bool, endDate: Date?, now: Date) {
        if let endDate {
            let remaining = endDate.timeIntervalSince(now)
            guard remaining > 0, remaining.isFinite else { return nil }
            timeout = remaining
        } else {
            timeout = nil
        }
        self.systemOnly = systemOnly
    }
}
