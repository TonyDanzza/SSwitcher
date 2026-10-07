import Foundation

/// A verified system search dialog can own keyboard focus while the workspace
/// still reports its background application. This is not a general PID bypass.
public enum SpotlightSearchScope {
    public static func isVerified(bundleID: String, role: String?, subrole: String?, identifier: String?,
                                  windowRole: String?, windowSubrole: String?, isSecure: Bool = false) -> Bool {
        !isSecure && bundleID == "com.apple.campo" && role == "AXTextField" && subrole == "AXSearchField" &&
            identifier == "SpotlightSearchField" && windowRole == "AXWindow" && windowSubrole == "AXSystemDialog"
    }

    public static func permitsTarget(foregroundPID: Int32, targetPID: Int32, verifiedOverlay: Bool) -> Bool {
        foregroundPID > 0 && targetPID > 0 && (foregroundPID == targetPID || verifiedOverlay)
    }

    public static func matchesFocus(expectedPID: Int32, actualPID: Int32, sameField: Bool,
                                    sameWindow: Bool, verifiedIdentity: Bool) -> Bool {
        expectedPID > 0 && expectedPID == actualPID && sameField && sameWindow && verifiedIdentity
    }

    public static func hasRequiredNativeRangeCapability(verifiedOverlay: Bool, nativeRangeSettable: Bool) -> Bool {
        !verifiedOverlay || nativeRangeSettable
    }

    public static func acceptsDocument(_ text: String?) -> Bool {
        guard let text, !AccessibilitySelectionPlan.hasTextAttachment(text) else { return false }
        return text.unicodeScalars.allSatisfy {
            $0.properties.generalCategory != .control && $0.value != 0x2028 && $0.value != 0x2029
        }
    }

    /// Whole-query writes are allowed only after deriving the exact one-word
    /// edit at a coherent empty caret. Repeated words never identify scope.
    public static func wordReplacement(document: String, caret: NSRange, replacement: String) -> AccessibilityReplacementPlan? {
        guard acceptsDocument(document), acceptsDocument(replacement), caret.length == 0,
              AccessibilitySelectionPlan.checkedRange(caret, in: document) != nil,
              let word = WordCursorPlan(value: document, caret: caret.location), word.text.count == replacement.count,
              let selection = AccessibilitySelectionPlan(document: document,
                  range: NSRange(location: caret.location - word.text.utf16.count, length: word.text.utf16.count), selectedText: word.text),
              let result = selection.replacing(with: replacement), acceptsDocument(result.document) else { return nil }
        return result
    }
}
