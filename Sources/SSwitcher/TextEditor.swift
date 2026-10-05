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
    static var diagnosticDetails = ""
    private static var pendingConversion: (() -> Void)?
    private static var verifiedCanvasSelection: (pid: pid_t, text: String, word: WordCursorPlan?, isInputUnchanged: () -> Bool)?

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
        if isConverting {
            let pid = targetApplication()?.processIdentifier
            pendingConversion = {
                guard isInputUnchanged(), targetApplication()?.processIdentifier == pid else {
                    completion(.failure("Ввод или активное поле изменились — повторите")); return
                }
                convertAtCursor(isInputUnchanged: isInputUnchanged, completion: completion)
            }
            return
        }
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
                let next = pendingConversion
                pendingConversion = nil
                next?()
            }
            if let error = beginConversion(in: app, isInputUnchanged: isInputUnchanged, completion: finish) { finish(.failure(error)) }
        }
    }

    private static func beginConversion(in app: NSRunningApplication, isInputUnchanged: @escaping () -> Bool, completion: @escaping (Outcome) -> Void) -> String? {
        guard isInputUnchanged(), targetApplication()?.processIdentifier == app.processIdentifier else {
            return "Активное приложение изменилось — повторите"
        }
        // Figma's AX document selection can differ from its canvas selection.
        // Setting an AX range may update the accessibility mirror only; Paste
        // then inserts at the canvas caret. Use the editor's own Copy command
        // as the source of truth and keyboard selection for this application.
        if app.bundleIdentifier == "com.figma.Desktop" {
            copySelection(in: app, isInputUnchanged: isInputUnchanged, completion: completion)
            return nil
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
        diagnosticDetails = "AX: \(app.localizedName ?? ""); диапазон \(selectedRange.location):\(selectedRange.length)"
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
        // Ordinary words can be replaced with Backspace + Paste without showing
        // a selection. Use range replacement for complex Unicode clusters:
        // editors disagree on how many Backspaces delete an emoji/combining mark.
        let withoutSelection = selectedRange.length == 0 && original.utf16.count == original.count && original.count <= 256
        let deletionCount = withoutSelection ? original.count : 0
        var insertionRange = withoutSelection
            ? CFRange(location: targetRange.location + targetRange.length, length: 0)
            : targetRange
        if selectedRange.length == 0 {
            guard let value = AXValueCreate(.cfRange, &insertionRange),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
                return "Это поле не позволяет переместить курсор через macOS Accessibility"
            }
        }
        // AX selection changes in web renderers can be asynchronous. Never paste
        // until the exact intended range is acknowledged by the target editor.
        func waitForSelection(_ attempt: Int) {
            guard sameFocus() else { completion(.failure("Активное поле изменилось — повторите")); return }
            guard let current = selection(element), current.location == insertionRange.location, current.length == insertionRange.length else {
                if attempt < 4 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { waitForSelection(attempt + 1) }
                } else { completion(.failure("Редактор не подтвердил положение курсора")) }
                return
            }
            if withoutSelection && text(in: element, range: targetRange) != original {
                completion(.failure("Текст изменился — повторите")); return
            }
            guard clipboard.paste(conversion.text, deletingBeforeCaret: deletionCount) else { completion(.failure("Не удалось вставить преобразованный текст")); return }
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
                    if selectedRange.length > 0, sameFocus() {
                        var restoredSelection = CFRange(location: targetRange.location, length: (conversion.text as NSString).length)
                        if let value = AXValueCreate(.cfRange, &restoredSelection) {
                            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
                        }
                    } else if withoutSelection, sameFocus(), let caret = selection(element),
                       caret.length == 0, caret.location == targetRange.location + (conversion.text as NSString).length {
                        var restoredCaret = CFRange(location: min(selectedRange.location, caret.location), length: 0)
                        if let value = AXValueCreate(.cfRange, &restoredCaret) {
                            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
                        }
                    }
                    // Give the receiving app time to finish handling Paste before
                    // restoring the clipboard, even if AX updates immediately.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if let current = selection(element) {
                            diagnosticDetails += "; после \(current.location):\(current.length)"
                        }
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
    /// Figma caret words use keyboard selection confirmed by Copy before Paste.
    private static func copySelection(in app: NSRunningApplication, isInputUnchanged: @escaping () -> Bool, completion: @escaping (Outcome) -> Void) {
        diagnosticDetails = "Copy: \(app.localizedName ?? "")"
        guard let clipboard = PasteboardTransaction() else {
            completion(.failure("Не удалось сохранить текущий буфер обмена")); return
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        let originalFocus = focusedElement(in: app)
        var expectedSelectedText: String?
        var wordPlan: WordCursorPlan?
        var wordIsSelected = false
        if let previous = verifiedCanvasSelection,
           previous.pid == app.processIdentifier, previous.isInputUnchanged() {
            expectedSelectedText = previous.text
            wordPlan = previous.word
        }
        verifiedCanvasSelection = nil
        if app.bundleIdentifier == "com.figma.Desktop", var candidate = originalFocus {
            for _ in 0..<6 {
                if expectedSelectedText != nil { break }
                if let range = selection(candidate), range.length == 0,
                   let value = attribute(candidate, kAXValueAttribute) as? String,
                   let plan = WordCursorPlan(value: value, caret: range.location) {
                    wordPlan = plan
                    expectedSelectedText = plan.text
                    break
                }
                if let range = selection(candidate), range.length > 0,
                   let selected = attribute(candidate, kAXSelectedTextAttribute) as? String, !selected.isEmpty {
                    expectedSelectedText = selected
                    break
                }
                guard let parent = attribute(candidate, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                candidate = parent as! AXUIElement
            }
            guard expectedSelectedText != nil else {
                completion(.failure("В Figma поставьте курсор у слова или выделите текст")); return
            }
        }
        func stillValid() -> Bool {
            guard isInputUnchanged() else { diagnosticDetails += "; ввод изменился"; return false }
            guard targetApplication()?.processIdentifier == app.processIdentifier else { diagnosticDetails += "; приложение изменилось"; return false }
            // Canvas accessibility focus can move between the web area and
            // transient document during Copy/Paste. Genuine input is checked
            // above, so do not require identity of that transient AX object.
            if app.bundleIdentifier == "com.figma.Desktop" { return true }
            if let originalFocus {
                guard let current = focusedElement(in: app) else { return false }
                return CFEqual(originalFocus, current)
            }
            return true
        }
        func finish(_ outcome: Outcome) {
            if let plan = wordPlan, wordIsSelected, stillValid() {
                let keys: [(CGKeyCode, CGEventFlags)] = [(124, [])] + Array(repeating: (123, []), count: plan.stepsToEnd)
                if let events = KeyboardEvents.sequence(keys) { KeyboardEvents.post(events) }
                // Let the editor apply the restored caret before a queued gesture.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { completion(outcome) }
            } else { completion(outcome) }
        }
        if let plan = wordPlan {
            let keys: [(CGKeyCode, CGEventFlags)] = Array(repeating: (124, []), count: plan.stepsToEnd)
                + Array(repeating: (123, .maskShift), count: plan.selectionSteps)
            guard stillValid(), let events = KeyboardEvents.sequence(keys) else {
                completion(.failure("Не удалось выбрать слово у курсора")); return
            }
            KeyboardEvents.post(events)
            wordIsSelected = true
            diagnosticDetails += "; слово у курсора"
        }
        guard stillValid(), clipboard.write("SSwitcher-copy-\(UUID().uuidString)"), KeyboardEvents.command(8) else {
            clipboard.restore()
            finish(.failure("Не удалось прочитать выделение")); return
        }
        func awaitCopy(_ remaining: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard stillValid() else {
                    clipboard.restore()
                    finish(.failure("Ввод или активное поле изменились — повторите")); return
                }
                if !clipboard.hasCopyResult && remaining > 0 { awaitCopy(remaining - 1); return }
                guard let selected = clipboard.acceptCopyResult(expectedSelectedText: expectedSelectedText), !selected.isEmpty else {
                    clipboard.restore()
                    finish(.failure("Редактор скрывает курсор. Выделите символы текста и повторите")); return
                }
                guard wordPlan == nil || selected == expectedSelectedText else {
                    clipboard.restore()
                    finish(.failure("Редактор не подтвердил слово у курсора — текст не изменён")); return
                }
                guard let conversion = InputSources.prepare(selected) else {
                    clipboard.restore()
                    finish(.failure("Добавьте английскую и русскую раскладки")); return
                }
                guard conversion.text != selected else {
                    clipboard.restore()
                    finish(.failure("В выделении нет символов для преобразования")); return
                }
                guard wordPlan == nil || wordPlan?.replacingText(with: conversion.text) != nil else {
                    clipboard.restore()
                    finish(.failure("Для этого слова выделите текст вручную")); return
                }
                guard stillValid(), clipboard.write(conversion.text), KeyboardEvents.command(9) else {
                    clipboard.restore()
                    finish(.failure("Вставка отменена: поле или буфер обмена изменились")); return
                }
                wordIsSelected = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if stillValid() {
                        TISSelectInputSource(conversion.target)
                        // Canvas editors such as Figma do not expose an AX range.
                        // Paste collapses the user's selection; restore it from
                        // the caret so a second double Shift converts it back.
                        let keys = Array(repeating: (CGKeyCode(123), CGEventFlags.maskShift), count: conversion.text.count)
                        if let events = KeyboardEvents.sequence(keys) {
                            KeyboardEvents.post(events)
                            wordIsSelected = wordPlan != nil
                        }
                    }
                    // Confirm the real editor selection, not its AX mirror.
                    // If it is missing, the next Copy will fail safely instead
                    // of reusing a stale AX range and inserting another word.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        guard stillValid(), clipboard.write("SSwitcher-verify-\(UUID().uuidString)"), KeyboardEvents.command(8) else {
                            clipboard.restore(); finish(.unverified); return
                        }
                        func verifyCopy(_ remaining: Int) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                guard stillValid() else { clipboard.restore(); finish(.unverified); return }
                                if !clipboard.hasCopyResult && remaining > 0 { verifyCopy(remaining - 1); return }
                                let actual = clipboard.acceptCopyResult(expectedSelectedText: conversion.text)
                                clipboard.restore()
                                diagnosticDetails += actual == conversion.text ? "; выделение подтверждено Copy" : "; выделение не подтверждено"
                                if actual == conversion.text, app.bundleIdentifier == "com.figma.Desktop" {
                                    verifiedCanvasSelection = (app.processIdentifier, conversion.text, wordPlan?.replacingText(with: conversion.text), isInputUnchanged)
                                }
                                finish(actual == conversion.text ? .converted : .unverified)
                            }
                        }
                        verifyCopy(9)
                    }
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
