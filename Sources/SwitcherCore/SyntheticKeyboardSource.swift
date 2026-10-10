import CoreGraphics

/// Synthetic input must never suppress the user's hardware input. Sources
/// for receipts share the original state table and retain the same policy.
enum SyntheticKeyboardSource {
    static func make(state: CGEventSourceStateID = .privateState) -> CGEventSource? {
        guard let source = CGEventSource(stateID: state) else { return nil }
        source.localEventsSuppressionInterval = 0
        let passThrough: CGEventFilterMask = [.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents]
        source.setLocalEventsFilterDuringSuppressionState(passThrough, state: .eventSuppressionStateSuppressionInterval)
        source.setLocalEventsFilterDuringSuppressionState(passThrough, state: .eventSuppressionStateRemoteMouseDrag)
        return source
    }
}
