/// The queued return-only request follows the selection request in the host's
/// responder loop. A cached menu item or key delivery alone proves no scope.
public struct NativeSelectionDispatchState {
    public enum Result: Equatable { case submitted, empty, rejected }
    private var delivered: Bool?
    private var publication: Bool?
    private var barrier = false
    public init() {}
    public mutating func delivery(_ success: Bool) {
        if delivered == nil { delivered = success }
    }
    public mutating func published(_ success: Bool) {
        if publication == nil { publication = success }
    }
    public mutating func receiveBarrier() { barrier = true }
    public var result: Result? {
        if delivered == false || publication == false { return .rejected }
        guard delivered == true else { return nil }
        // A positive selection response proves the scope without waiting for
        // a second service which Qt may drop after committing that response.
        if publication == true { return .submitted }
        return barrier ? .empty : nil
    }
}
