import Foundation

/// The native adapter supplies a prefix ending at the original caret, whose
/// left boundary is a proved whitespace delimiter or the document start.
public struct NativeWordCandidatePlan: Equatable {
    public let text: String
    public let backwardGraphemes: Int

    public static func isFollowingBoundary(_ selection: String?) -> Bool {
        guard let selection else { return true } // Adapter-proved document end.
        return selection.count == 1 && !selection.isEmpty &&
            selection.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// Keep a nonempty prefix selected while extending its active end right.
    /// An unchanged packet proves EOF; a single appended whitespace grapheme
    /// proves a delimiter. Missing callbacks and arbitrary extensions prove neither.
    public static func acceptsRightProbe(prefix: String, expanded: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        if prefix.utf16.elementsEqual(expanded.utf16) { return true }
        guard expanded.count == prefix.count + 1, let last = expanded.last,
              String(last).unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else { return false }
        return expanded.dropLast().utf16.elementsEqual(prefix.utf16)
    }

    public init?(prefix: String) {
        guard prefix.utf16.prefix(NativeServicePayload.utf16Limit + 1).count <= NativeServicePayload.utf16Limit,
              let word = WordScopePlan(value: prefix, caret: prefix.utf16.count),
              NativeServicePayload.accepts(word.text), word.text.count <= 256 else { return nil }
        text = word.text
        backwardGraphemes = word.text.count
    }

    public func matches(_ selected: String) -> Bool { text.utf16.elementsEqual(selected.utf16) }

    public static func containsDelimiter(_ selected: String) -> Bool {
        selected.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// A Shift-Left probe either reaches the start (unchanged selection) or
    /// prepends exactly one complete grapheme. Reject any other movement.
    public static func acceptsLeftProbe(previous: String, expanded: String) -> Bool {
        if previous.utf16.elementsEqual(expanded.utf16) { return true }
        guard expanded.count == previous.count + 1, let first = expanded.first else { return false }
        return String(first).utf16.count + previous.utf16.count == expanded.utf16.count &&
            expanded.utf16.dropFirst(String(first).utf16.count).elementsEqual(previous.utf16)
    }
}
