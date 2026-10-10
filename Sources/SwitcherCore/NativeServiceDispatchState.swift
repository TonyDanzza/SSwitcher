/// Native menu action acceptance and service publication are independent
/// receipts. Neither receipt alone confirms an accepted selected-text request.
public struct NativeServiceDispatchState {
    public enum Outcome: Equatable { case submitted, unavailable, cancelled, unverified }
    public private(set) var publication: Bool?
    public private(set) var pressAccepted: Bool?
    public init() {}
    public mutating func published(_ success: Bool) { if publication == nil { publication = success } }
    public mutating func pressed(_ success: Bool) { if pressAccepted == nil { pressAccepted = success } }
    public var completed: Outcome? {
        guard let pressAccepted, let publication else { return nil }
        if publication { return pressAccepted ? .submitted : .unverified }
        return .unavailable
    }
    public func stopped(cancelled: Bool) -> Outcome {
        publication == true ? .unverified : (cancelled ? .cancelled : .unavailable)
    }
}
