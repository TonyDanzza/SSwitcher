import Foundation

/// A native word selection and a separately observed right-hand delimiter.
/// End-of-document is adapter evidence, never inferred from a missing packet.
public struct NativeWordBoundaryPlan {
    public let word: String
    /// Whitespace after the word that the caret followed; returned unchanged.
    public let trailing: String
    public var selection: String { word + trailing }
    public init?(selection: String) {
        guard NativeServicePayload.accepts(selection),
              let candidate = NativeWordCandidatePlan(prefix: selection),
              candidate.matches(selection) else { return nil }
        word = selection
        trailing = ""
    }
    /// A single Option+Shift+Left selection from an unprobed caret: the word
    /// before it, optionally followed by the whitespace the caret was after.
    public init?(directSelection selection: String) {
        let trailing = String(selection.reversed().prefix { $0.isWhitespace }.reversed())
        guard trailing.count < selection.count,
              let plan = NativeWordBoundaryPlan(selection: String(selection.dropLast(trailing.count))) else { return nil }
        word = plan.word
        self.trailing = trailing
    }
    public func matches(_ selection: String) -> Bool { self.selection.utf16.elementsEqual(selection.utf16) }
    public func acceptsFollowingSelection(_ selection: String) -> Bool {
        Self.isFollowingDelimiter(selection)
    }
    public static func isFollowingDelimiter(_ selection: String) -> Bool {
        selection.count == 1 && !selection.isEmpty &&
            selection.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
