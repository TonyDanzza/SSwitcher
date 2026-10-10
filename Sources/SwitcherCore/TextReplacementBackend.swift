/// Working Unicode transports stay unchanged. A native selected-fragment
/// setter can carry a payload that cannot be represented safely by that
/// transport, with fresh capability/scope proof and exact acknowledgement.
public enum TextReplacementBackend: Equatable {
    case unicodeEvents
    case accessibilitySelectedText
    case accessibilitySpotlightQuery

    public static func select(isSelected: Bool, bundleID: String, isCurrentProcess: Bool,
                              isElectron: Bool, role: String?, selectedTextSettable: Bool,
                              verifiedSpotlightSearch: Bool = false, queryValueSettable: Bool = false,
                              queryRangeSettable: Bool = false, requiresNativePayload: Bool = false,
                              isFigma: Bool = false) -> Self {
        if !isSelected, verifiedSpotlightSearch, bundleID == "com.apple.campo", role == "AXTextField",
           !isElectron, queryValueSettable, queryRangeSettable { return .accessibilitySpotlightQuery }
        guard isSelected, selectedTextSettable, !isElectron else { return .unicodeEvents }
        if verifiedSpotlightSearch, bundleID == "com.apple.campo", role == "AXTextField" { return .accessibilitySelectedText }
        guard role == "AXTextArea",
              isCurrentProcess || bundleID == "com.apple.TextEdit" || (requiresNativePayload && !isFigma) else { return .unicodeEvents }
        return .accessibilitySelectedText
    }

    /// Native replacement can carry literal line characters without a Return
    /// key. Keep other unproven controls refused, before the setter is issued.
    public static func acceptsNativeText(_ text: String, permitsLineBreaks: Bool = true) -> Bool {
        if !permitsLineBreaks { return !text.isEmpty && SpotlightSearchScope.acceptsDocument(text) }
        return !text.isEmpty && !AccessibilitySelectionPlan.hasTextAttachment(text) && text.unicodeScalars.allSatisfy {
            $0.value == 0x0A || $0.value == 0x2028 || ($0.properties.generalCategory != .control && $0.value != 0x2029)
        }
    }
}
