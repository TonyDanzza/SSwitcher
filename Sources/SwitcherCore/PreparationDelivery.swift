/// Cancellation is distinct from an unavailable optional preparation. A
/// capture timeout may continue without animation; cancellation must not.
public enum PreparationResult<Value> { case ready(Value), skipped, cancelled }
public final class PreparationDelivery<Value> {
    private var completion: ((PreparationResult<Value>) -> Void)?
    public init(completion: @escaping (PreparationResult<Value>) -> Void) { self.completion = completion }
    public func complete(_ result: PreparationResult<Value>) {
        let callback = completion
        completion = nil
        callback?(result)
    }
    public func cancel() { complete(.cancelled) }
}
