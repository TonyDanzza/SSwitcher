/// A text range and settable AXValue alone do not establish an editing session:
/// Figma exposes those attributes for a selected canvas layer outside editing.
public enum AccessibilityEditorPolicy {
    public static func isFigmaCanvas(isFigma: Bool, role: String?, description: String?) -> Bool {
        isFigma && role == "AXTextArea" && description == "Text"
    }

    /// Pages reports its document scroll area as focused until an assistive
    /// client asks for AXEnhancedUserInterface; only then does the text element
    /// exist and take the focus. Only such a container focus, with no text
    /// range anywhere above it, is worth that one request.
    public static func needsCanvasFocusPreparation(focusRole: String?, textRangeFound: Bool) -> Bool {
        !textRangeFound && ["AXScrollArea", "AXLayoutArea"].contains(focusRole ?? "")
    }

    /// The woken focus may become the editor only if it is a focused text
    /// element with a selection range.
    public static func isFocusedTextCandidate(role: String?, focused: Bool, hasRange: Bool) -> Bool {
        focused && hasRange && ["AXTextArea", "AXTextField"].contains(role ?? "")
    }

    public static func permitsEditing(isFigma: Bool, role: String?, description: String?) -> Bool {
        if isFigma, role == "AXTextArea", description?.isEmpty != false { return false }
        return ["AXTextArea", "AXTextField", "AXComboBox"].contains(role ?? "")
    }
}
