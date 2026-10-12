import Carbon
import InputMethodSupport
import SwitcherCore

enum InputSources {
    // Accessed on the AppKit main thread alongside conversion and notices.
    private static var observation = InputSourceObservation(sourceID: currentID)

    static var currentID: String? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(kTISPropertyInputSourceID, of: current)
    }

    static func sourceChanged() -> Bool { observation.observe(currentID) }

    /// The key's character in the current ASCII-capable layout (ABC), so a
    /// shortcut reads "⌃⌥⌘F" while a Russian layout is selected.
    static func asciiCharacter(forKeyCode key: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        guard UCKeyTranslate(layout, key, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                             OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey, buffer.count, &length, &buffer) == noErr,
              length > 0 else { return nil }
        let result = String(utf16CodeUnits: buffer, count: length)
        return result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == " " }) ? nil : result
    }

    @discardableResult
    static func selectAfterConversion(_ source: TISInputSource) -> OSStatus {
        // Initialize the baseline before changing the source. An observer
        // then reads current state instead of treating every notice as input.
        _ = observation
        let reply = TISSelectInputSource(source)
        observation.confirmedSelection(requestedID: string(kTISPropertyInputSourceID, of: source),
            actualID: currentID, succeeded: reply == noErr)
        return reply
    }

    struct Conversion {
        let text: String
        let target: TISInputSource
    }

    static func string(_ property: CFString, of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, property) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
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
