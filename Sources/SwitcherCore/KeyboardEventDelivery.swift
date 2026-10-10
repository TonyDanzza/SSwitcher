import CoreGraphics

/// Receipt at the listening session tap establishes delivery through Quartz,
/// never target-editor acknowledgement. Only one batch may be in flight.
public struct KeyboardEventDelivery {
    public static let sourceMarker: Int64 = 0x53535749544348
    private static let markerMask: Int64 = ~0xFFFFFFFF
    private var counter: UInt32 = 0
    public private(set) var activeMarker: Int64?
    public init() {}

    public static func isSynthetic(marker: Int64) -> Bool {
        marker & markerMask == sourceMarker & markerMask
    }

    /// Quartz can regenerate keyboard metadata from its source when posting.
    /// Tag both events of the final pair through a distinct source, rather
    /// than relying on a per-event field that may be normalized away.
    public static func tagFinalPair(_ events: [CGEvent], marker: Int64) -> Bool {
        guard events.count >= 2, events[events.count - 2].type == .keyDown,
              events[events.count - 1].type == .keyUp,
              let original = CGEventSource(event: events[events.count - 2]),
              let source = SyntheticKeyboardSource.make(state: original.sourceStateID) else { return false }
        source.keyboardType = original.keyboardType
        source.userData = marker
        for event in events.suffix(2) {
            event.setSource(source)
            event.setIntegerValueField(.eventSourceUserData, value: marker)
        }
        return true
    }

    public mutating func begin() -> Int64? {
        guard activeMarker == nil else { return nil }
        counter &+= 1
        if counter == UInt32(truncatingIfNeeded: Self.sourceMarker) { counter &+= 1 }
        let marker = (Self.sourceMarker & Self.markerMask) | Int64(counter)
        activeMarker = marker
        return marker
    }

    public mutating func acknowledge(marker: Int64) -> Bool {
        guard activeMarker == marker else { return false }
        activeMarker = nil
        return true
    }

    public mutating func cancel() -> Bool {
        guard activeMarker != nil else { return false }
        activeMarker = nil
        return true
    }
}
