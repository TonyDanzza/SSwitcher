import CoreGraphics

/// The replacement is carried by the event, rather than read later from the
/// mutable general pasteboard. Plan and create every event before editing text.
public struct UnicodeTextInput {
    public enum ControlPolicy: Equatable {
        case singleLine, figmaText, literalLines

        public static func forEditor(isCurrentProcess: Bool, isFigma: Bool,
                                     role: String?, description: String?) -> Self {
            if isCurrentProcess { return .literalLines }
            if isFigma, role == "AXTextArea", description == "Text" { return .figmaText }
            return .singleLine
        }
    }
    public enum Action: Equatable { case text(String), lineFeed, lineSeparator }
    public let actions: [Action]
    public var chunks: [String] { actions.compactMap { if case .text(let text) = $0 { return text }; return nil } }

    /// Small events also work with frameworks that cap text per key event.
    /// Never split a surrogate pair or an extended grapheme cluster. A cluster
    /// larger than the supported event size is rejected before any mutation.
    public init?(text: String, controlPolicy: ControlPolicy = .singleLine,
                 maximumUTF16UnitsPerEvent: Int = 20) {
        guard !text.isEmpty, !AccessibilitySelectionPlan.hasTextAttachment(text), maximumUTF16UnitsPerEvent > 0 else { return nil }
        // Return and Tab can submit a message or move focus in another app.
        // Control handling must be demonstrated for the specific editor.
        for scalar in text.unicodeScalars {
            if scalar.value == 0x0A || scalar.value == 0x2028 {
                guard controlPolicy != .singleLine else { return nil }
            } else if scalar.properties.generalCategory == .control || scalar.value == 0x2029 {
                return nil
            }
        }
        var actions: [Action] = []
        var chunk = ""
        var chunkUnits = 0
        func flush() {
            if !chunk.isEmpty { actions.append(.text(chunk)) }
            chunk = ""
            chunkUnits = 0
        }
        for character in text {
            let grapheme = String(character)
            if controlPolicy == .figmaText, grapheme == "\n" || grapheme == "\u{2028}" {
                flush()
                actions.append(grapheme == "\n" ? .lineFeed : .lineSeparator)
                continue
            }
            let units = grapheme.utf16.count
            guard units <= maximumUTF16UnitsPerEvent else { return nil }
            if chunkUnits + units > maximumUTF16UnitsPerEvent { flush() }
            chunk.append(character)
            chunkUnits += units
        }
        flush()
        self.actions = actions
    }

    /// CoreGraphics construction is checked for loss/truncation before the
    /// caller reserves its one mutation. This does not establish that a target
    /// framework supports Unicode keyboard events; editor proof is separate.
    public func makeEvents(virtualKey: CGKeyCode = 0) -> [CGEvent]? {
        guard let source = SyntheticKeyboardSource.make() else { return nil }
        source.userData = KeyboardEventDelivery.sourceMarker
        var events: [CGEvent] = []
        events.reserveCapacity(actions.count * 2)
        for action in actions {
            let key: CGKeyCode
            let flags: CGEventFlags
            let units: [UniChar]?
            switch action {
            case .text(let chunk): key = virtualKey; flags = []; units = Array(chunk.utf16)
            case .lineFeed: key = 36; flags = []; units = nil
            case .lineSeparator: key = 36; flags = .maskShift; units = nil
            }
            for isDown in [true, false] {
                // A framework may ignore Unicode and translate this virtual
                // key itself. Only actual editor evidence confirms insertion.
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { return nil }
                event.flags = isDown ? flags : []
                event.setIntegerValueField(.eventSourceUserData, value: KeyboardEventDelivery.sourceMarker)
                if let units {
                    units.withUnsafeBufferPointer {
                        event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                    }
                    guard Self.matches(event, units: units) else { return nil }
                }
                events.append(event)
            }
        }
        return events
    }

    /// All text events are created successfully before preparing deletion.
    /// Word deletion and its first text pair share one batch, so cancellation
    /// cannot interrupt them by stopping a later unposted deletion-only batch,
    /// and the editor applies deletion and insertion in one event-loop turn.
    /// `asOneWord` replaces the Backspaces with one Option+Backspace; the
    /// caller must know the editor's word boundary is the deleted text's start.
    public func makeEventBatches(deletingCharacters: Int = 0, asOneWord: Bool = false) -> [[CGEvent]]? {
        guard deletingCharacters >= 0, !asOneWord || deletingCharacters > 0,
              let textEvents = makeEvents(), !textEvents.isEmpty else { return nil }
        var batches = stride(from: 0, to: textEvents.count, by: 2).map { Array(textEvents[$0..<($0 + 2)]) }
        var initial: [CGEvent] = []
        for _ in 0..<(asOneWord ? 1 : deletingCharacters) {
            guard let pair = Self.deletionPair(flags: asOneWord ? .maskAlternate : []) else { return nil }
            initial.append(contentsOf: pair)
        }
        batches[0] = initial + batches[0]
        return batches
    }

    private static func deletionPair(flags: CGEventFlags = []) -> [CGEvent]? {
        guard let source = SyntheticKeyboardSource.make() else { return nil }
        source.userData = KeyboardEventDelivery.sourceMarker
        var pair: [CGEvent] = []
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: isDown) else { return nil }
            event.flags = isDown ? flags : []
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardEventDelivery.sourceMarker)
            pair.append(event)
        }
        return pair
    }

    private static func matches(_ event: CGEvent, units: [UniChar]) -> Bool {
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &count, unicodeString: nil)
        guard count == units.count else { return false }
        var stored = [UniChar](repeating: 0, count: count)
        stored.withUnsafeMutableBufferPointer {
            event.keyboardGetUnicodeString(maxStringLength: $0.count, actualStringLength: &count, unicodeString: $0.baseAddress)
        }
        return count == units.count && stored == units
    }
}
