import AppKit
import Carbon
import SwitcherCore

enum TextEditor {
    static func convertAtCursor() -> String? {
        guard AXIsProcessTrusted() else { return "Разрешите «Универсальный доступ» в меню SSwitcher" }
        guard let app = NSWorkspace.shared.frontmostApplication else { return "Нет активного приложения" }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        guard let focused = attribute(application, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return "Поставьте курсор в редактируемый текст" }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)
        if attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
            return "В защищённых полях преобразование отключено"
        }
        guard let rangeValue = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return "Это поле не предоставляет положение курсора через macOS Accessibility"
        }
        var selectedRange = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selectedRange),
              selectedRange.location >= 0, selectedRange.length >= 0 else { return "Не удалось прочитать выделение" }

        var targetRange = selectedRange
        let original: String
        if selectedRange.length > 0, let selected = attribute(element, kAXSelectedTextAttribute) as? String, !selected.isEmpty {
            original = selected
        } else {
            guard let value = attribute(element, kAXValueAttribute) as? String else {
                return "Это поле не предоставляет текст через macOS Accessibility"
            }
            let string = value as NSString
            guard selectedRange.location <= string.length,
                  selectedRange.length <= string.length - selectedRange.location else { return "Положение курсора изменилось — повторите" }
            if selectedRange.length > 0 {
                original = string.substring(with: NSRange(location: selectedRange.location, length: selectedRange.length))
            } else {
                guard let range = TextConversion.tokenRange(in: value, caret: selectedRange.location) else {
                    return "Рядом с курсором нет слова"
                }
                targetRange = CFRange(location: range.location, length: range.length)
                original = string.substring(with: range)
            }
        }
        guard let conversion = InputSources.prepare(original) else {
            return "Добавьте английскую и русскую раскладки в настройках клавиатуры"
        }
        guard conversion.text != original else { return nil }
        // Unicode input replaces the selected text without changing the clipboard.
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return "Не удалось создать событие ввода"
        }
        let characters = Array(conversion.text.utf16)
        down.flags = []
        up.flags = []
        characters.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return "Активное приложение изменилось — повторите"
        }
        guard let stillFocused = attribute(application, kAXFocusedUIElementAttribute),
              CFEqual(stillFocused, element),
              let stillSelected = attribute(element, kAXSelectedTextRangeAttribute),
              CFEqual(stillSelected, rangeValue) else {
            return "Курсор или выделение изменились — повторите"
        }
        if selectedRange.length == 0 {
            guard let value = AXValueCreate(.cfRange, &targetRange),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
                return "Это поле не позволяет выделить слово через macOS Accessibility"
            }
        }
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
        if TISSelectInputSource(conversion.target) != noErr {
            return "Текст отправлен, но переключить источник ввода не удалось"
        }
        return nil
    }
}
