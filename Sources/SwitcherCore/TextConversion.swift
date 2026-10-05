import Foundation

public enum TextConversion {
    public enum Direction { case toEnglish, toRussian }

    public static func direction(for text: String, fallback: Direction) -> Direction {
        let latin = text.unicodeScalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) }.count
        let russian = text.unicodeScalars.filter { (0x0410...0x044F).contains($0.value) || $0.value == 0x0401 || $0.value == 0x0451 }.count
        if latin == russian { return fallback }
        return russian > latin ? .toEnglish : .toRussian
    }

    public static func convert(_ text: String, mapping: [Character: String]) -> String {
        text.map { mapping[$0] ?? String($0) }.joined()
    }

    /// AX uses UTF-16 offsets. Include punctuation because [ and ; produce
    /// Russian letters; whitespace separates tokens.
    public static func tokenRange(in text: String, caret: Int) -> NSRange? {
        let string = text as NSString
        guard caret >= 0, caret <= string.length, string.length > 0 else { return nil }
        func isWhitespace(_ range: NSRange) -> Bool {
            string.substring(with: range).unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }
        var anchor = caret
        if anchor == string.length || isWhitespace(string.rangeOfComposedCharacterSequence(at: anchor)) {
            guard anchor > 0 else { return nil }
            let previous = string.rangeOfComposedCharacterSequence(at: anchor - 1)
            guard !isWhitespace(previous) else { return nil }
            anchor = previous.location
        }
        var range = string.rangeOfComposedCharacterSequence(at: anchor)
        while range.location > 0 {
            let previous = string.rangeOfComposedCharacterSequence(at: range.location - 1)
            if isWhitespace(previous) { break }
            range = NSUnionRange(range, previous)
        }
        while NSMaxRange(range) < string.length {
            let next = string.rangeOfComposedCharacterSequence(at: NSMaxRange(range))
            if isWhitespace(next) { break }
            range = NSUnionRange(range, next)
        }
        return range
    }
}
