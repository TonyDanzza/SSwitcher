import Foundation

/// Transport-independent token scope: the caret is on a whole grapheme
/// boundary and exactly at this token's end, before any following whitespace.
public struct WordScopePlan: Equatable {
    public let text: String
    public let range: NSRange

    public init?(value: String, caret: Int) {
        guard let token = TextConversion.tokenRange(in: value, caret: caret),
              let range = AccessibilitySelectionPlan.checkedRange(token, in: value),
              let caretRange = AccessibilitySelectionPlan.checkedRange(NSRange(location: caret, length: 0), in: value),
              caretRange.lowerBound == range.upperBound else { return nil }
        let text = String(value[range])
        guard !text.isEmpty else { return nil }
        self.text = text
        self.range = token
    }
}
