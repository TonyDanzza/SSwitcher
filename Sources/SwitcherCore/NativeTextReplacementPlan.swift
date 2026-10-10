import Foundation

/// Complete IMK document evidence. A clipped surrounding-text reply cannot
/// become a replacement plan, even when the requested word is present.
public struct NativeTextSnapshot: Equatable {
    public static let documentLimit = 65_536
    public let document: String
    public let selection: NSRange
    public let marked: NSRange

    public init?(document: String?, length: Int, actualRange: NSRange, selection: NSRange, marked: NSRange) {
        guard length >= 0, length <= Self.documentLimit, let document,
              document.utf16.count == length, actualRange == NSRange(location: 0, length: length),
              !AccessibilitySelectionPlan.hasTextAttachment(document),
              AccessibilitySelectionPlan.checkedRange(selection, in: document) != nil else { return nil }
        // NSNotFound/NSNotFound means unavailable in IMK, not proof that no
        // composition exists. Cocoa's ordinary unmarked range is NSNotFound/0.
        if marked.location == NSNotFound {
            guard marked.length == 0 else { return nil }
        } else {
            guard marked.length == 0, AccessibilitySelectionPlan.checkedRange(marked, in: document) != nil else { return nil }
        }
        self.document = document
        self.selection = selection
        self.marked = marked
    }

    public func matches(_ other: Self) -> Bool {
        selection == other.selection && marked == other.marked &&
            AccessibilitySelectionPlan.exactlyEqual(document, other.document)
    }

    public static func == (left: Self, right: Self) -> Bool { left.matches(right) }
}

/// A pure whole-document plan shared with the existing selection/caret proof.
/// A new gesture always plans from the actual snapshot, never old highlights.
public struct NativeTextReplacementPlan {
    public let original: NativeTextSnapshot
    public let scope: AccessibilitySelectionPlan
    public var isSelection: Bool { original.selection.length > 0 }

    public init?(snapshot: NativeTextSnapshot) {
        let range: NSRange
        if snapshot.selection.length > 0 {
            range = snapshot.selection
        } else {
            guard let word = WordScopePlan(value: snapshot.document, caret: snapshot.selection.location) else { return nil }
            range = word.range
        }
        guard let scope = AccessibilitySelectionPlan(document: snapshot.document, range: range, selectedText: nil) else { return nil }
        self.original = snapshot
        self.scope = scope
    }

    public func matches(_ snapshot: NativeTextSnapshot) -> Bool { original.matches(snapshot) }

    public func replacing(with text: String) -> AccessibilityReplacementPlan? {
        guard let result = scope.replacing(with: text), result.document.utf16.count <= NativeTextSnapshot.documentLimit else { return nil }
        return result
    }

    public func confirms(_ replacement: AccessibilityReplacementPlan, snapshot: NativeTextSnapshot) -> Bool {
        replacement.confirmsCaret(document: snapshot.document, range: snapshot.selection, selectedText: nil)
    }
}
