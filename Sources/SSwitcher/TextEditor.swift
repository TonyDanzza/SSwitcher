import AppKit
import Carbon
import SwitcherCore

enum TextEditor {
    enum Outcome {
        case converted
        case unverified
        case failure(String)
    }

    private static var isConverting = false

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func selection(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return range
    }

    private static func focusedElement(_ application: AXUIElement) -> AXUIElement? {
        guard let value = attribute(application, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    // Non-activating panels such as Spotlight can own keyboard focus while
    // NSWorkspace.frontmostApplication still points to the underlying app.
    private static func targetApplication() -> NSRunningApplication? {
        if let focused = focusedElement(AXUIElementCreateSystemWide()) {
            var pid: pid_t = 0
            if AXUIElementGetPid(focused, &pid) == .success, let app = NSRunningApplication(processIdentifier: pid) { return app }
        }
        return NSWorkspace.shared.frontmostApplication
    }

    private static func focusedElement(in app: NSRunningApplication) -> AXUIElement? {
        if let focused = focusedElement(AXUIElementCreateSystemWide()) {
            var pid: pid_t = 0
            if AXUIElementGetPid(focused, &pid) == .success, pid == app.processIdentifier { return focused }
        }
        return focusedElement(AXUIElementCreateApplication(app.processIdentifier))
    }

    // Electron exposes its renderer's accessibility tree on demand.
    // https://www.electronjs.org/docs/latest/tutorial/accessibility
    static func prepareAccessibility(for app: NSRunningApplication) {
        guard AXIsProcessTrusted(), let url = app.bundleURL,
              FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func convertAtCursor(isInputUnchanged: @escaping () -> Bool, completion: @escaping (Outcome) -> Void) {
        guard !isConverting else { return }
        guard AXIsProcessTrusted() else { completion(.failure("Разрешите «Универсальный доступ» в меню SSwitcher")); return }
        guard !IsSecureEventInputEnabled() else { completion(.failure("Преобразование недоступно при защищённом вводе")); return }
        guard let app = targetApplication() else { completion(.failure("Нет активного приложения")); return }
        isConverting = true
        prepareAccessibility(for: app)
        // Allow a lazy renderer accessibility tree to become available.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let finish: (Outcome) -> Void = { outcome in
                isConverting = false
                completion(outcome)
            }
            if let error = beginConversion(in: app, isInputUnchanged: isInputUnchanged, completion: finish) { finish(.failure(error)) }
        }
    }

    private static func beginConversion(in app: NSRunningApplication, isInputUnchanged: @escaping () -> Bool, completion: @escaping (Outcome) -> Void) -> String? {
        guard isInputUnchanged(), targetApplication()?.processIdentifier == app.processIdentifier else {
            return "Активное приложение изменилось — повторите"
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let focused = focusedElement(in: app) else {
            copySelection(in: app, isInputUnchanged: isInputUnchanged, completion: completion)
            return nil
        }
        // Web editors may expose a nested text node as focused; find its editor.
        var element = focused
        for _ in 0..<6 {
            if selection(element) != nil { break }
            guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        AXUIElementSetMessagingTimeout(element, 0.5)
        if attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
            return "В защищённых полях преобразование отключено"
        }
        guard let selectedRange = selection(element) else {
            copySelection(in: app, isInputUnchanged: isInputUnchanged, completion: completion)
            return nil
        }
        var targetRange = selectedRange
        let original: String
        if selectedRange.length > 0, let selected = attribute(element, kAXSelectedTextAttribute) as? String, !selected.isEmpty {
            original = selected
        } else {
            guard let value = attribute(element, kAXValueAttribute) as? String else {
                copySelection(in: app, isInputUnchanged: isInputUnchanged, completion: completion)
                return nil
            }
            let string = value as NSString
            guard selectedRange.location <= string.length,
                  selectedRange.length <= string.length - selectedRange.location else { return "Положение курсора изменилось — повторите" }
            if selectedRange.length > 0 {
                original = string.substring(with: NSRange(location: selectedRange.location, length: selectedRange.length))
            } else {
                guard let range = TextConversion.tokenRange(in: value, caret: selectedRange.location) else { return "Рядом с курсором нет слова" }
                targetRange = CFRange(location: range.location, length: range.length)
                original = string.substring(with: range)
            }
        }
        guard let conversion = InputSources.prepare(original) else {
            return "Добавьте английскую и русскую раскладки в настройках клавиатуры"
        }
        guard conversion.text != original else { return "В выбранном фрагменте нет символов для преобразования" }
        guard let clipboard = ClipboardInsertion() else { return "Не удалось сохранить текущий буфер обмена" }

        func sameFocus() -> Bool {
            guard isInputUnchanged(), targetApplication()?.processIdentifier == app.processIdentifier,
                  let current = focusedElement(in: app) else { return false }
            return CFEqual(current, focused)
        }
        guard sameFocus(), let current = selection(element),
              current.location == selectedRange.location, current.length == selectedRange.length else {
            return "Курсор или выделение изменились — повторите"
        }
        if selectedRange.length == 0 {
            guard let value = AXValueCreate(.cfRange, &targetRange),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
                return "Это поле не позволяет выделить слово через macOS Accessibility"
            }
        }
        // AX selection changes in web renderers can be asynchronous. Never paste
        // until the exact intended range is acknowledged by the target editor.
        func waitForSelection(_ attempt: Int) {
            guard sameFocus() else { completion(.failure("Активное поле изменилось — повторите")); return }
            guard let current = selection(element), current.location == targetRange.location, current.length == targetRange.length else {
                if attempt < 4 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { waitForSelection(attempt + 1) }
                } else { completion(.failure("Редактор не подтвердил выделение слова")) }
                return
            }
            guard clipboard.paste(conversion.text) else { completion(.failure("Не удалось вставить преобразованный текст")); return }
            verifyInsertion(remaining: 8)
        }
        func verifyInsertion(remaining: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Never read another field or change its input source if focus moved.
                guard sameFocus() else {
                    clipboard.restore()
                    completion(.unverified)
                    return
                }
                let actual = text(in: element, range: CFRange(location: targetRange.location, length: (conversion.text as NSString).length))
                if actual == conversion.text {
                    // Give the receiving app time to finish handling Paste before
                    // restoring the clipboard, even if AX updates immediately.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        clipboard.restore()
                        if sameFocus() { TISSelectInputSource(conversion.target) }
                        completion(.converted)
                    }
                } else if remaining > 0 {
                    verifyInsertion(remaining: remaining - 1)
                } else {
                    clipboard.restore()
                    completion(actual == nil ? .unverified : .failure("Редактор не заменил текст. Попробуйте выделить его вручную"))
                }
            }
        }
        waitForSelection(0)
        return nil
    }

    /// Canvas editors can expose neither numeric ranges nor text through AX.
    /// Copy only the user's existing selection; never guess a caret position.
    private static func copySelection(in app: NSRunningApplication, isInputUnchanged: @escaping () -> Bool, completion: @escaping (Outcome) -> Void) {
        guard let clipboard = PasteboardTransaction() else {
            completion(.failure("Не удалось сохранить текущий буфер обмена")); return
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        let originalFocus = focusedElement(in: app)
        func stillValid() -> Bool {
            guard isInputUnchanged(), targetApplication()?.processIdentifier == app.processIdentifier else { return false }
            if let originalFocus {
                guard let current = focusedElement(in: app) else { return false }
                return CFEqual(originalFocus, current)
            }
            return true
        }
        guard stillValid(), clipboard.write("SSwitcher-copy-\(UUID().uuidString)"), KeyboardEvents.command(8) else {
            clipboard.restore()
            completion(.failure("Не удалось прочитать выделение")); return
        }
        func awaitCopy(_ remaining: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard stillValid() else {
                    clipboard.restore()
                    completion(.failure("Ввод или активное поле изменились — повторите")); return
                }
                if !clipboard.hasCopyResult && remaining > 0 { awaitCopy(remaining - 1); return }
                guard let selected = clipboard.acceptCopyResult(), !selected.isEmpty else {
                    clipboard.restore()
                    completion(.failure("Редактор скрывает курсор. Выделите символы текста и повторите")); return
                }
                guard let conversion = InputSources.prepare(selected) else {
                    clipboard.restore()
                    completion(.failure("Добавьте английскую и русскую раскладки")); return
                }
                guard conversion.text != selected else {
                    clipboard.restore()
                    completion(.failure("В выделении нет символов для преобразования")); return
                }
                guard stillValid(), clipboard.write(conversion.text), KeyboardEvents.command(9) else {
                    clipboard.restore()
                    completion(.failure("Вставка отменена: поле или буфер обмена изменились")); return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    clipboard.restore()
                    if stillValid() { TISSelectInputSource(conversion.target) }
                    completion(.unverified)
                }
            }
        }
        awaitCopy(9)
    }

    private static func text(in element: AXUIElement, range: CFRange) -> String? {
        var range = range
        if let value = AXValueCreate(.cfRange, &range) {
            var result: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, value, &result) == .success,
               let string = result as? String { return string }
        }
        if let value = attribute(element, kAXValueAttribute) as? String {
            let string = value as NSString
            if range.location <= string.length && range.length <= string.length - range.location {
                return string.substring(with: NSRange(location: range.location, length: range.length))
            }
        }
        return nil
    }
}
