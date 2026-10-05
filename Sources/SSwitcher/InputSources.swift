import Carbon
import SwitcherCore

enum InputSources {
    struct Conversion {
        let text: String
        let target: TISInputSource
    }

    static func string(_ property: CFString, of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, property) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    static var currentName: String {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "—" }
        return string(kTISPropertyLocalizedName, of: current) ?? "—"
    }

    private static func languages(_ source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        return Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String] ?? []
    }

    static func prepare(_ text: String) -> Conversion? {
        let filter = [
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout as Any,
            kTISPropertyInputSourceIsSelectCapable: true,
            kTISPropertyInputSourceIsEnabled: true
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue(),
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        let sources = list as! [TISInputSource]
        let currentID = string(kTISPropertyInputSourceID, of: current)
        func source(for language: String) -> TISInputSource? {
            let matches = sources.filter { languages($0).contains { $0 == language || $0.hasPrefix(language + "-") } }
            return matches.first { string(kTISPropertyInputSourceID, of: $0) == currentID } ?? matches.first
        }
        guard let english = source(for: "en"), let russian = source(for: "ru") else { return nil }
        let fallback: TextConversion.Direction = languages(current).contains("ru") ? .toEnglish : .toRussian
        let direction = TextConversion.direction(for: text, fallback: fallback)
        let from = direction == .toEnglish ? russian : english
        let to = direction == .toEnglish ? english : russian
        guard let mapping = mapping(from: from, to: to) else { return nil }
        return Conversion(text: TextConversion.convert(text, mapping: mapping), target: to)
    }

    // Use actual installed layouts, including Russian vs Russian-PC punctuation.
    private static func mapping(from: TISInputSource, to: TISInputSource) -> [Character: String]? {
        func data(_ source: TISInputSource) -> CFData? {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        }
        guard let fromData = data(from), let toData = data(to) else { return nil }
        func character(_ data: CFData, key: UInt16, shifted: Bool) -> String? {
            guard let bytes = CFDataGetBytePtr(data) else { return nil }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKey: UInt32 = 0
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown),
                shifted ? UInt32(shiftKey >> 8) : 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey, buffer.count, &length, &buffer)
            guard status == noErr, length > 0 else { return nil }
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
        return result
    }
}
