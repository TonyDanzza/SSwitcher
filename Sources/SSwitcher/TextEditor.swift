import AppKit
import Carbon
import SwitcherCore

enum TextEditor {
    enum Outcome {
        case ignored
        case converted
        case unverified
        case failure(String)
    }

    private(set) static var isConverting = false
    static var diagnosticDetails = ""
    private static var unconfirmedInput: (() -> Bool)?
    private static var verifiedCanvasSelection: (pid: pid_t, text: String, isInputUnchanged: () -> Bool)?

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
        guard !isConverting else { completion(.ignored); return }
        if unconfirmedInput?() == true {
            completion(.failure("Предыдущая замена не подтверждена. Проверьте текст и поставьте курсор заново")); return
        }
        unconfirmedInput = nil
        guard AXIsProcessTrusted() else { completion(.failure("Разрешите «Универсальный доступ» в меню SSwitcher")); return }
        guard !IsSecureEventInputEnabled() else { completion(.failure("Преобразование недоступно при защищённом вводе")); return }
        guard let app = targetApplication() else { completion(.failure("Нет активного приложения")); return }
        isConverting = true
        diagnosticDetails = ""
        prepareAccessibility(for: app)
        // AX is normally ready from the activation observer; do not add a fixed delay.
        DispatchQueue.main.async {
            let finish: (Outcome) -> Void = { outcome in
                if case .unverified = outcome { unconfirmedInput = isInputUnchanged }
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
        // Figma's own selection survives Paste, while its AX mirror may not.
        if app.bundleIdentifier == "com.figma.Desktop",
           let previous = verifiedCanvasSelection,
           previous.pid == app.processIdentifier, previous.isInputUnchanged() {
            copySelection(in: app, isInputUnchanged: isInputUnchanged, completion: completion)
            return nil
        }
        if selectedRange.length > 0 {
            copySelection(in: app, isInputUnchanged: isInputUnchanged, completion: completion)
            return nil
        }
        verifiedCanvasSelection = nil
        guard let originalDocument = attribute(element, kAXValueAttribute) as? String else {
            return "Редактор не предоставляет текст у курсора"
        }
        var editable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &editable) == .success,
              editable.boolValue else { return "Это поле не подтверждает возможность редактирования" }
        guard let plan = WordCursorPlan(value: originalDocument, caret: selectedRange.location) else {
            completion(.ignored)
            return nil
        }
        guard let conversion = InputSources.prepare(plan.text) else {
            return "Добавьте английскую и русскую раскладки"
        }
        guard conversion.text != plan.text else { completion(.ignored); return nil }
        guard plan.replacingText(with: conversion.text) != nil else {
            return "Для этого слова выделите текст вручную"
        }
        guard let clipboard = ClipboardInsertion() else { return "Не удалось сохранить буфер обмена" }
        let started = ProcessInfo.processInfo.systemUptime
        diagnosticDetails = "Без выделения: \(app.localizedName ?? "")"
        func sameFocus() -> Bool {
            guard isInputUnchanged() else { return false }
            // No remote AX focus round trips during Figma verification. Its
            // document is already captured, and real input invalidates this run.
            if app.bundleIdentifier == "com.figma.Desktop" {
                return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            }
            guard targetApplication()?.processIdentifier == app.processIdentifier else { return false }
            guard let current = focusedElement(in: app) else { return false }
            return CFEqual(current, focused)
        }
        guard sameFocus(), let current = selection(element), current.length == 0,
              current.location == selectedRange.location,
              attribute(element, kAXValueAttribute) as? String == originalDocument else {
            return "Курсор или текст изменились — повторите"
        }
        let targetRange = NSRange(location: selectedRange.location - plan.text.utf16.count, length: plan.text.utf16.count)
        let expectedDocument = (originalDocument as NSString).replacingCharacters(in: targetRange, with: conversion.text)
        // No AX range setters, arrows, Shift-selection, or Copy in the word path.
        // Prepare the complete clipboard and event sequence before any deletion.
        let heldModifiers = CGEventSource.flagsState(.combinedSessionState)
        let unsafeModifiers: CGEventFlags = [.maskShift, .maskCommand, .maskControl, .maskAlternate]
        guard heldModifiers.intersection(unsafeModifiers).isEmpty else {
            completion(.ignored); return nil
        }
        guard clipboard.paste(conversion.text, deletingBeforeCaret: plan.selectionSteps) else {
            return "Не удалось отправить замену текста"
        }
        func verify(_ remaining: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                guard sameFocus() else { clipboard.restore(); completion(.unverified); return }
                if attribute(element, kAXValueAttribute) as? String == expectedDocument {
                    clipboard.restore()
                    TISSelectInputSource(conversion.target)
                    let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                    diagnosticDetails += "; подтверждено за \(elapsed) мс"
                    completion(.converted)
                } else if remaining > 0 {
                    verify(remaining - 1)
                } else {
                    clipboard.restore()
                    completion(.unverified)
                }
            }
        }
        verify(24)
        return nil
    }

    /// Canvas editors can expose neither numeric ranges nor text through AX.
    /// Copy only the user's existing selection; never guess a caret position.
    private static func copySelection(in app: NSRunningApplication, isInputUnchanged: @escaping () -> Bool, completion: @escaping (Outcome) -> Void) {
        diagnosticDetails = "Copy: \(app.localizedName ?? "")"
        guard let clipboard = PasteboardTransaction() else {
            completion(.failure("Не удалось сохранить текущий буфер обмена")); return
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        let originalFocus = focusedElement(in: app)
        var expectedSelectedText: String?
        if let previous = verifiedCanvasSelection,
           previous.pid == app.processIdentifier, previous.isInputUnchanged() {
            expectedSelectedText = previous.text
        }
        verifiedCanvasSelection = nil
        if app.bundleIdentifier == "com.figma.Desktop", var candidate = originalFocus {
            for _ in 0..<6 {
                if expectedSelectedText != nil { break }
                if let range = selection(candidate), range.length > 0,
                   let selected = attribute(candidate, kAXSelectedTextAttribute) as? String, !selected.isEmpty {
                    expectedSelectedText = selected
                    break
                }
                guard let parent = attribute(candidate, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                candidate = parent as! AXUIElement
            }
            guard expectedSelectedText != nil else {
                completion(.failure("В Figma выделите символы внутри редактируемого текста")); return
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
                guard let selected = clipboard.acceptCopyResult(expectedSelectedText: expectedSelectedText), !selected.isEmpty else {
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
                    if stillValid() {
                        TISSelectInputSource(conversion.target)
                        // Canvas editors such as Figma do not expose an AX range.
                        // Paste collapses the user's selection; restore it from
                        // the caret so a second double Shift converts it back.
                        let keys = Array(repeating: (CGKeyCode(123), CGEventFlags.maskShift), count: conversion.text.count)
                        if let events = KeyboardEvents.sequence(keys) { KeyboardEvents.post(events) }
                    }
                    // Confirm the real editor selection, not its AX mirror.
                    // If it is missing, the next Copy will fail safely instead
                    // of reusing a stale AX range and inserting another word.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        guard stillValid(), clipboard.write("SSwitcher-verify-\(UUID().uuidString)"), KeyboardEvents.command(8) else {
                            clipboard.restore(); completion(.unverified); return
                        }
                        func verifyCopy(_ remaining: Int) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                guard stillValid() else { clipboard.restore(); completion(.unverified); return }
                                if !clipboard.hasCopyResult && remaining > 0 { verifyCopy(remaining - 1); return }
                                let actual = clipboard.acceptCopyResult(expectedSelectedText: conversion.text)
                                clipboard.restore()
                                diagnosticDetails += actual == conversion.text ? "; выделение подтверждено Copy" : "; выделение не подтверждено"
                                if actual == conversion.text, app.bundleIdentifier == "com.figma.Desktop" {
                                    verifiedCanvasSelection = (app.processIdentifier, conversion.text, isInputUnchanged)
                                }
                                completion(actual == conversion.text ? .converted : .unverified)
                            }
                        }
                        verifyCopy(9)
                    }
                }
            }
        }
        awaitCopy(9)
    }

}
