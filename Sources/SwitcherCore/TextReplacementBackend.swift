/// Selected-text setters need demonstrated behavior, not merely a successful
/// capability query. Other editors keep the immutable Unicode event transport.
public enum TextReplacementBackend: Equatable {
    case unicodeEvents
    case accessibilitySelectedText

    public static func select(isSelected: Bool, bundleID: String, isCurrentProcess: Bool,
                              isElectron: Bool, role: String?, selectedTextSettable: Bool) -> Self {
        guard isSelected, selectedTextSettable, !isElectron, role == "AXTextArea",
              isCurrentProcess || bundleID == "com.apple.TextEdit" else { return .unicodeEvents }
        return .accessibilitySelectedText
    }

    /// Native replacement can carry literal line characters without a Return
    /// key. Keep other unproven controls refused, before the setter is issued.
    public static func acceptsNativeText(_ text: String) -> Bool {
        !text.isEmpty && !AccessibilitySelectionPlan.hasTextAttachment(text) && text.unicodeScalars.allSatisfy {
            $0.value == 0x0A || $0.value == 0x2028 || ($0.properties.generalCategory != .control && $0.value != 0x2029)
        }
    }
}
