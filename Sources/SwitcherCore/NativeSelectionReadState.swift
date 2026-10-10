/// A positive selection reply and an empty responder barrier are different
/// receipts. A missing selection reply alone never proves an empty caret.
public struct NativeSelectionReadState {
    public enum Result: Equatable {
        case selection(String)
        case emptyNeedsVerification
        case rejected
    }
    private var delivered: Bool?
    private var text: String?
    private var barrier = false
    private var invalid = false
    public init() {}
    public mutating func delivery(_ success: Bool) {
        if delivered == nil { delivered = success }
    }
    public mutating func receive(_ value: String) -> Bool {
        guard text == nil, !invalid else { return false }
        guard NativeServicePayload.accepts(value) else { invalid = true; return false }
        text = value
        return true
    }
    public mutating func receiveBarrier() { barrier = true }
    public var result: Result? {
        if invalid || delivered == false { return .rejected }
        guard delivered == true else { return nil }
        if let text { return .selection(text) }
        return barrier ? .emptyNeedsVerification : nil
    }
}
