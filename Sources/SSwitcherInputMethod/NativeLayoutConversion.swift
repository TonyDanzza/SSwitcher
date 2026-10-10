import Carbon
import InputMethodSupport
import SwitcherCore

struct NativeLayoutConversion {
    let text: String
    let targetMode: InputMethodIdentity.Mode

    static func prepare(_ text: String, mode: InputMethodIdentity.Mode) -> Self? {
        guard let english = InputMethodIdentity.systemKeyboardSource(for: .english),
              let russian = InputMethodIdentity.systemKeyboardSource(for: .russian) else { return nil }
        let fallback: TextConversion.Direction = mode == .russian ? .toEnglish : .toRussian
        let direction = TextConversion.direction(for: text, fallback: fallback)
        let from = direction == .toEnglish ? russian : english
        let to = direction == .toEnglish ? english : russian
        guard let mapping = KeyboardLayoutMapping.mapping(from: from, to: to) else { return nil }
        return Self(text: TextConversion.convert(text, mapping: mapping), targetMode: direction == .toEnglish ? .english : .russian)
    }
}
