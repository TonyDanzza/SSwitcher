/// Tracks actual input-source identity, not notification arrival order.
/// A confirmed switch performed by this process must not cancel a later
/// gesture when its distributed notification eventually arrives.
public struct InputSourceObservation {
    private var sourceID: String?

    public init(sourceID: String?) { self.sourceID = sourceID }

    public mutating func observe(_ currentID: String?) -> Bool {
        guard let currentID, !currentID.isEmpty else {
            sourceID = nil
            return true
        }
        let changed = currentID != sourceID
        sourceID = currentID
        return changed
    }

    public mutating func confirmedSelection(requestedID: String?, actualID: String?, succeeded: Bool) {
        guard succeeded, let requestedID, !requestedID.isEmpty,
              requestedID == actualID else { return }
        sourceID = actualID
    }
}
