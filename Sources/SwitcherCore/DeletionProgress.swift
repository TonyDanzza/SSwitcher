import Foundation

/// How far the Backspaces of a word replacement have got, judged from the
/// editor's own value and caret. Web pages that rebuild a search field on
/// every keystroke can drop fast Backspaces, so the text is typed only after
/// the word is confirmed gone.
public enum DeletionProgress: Equatable {
    /// The word is gone and the caret is where it started.
    case done
    /// The first `n` UTF-16 units of the word are still there, caret after them.
    case remaining(Int)
    /// The editor shows something else (or is still updating).
    case unknown

    public static func evaluate(document: String, wordRange: NSRange, value: String?, caret: NSRange?) -> Self {
        let original = document as NSString
        guard let value, let caret, caret.length == 0, wordRange.length > 0,
              NSMaxRange(wordRange) <= original.length else { return .unknown }
        let before = original.substring(to: wordRange.location)
        let word = original.substring(with: wordRange) as NSString
        let after = original.substring(from: NSMaxRange(wordRange))
        let current = value as NSString
        let kept = current.length - (before as NSString).length - (after as NSString).length
        guard kept >= 0, kept <= word.length, caret.location == wordRange.location + kept,
              Self.plain(value) == Self.plain(before + word.substring(to: kept) + after) else { return .unknown }
        return kept == 0 ? .done : .remaining(kept)
    }

    /// Chromium editors turn the space left at the end of a line into a
    /// no-break space while the word after it is gone, and back once text
    /// follows. Both are one UTF-16 unit, so offsets are unaffected.
    private static func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{00A0}", with: " ") }
}
