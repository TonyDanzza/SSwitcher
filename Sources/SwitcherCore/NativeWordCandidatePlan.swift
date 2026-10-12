import Foundation

/// The last word of a prefix ending at the original caret: its left boundary
/// is a whitespace delimiter or the document start.
public struct NativeWordCandidatePlan: Equatable {
    public let text: String

    public init?(prefix: String) {
        guard prefix.utf16.prefix(NativeServicePayload.utf16Limit + 1).count <= NativeServicePayload.utf16Limit,
              let word = WordScopePlan(value: prefix, caret: prefix.utf16.count),
              NativeServicePayload.accepts(word.text), word.text.count <= 256 else { return nil }
        text = word.text
    }

    public func matches(_ selected: String) -> Bool { text.utf16.elementsEqual(selected.utf16) }
}
