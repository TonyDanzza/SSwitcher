import Foundation

/// An eligible word ends exactly at the UTF-16 caret and has a safe deletion count.
public struct WordCursorPlan: Equatable {
    public let text: String
    public var deletingCharacters: Int { text.count }

    public init?(value: String, caret: Int) {
        guard let token = TextConversion.tokenRange(in: value, caret: caret),
              let range = Range(token, in: value),
              let caretRange = Range(NSRange(location: caret, length: 0), in: value),
              value.indices.contains(caretRange.lowerBound) || caretRange.lowerBound == value.endIndex,
              caretRange.lowerBound >= range.lowerBound, caretRange.lowerBound <= range.upperBound else { return nil }
        guard caretRange.lowerBound == range.upperBound else { return nil }
        let word = String(value[range])
        guard !word.isEmpty, word.count <= 256, word.utf16.count == word.count else { return nil }
        text = word
    }
}
