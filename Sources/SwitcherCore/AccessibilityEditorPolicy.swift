/// A text range and settable AXValue alone do not establish an editing session:
/// Figma exposes those attributes for a selected canvas layer outside editing.
public enum AccessibilityEditorPolicy {
    public static func isFigmaCanvas(isFigma: Bool, role: String?, description: String?) -> Bool {
        isFigma && role == "AXTextArea" && description == "Text"
    }

    public static func permitsEditing(isFigma: Bool, role: String?, description: String?) -> Bool {
        if isFigma, role == "AXTextArea", description?.isEmpty != false { return false }
        return ["AXTextArea", "AXTextField", "AXComboBox"].contains(role ?? "")
    }
}
