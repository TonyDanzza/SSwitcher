import Foundation

/// An eligible word ends exactly at the UTF-16 caret and has a safe deletion count.
public struct WordCursorPlan: Equatable {
    public let text: String
    public var deletingCharacters: Int { text.count }

    public init?(value: String, caret: Int, ignoringTrailing ignored: (Character) -> Bool = { _ in false }) {
        guard let scope = WordScopePlan(value: value, caret: caret, ignoringTrailing: ignored) else { return nil }
        let word = scope.text
        guard !word.isEmpty, word.count <= 256, word.utf16.count == word.count else { return nil }
        text = word
    }
}
