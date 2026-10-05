import Dispatch

/// Own-process AX access can invoke AppKit directly. It must run on main;
/// external messages use a serial worker. Each client owns a separate executor
/// and separate caches, so local UI work cannot race remote capability updates.
public final class AccessibilityExecution {
    public enum Policy { case localApplication, remoteApplication }
    public let policy: Policy
    private let queue: DispatchQueue
    public init(policy: Policy) {
        self.policy = policy
        queue = policy == .localApplication ? .main : DispatchQueue(label: "com.tonydanzza.SSwitcher.accessibility", qos: .userInitiated)
    }
    public func submit(_ operation: @escaping () -> Void) { queue.async(execute: operation) }
    public func assertIsolated() { dispatchPrecondition(condition: .onQueue(queue)) }
}
