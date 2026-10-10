import Carbon
import InputMethodSupport
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
        guard let mapping = KeyboardLayoutMapping.mapping(from: from, to: to) else { return nil }
        return Conversion(text: TextConversion.convert(text, mapping: mapping), target: to)
    }

}
