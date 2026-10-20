import Foundation

/// Transport-independent token scope: the caret is on a whole grapheme
/// boundary and at this token's end, before any following whitespace.
/// Characters after the caret that `ignoringTrailing` accepts (layout-neutral
/// punctuation such as a closing bracket) stay in place and do not block it.
public struct WordScopePlan: Equatable {
    public let text: String
    public let range: NSRange

    public init?(value: String, caret: Int, ignoringTrailing ignored: (Character) -> Bool = { _ in false }) {
        guard let token = TextConversion.tokenRange(in: value, caret: caret),
              let range = AccessibilitySelectionPlan.checkedRange(token, in: value),
              let caretRange = AccessibilitySelectionPlan.checkedRange(NSRange(location: caret, length: 0), in: value) else { return nil }
        let end = caretRange.lowerBound
        guard end > range.lowerBound, end <= range.upperBound,
              value[end..<range.upperBound].allSatisfy(ignored) else { return nil }
        let text = String(value[range.lowerBound..<end])
        guard !text.isEmpty else { return nil }
        self.text = text
        self.range = NSRange(range.lowerBound..<end, in: value)
    }
}
