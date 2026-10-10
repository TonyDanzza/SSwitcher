import Foundation

/// A native full-document selection can restore the original caret from its
/// nearer edge. Exact UTF-16 and grapheme checks prevent offset guessing.
public struct NativeDocumentCaretPlan {
    public let fromEnd: Bool
    public let offsetGraphemes: Int

    public init?(prefix: String, document: String) {
        guard NativeServicePayload.accepts(prefix), NativeServicePayload.accepts(document),
              document.utf16.starts(with: prefix.utf16),
              AccessibilitySelectionPlan.checkedRange(NSRange(location: prefix.utf16.count, length: 0), in: document) != nil else { return nil }
        let before = prefix.count
        let after = document.count - before
        guard min(before, after) <= 256 else { return nil }
        fromEnd = after <= before
        offsetGraphemes = min(before, after)
    }
}

/// Exact native document/prefix packets prove a token ending at the original
/// caret. Only this token, never the surrounding prefix, may be committed.
public struct NativeWordDocumentPlan {
    public let word: String
    public let caret: NativeDocumentCaretPlan

    public init?(prefix: String, document: String) {
        guard let caret = NativeDocumentCaretPlan(prefix: prefix, document: document),
              let scope = WordScopePlan(value: document, caret: prefix.utf16.count),
              let prefixScope = WordScopePlan(value: prefix, caret: prefix.utf16.count),
              scope.range == prefixScope.range, scope.text.utf16.elementsEqual(prefixScope.text.utf16),
              scope.text.count <= 256 else { return nil }
        self.caret = caret
        word = scope.text
    }

    public func matches(_ packet: String) -> Bool { word.utf16.elementsEqual(packet.utf16) }
}
