import Foundation

/// A native word selection and a separately observed right-hand delimiter.
/// End-of-document is adapter evidence, never inferred from a missing packet.
public struct NativeWordBoundaryPlan {
    public let word: String
    public init?(selection: String) {
        guard NativeServicePayload.accepts(selection),
              let candidate = NativeWordCandidatePlan(prefix: selection),
              candidate.matches(selection) else { return nil }
        word = selection
    }
    public func matches(_ selection: String) -> Bool { word.utf16.elementsEqual(selection.utf16) }
    public func acceptsFollowingSelection(_ selection: String) -> Bool {
        Self.isFollowingDelimiter(selection)
    }
    public static func isFollowingDelimiter(_ selection: String) -> Bool {
        selection.count == 1 && !selection.isEmpty &&
            selection.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
