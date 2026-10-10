import Carbon
import Foundation

/// The utility and native IMK component use the same actual Carbon layouts.
/// Call on main; the bounded two-entry cache retains only layout data/maps.
public enum KeyboardLayoutMapping {
    private static var cachedMappings: [(from: CFData, to: CFData, keyboard: UInt32, value: [Character: String])] = []

    public static func mapping(from: TISInputSource, to: TISInputSource) -> [Character: String]? {
        func data(_ source: TISInputSource) -> CFData? {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        }
        guard let fromData = data(from), let toData = data(to) else { return nil }
        let keyboard = UInt32(LMGetKbdType())
        if let cached = cachedMappings.first(where: { $0.keyboard == keyboard && CFEqual($0.from, fromData) && CFEqual($0.to, toData) }) {
            return cached.value
        }
        func character(_ data: CFData, key: UInt16, shifted: Bool) -> String? {
            guard let bytes = CFDataGetBytePtr(data) else { return nil }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKey: UInt32 = 0
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown),
                shifted ? UInt32(shiftKey >> 8) : 0, keyboard,
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey, buffer.count, &length, &buffer)
            guard status == noErr, length > 0, length <= buffer.count else { return nil }
            let result = String(utf16CodeUnits: buffer, count: length)
            guard !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return result
        }
        var result: [Character: String] = [:]
        for key in UInt16(0)...50 where key != 36 && key != 48 {
            for shifted in [false, true] {
                if let a = character(fromData, key: key, shifted: shifted), a.count == 1,
                   let b = character(toData, key: key, shifted: shifted), let letter = a.first {
                    if result[letter] == nil { result[letter] = b }
                }
            }
        }
        if cachedMappings.count >= 2 { cachedMappings.removeFirst() }
        cachedMappings.append((fromData, toData, keyboard, result))
        return result
    }
}
