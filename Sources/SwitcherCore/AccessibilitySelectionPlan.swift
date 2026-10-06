import Foundation

/// Accessibility offsets are UTF-16, while keyboard selection steps are
/// grapheme clusters. A selection is usable only when every supplied piece of
/// document evidence agrees; missing or stale data must never widen its scope.
public struct AccessibilitySelectionPlan: Equatable {
    public let document: String
    public let range: NSRange
    public let text: String

    public init?(document: String?, range: NSRange?, selectedText: String?, selectedRanges: [NSRange]? = nil) {
        guard let document, let range, range.length > 0, !Self.hasTextAttachment(document),
              Self.hasSingleRange(range, selectedRanges: selectedRanges),
              let stringRange = Self.checkedRange(range, in: document) else { return nil }
        let text = String(document[stringRange])
        if let selectedText, !Self.exactlyEqual(text, selectedText) { return nil }
        self.document = document
        self.range = range
        self.text = text
    }

    public var isEntireDocument: Bool { range.location == 0 && range.length == document.utf16.count }

    /// A second snapshot immediately before mutation must describe the same
    /// document and range. In particular, repeated text cannot identify scope.
    public func matches(document: String?, range: NSRange?, selectedText: String?, selectedRanges: [NSRange]? = nil) -> Bool {
        guard let candidate = Self(document: document, range: range, selectedText: selectedText, selectedRanges: selectedRanges) else { return false }
        return self.range == candidate.range && Self.exactlyEqual(self.document, candidate.document)
    }

    public func replacing(with replacement: String) -> AccessibilityReplacementPlan? {
        guard !replacement.isEmpty, !Self.hasTextAttachment(replacement) else { return nil }
        let result = (document as NSString).replacingCharacters(in: range, with: replacement)
        let resultRange = NSRange(location: range.location, length: replacement.utf16.count)
        // A replacement may combine with a neighboring grapheme. In that case
        // the exact fragment cannot be restored safely by character selection.
        guard Self.checkedRange(resultRange, in: result) != nil else { return nil }
        return AccessibilityReplacementPlan(document: result, range: resultRange, text: replacement,
                                             isEntireDocument: isEntireDocument)
    }

    public static func hasTextAttachment(_ text: String) -> Bool { text.unicodeScalars.contains { $0.value == 0xFFFC } }

    public static func exactlyEqual(_ left: String, _ right: String) -> Bool {
        left.utf16.elementsEqual(right.utf16)
    }

    public static func hasSingleRange(_ range: NSRange, selectedRanges: [NSRange]?) -> Bool {
        guard let selectedRanges else { return true }
        return selectedRanges == [range]
    }

    public static func confirmsCaret(document: String?, range: NSRange?, selectedText: String?,
                                     selectedRanges: [NSRange]? = nil, expectedDocument: String, expectedCaret: NSRange) -> Bool {
        guard let document, let range, range == expectedCaret, range.length == 0, !hasTextAttachment(document),
              exactlyEqual(document, expectedDocument), checkedRange(range, in: document) != nil,
              hasSingleRange(range, selectedRanges: selectedRanges) else { return false }
        return selectedText == nil || selectedText?.isEmpty == true
    }

    public static func checkedRange(_ range: NSRange, in document: String) -> Range<String.Index>? {
        let count = document.utf16.count
        guard range.location >= 0, range.length >= 0, range.location <= count,
              range.length <= count - range.location,
              let result = Range(range, in: document),
              (result.lowerBound == document.endIndex || document.indices.contains(result.lowerBound)),
              (result.upperBound == document.endIndex || document.indices.contains(result.upperBound)) else { return nil }
        return result
    }
}

/// The exact document and range expected after a single replacement. Event
/// receipt and elapsed time are not text acknowledgement; AX evidence is.
public struct AccessibilityReplacementPlan: Equatable {
    public let document: String
    public let range: NSRange
    public let text: String
    public let isEntireDocument: Bool
    public var caret: NSRange { NSRange(location: range.location + range.length, length: 0) }

    public func documentMatches(_ candidate: String?) -> Bool {
        candidate.map { AccessibilitySelectionPlan.exactlyEqual(document, $0) } == true
    }

    public func confirmsSelection(document: String?, range: NSRange?, selectedText: String?, selectedRanges: [NSRange]? = nil) -> Bool {
        guard let candidate = AccessibilitySelectionPlan(document: document, range: range, selectedText: selectedText, selectedRanges: selectedRanges),
              documentMatches(candidate.document), candidate.range == self.range else { return false }
        return AccessibilitySelectionPlan.exactlyEqual(text, candidate.text)
    }
}
