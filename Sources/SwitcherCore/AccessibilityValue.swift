import ApplicationServices

/// CopyMultipleAttributeValues can succeed while individual slots are CFNull
/// or an AXValue containing AXError. Check the slot before any typed decoding.
public enum AccessibilityValue {
    /// Some native fields report generic failure for their optional description.
    /// This may omit that label, never text/range/security evidence. A canvas
    /// policy that requires an exact description still rejects the missing label.
    public static func isAbsentAttributeError(_ error: AXError, attribute: String) -> Bool {
        error == .attributeUnsupported || error == .noValue ||
            (error == .failure && attribute == kAXDescriptionAttribute)
    }
    public static func usable(_ value: CFTypeRef?) -> CFTypeRef? {
        guard let value, CFGetTypeID(value) != CFNullGetTypeID() else { return nil }
        if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
        return value
    }
    public static func error(_ value: CFTypeRef?) -> AXError? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError else { return nil }
        var error = AXError.success
        return AXValueGetValue(value as! AXValue, .axError, &error) ? error : nil
    }
    public static func range(_ value: CFTypeRef?) -> CFRange? {
        guard let value = usable(value), CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return range
    }
    public static func ranges(_ value: CFTypeRef?) -> [CFRange]? {
        guard let value = usable(value), CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        let values = value as! CFArray
        var ranges: [CFRange] = []
        for raw in values as [AnyObject] {
            guard let range = range(raw) else { return nil }
            ranges.append(range)
        }
        return ranges
    }
}
