/// The characters the user has typed since the caret last moved, kept only in
/// memory, so a freshly typed word can be retyped without selecting it.
/// Clicks, navigation, shortcuts, Return and unknown keys forget everything;
/// the run never holds more than one long word and is never stored.
public struct TypedWordTracker {
    public enum Candidate: Equatable {
        /// Nothing is known about the text before the caret.
        case unknown
        /// The caret follows a typed space: there is no word to convert.
        case afterSpace
        /// Exactly these characters are immediately before the caret.
        /// `boundedStart` means a typed space precedes them, so the word has
        /// no unknown prefix.
        case word(String, boundedStart: Bool)
    }

    public static let capacity = 64
    private var run = ""
    private var overflow = false

    public init() {}

    public var candidate: Candidate {
        guard !overflow, let last = run.last else { return .unknown }
        if Self.isSpace(last) { return .afterSpace }
        guard let space = run.lastIndex(where: Self.isSpace) else { return .word(run, boundedStart: false) }
        return .word(String(run[run.index(after: space)...]), boundedStart: true)
    }

    /// Characters produced by one ordinary key press (no Command, Control or
    /// Option). Control, function and private-use characters move the caret
    /// or edit unpredictably, so they forget the run.
    public mutating func typed(_ text: String) {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(Self.isTypedScalar) else { reset(); return }
        for character in text {
            if overflow {
                // A word longer than the capacity stays unknown until a space.
                guard Self.isSpace(character) else { continue }
                overflow = false
                run = ""
            }
            run.append(character)
        }
        guard run.count > Self.capacity else { return }
        if let space = run.lastIndex(where: Self.isSpace) { run = String(run[space...]) }
        if run.count > Self.capacity { run = ""; overflow = true }
    }

    /// Deleting back across a space forgets the run: editors may autocorrect
    /// the previous word when the space was typed, so its characters are no
    /// longer known.
    public mutating func backspace() {
        guard !overflow, let last = run.last else { return }
        if Self.isSpace(last) { reset() } else { run.removeLast() }
    }

    public mutating func reset() {
        run = ""
        overflow = false
    }

    /// Our own retyping is not observed as user input; record its result so a
    /// second gesture converts the word back.
    public mutating func replaceWord(_ word: String, with replacement: String) {
        guard !overflow, !word.isEmpty, run.hasSuffix(word) else { reset(); return }
        run.removeLast(word.count)
        run.append(replacement)
    }

    /// Text read back from the editor itself now ends at the caret.
    public mutating func assume(_ text: String) {
        reset()
        typed(text)
    }

    /// One Backspace removes one of these characters in an ordinary editor.
    /// Composed or astral characters are refused rather than guessed.
    public static func backspaceCount(for word: String) -> Int? {
        guard !word.isEmpty, word.unicodeScalars.count == word.count, word.utf16.count == word.count else { return nil }
        return word.count
    }

    /// Option+Backspace deletes exactly this word only when it starts after a
    /// typed space and has no punctuation that an editor treats as a boundary.
    public static func deletesAsOneWord(_ word: String, boundedStart: Bool) -> Bool {
        boundedStart && backspaceCount(for: word) != nil && word.allSatisfy(\.isLetter)
    }

    private static func isSpace(_ character: Character) -> Bool { character == " " || character == "\u{00A0}" }

    private static func isTypedScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " || scalar == "\u{00A0}" { return true }
        if (0xE000...0xF8FF).contains(scalar.value) { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator, .unassigned, .privateUse, .surrogate:
            return false
        default:
            return true
        }
    }
}
