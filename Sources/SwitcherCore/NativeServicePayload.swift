/// A Services packet is the OS requestor's selected plain-text scope, not an
/// AX document. Literal line endings and composed characters are preserved.
public enum NativeServicePayload {
    public static let utf16Limit = 65_536

    public static func accepts(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf16.prefix(utf16Limit + 1).count <= utf16Limit else { return false }
        var needsLF = false
        for scalar in text.unicodeScalars {
            if needsLF && scalar.value != 0x0A { return false }
            needsLF = scalar.value == 0x0D
            if scalar.value == 0xFFFC { return false }
            if scalar.properties.generalCategory == .control && scalar.value != 0x09 && scalar.value != 0x0A && scalar.value != 0x0D { return false }
        }
        return !needsLF
    }
}
