import Foundation

/// Translate UTF-16 accessibility offsets to physical cursor movements.
public struct WordCursorPlan: Equatable {
    public let text: String
    public let stepsToEnd: Int
    public var selectionSteps: Int { text.count }

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
        stepsToEnd = value[caretRange.lowerBound..<range.upperBound].count
    }

    private init(text: String, stepsToEnd: Int) {
        self.text = text
        self.stepsToEnd = stepsToEnd
    }

    public func replacingText(with converted: String) -> WordCursorPlan? {
        guard converted.count == text.count else { return nil }
        return WordCursorPlan(text: converted, stepsToEnd: stepsToEnd)
    }
}
