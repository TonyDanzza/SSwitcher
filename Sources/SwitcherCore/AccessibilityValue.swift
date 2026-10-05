import ApplicationServices

/// CopyMultipleAttributeValues can succeed while individual slots are CFNull
/// or an AXValue containing AXError. Check the slot before any typed decoding.
public enum AccessibilityValue {
    public static func usable(_ value: CFTypeRef?) -> CFTypeRef? {
        guard let value, CFGetTypeID(value) != CFNullGetTypeID() else { return nil }
        if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
        return value
    }
    public static func range(_ value: CFTypeRef?) -> CFRange? {
        guard let value = usable(value), CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return range
    }
}
