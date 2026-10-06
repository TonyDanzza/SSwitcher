import Foundation

/// Read-only extent discovery for an editor with demonstrated out-of-bounds
/// replies. Generic missing values or IPC failures must never become bounds.
public struct TextRangeDocumentPlan {
    public enum Reply { case text(String), outOfBounds, unavailable }
    public let document: String
    public var length: Int { document.utf16.count }

    public init?(upperBound: Int, lowerCandidate: Int, cachedLength: Int? = nil,
                 maximumProbes: Int = 32, read: (NSRange) -> Reply) {
        guard upperBound >= 0, upperBound <= 1_048_576, lowerCandidate >= 0, lowerCandidate <= upperBound,
              maximumProbes > 0 else { return nil }
        var probes = 0
        func query(_ location: Int, _ length: Int) -> Reply {
            guard probes < maximumProbes else { return .unavailable }
            probes += 1
            return read(NSRange(location: location, length: length))
        }
        func prefix(_ length: Int) -> Reply {
            let reply = query(0, length)
            if case .text(let text) = reply, text.utf16.count != length { return .unavailable }
            return reply
        }
        let end: Int
        let text: String
        if let cachedLength {
            guard cachedLength >= lowerCandidate, cachedLength <= upperBound,
                  case .text(let value) = prefix(cachedLength) else { return nil }
            end = cachedLength
            text = value
        } else {
            switch prefix(upperBound) {
            case .text(let value): end = upperBound; text = value
            case .unavailable: return nil
            case .outOfBounds:
                var low = lowerCandidate
                var high = upperBound
                guard case .text = prefix(low) else { return nil }
                while high - low > 1 {
                    let middle = low + (high - low) / 2
                    switch prefix(middle) {
                    case .text: low = middle
                    case .outOfBounds: high = middle
                    case .unavailable: return nil
                    }
                }
                guard case .text(let value) = prefix(low) else { return nil }
                end = low
                text = value
            }
        }
        guard case .text(let empty) = query(end, 0), empty.isEmpty,
              case .outOfBounds = query(end, 1),
              case .text(let repeated) = prefix(end), AccessibilitySelectionPlan.exactlyEqual(text, repeated),
              !AccessibilitySelectionPlan.hasTextAttachment(text) else { return nil }
        document = text
    }
}
