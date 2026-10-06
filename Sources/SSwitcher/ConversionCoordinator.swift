import AppKit
import Carbon
import SwitcherCore

/// Main-thread state owner. Each attempt keeps its own clipboard, cancellation
/// and callback identity; remote AX messages run only through the serial client.
final class ConversionCoordinator {
    enum Outcome { case ignored, cancelled, converted, unverified, failure(String) }
    private let ax = AXClient(policy: .remoteApplication)
    private let localAX = AXClient(policy: .localApplication)
    let overlay = ReplacementOverlay()
    let performance = PerformanceRecorder()
    private var attempt: ConversionAttempt?
    private var unconfirmedInput: (() -> Bool)?
    private struct VerifiedCanvasSelection {
        let context: AXEditorContext
        let text: String
        let entireDocument: Bool
        let unchanged: () -> Bool
        func matches(_ current: AXEditorContext) -> Bool {
            guard context.application.session == current.application.session, unchanged(),
                  let original = context.element ?? context.focused,
                  let candidate = current.element ?? current.focused else { return false }
            return CFEqual(original, candidate)
        }
    }
    private var verifiedCanvasSelection: VerifiedCanvasSelection?
    private(set) var diagnosticDetails = ""
    var isConverting: Bool { attempt != nil }

    private func client(for pid: pid_t) -> AXClient {
        pid == ProcessInfo.processInfo.processIdentifier ? localAX : ax
    }
    func prepareAccessibility(for app: NSRunningApplication) { client(for: app.processIdentifier).prepareAccessibility(for: EditorApplication(app)) }

    func userInputChanged() {
        dispatchPrecondition(condition: .onQueue(.main))
        verifiedCanvasSelection = nil
        unconfirmedInput = nil
        ax.invalidateGeometry()
        localAX.invalidateGeometry()
        cancel()
    }

    /// Immediate invalidation is local/short enough for the event tap. Cleanup
    /// happens after its callback returns, with cancellation already visible.
    func cancel() {
        guard let attempt, attempt.lifecycle.cancel() else { return }
        attempt.cancellation.cancel()
        attempt.poll?.cancel(); attempt.poll = nil
        KeyboardEvents.cancelDelivery()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.attempt === attempt else { return }
            self.overlay.cancel()
            self.finish(attempt, outcome: attempt.lifecycle.hasMutated ? .unverified : .cancelled)
        }
    }

    /// Termination cannot rely on a queued cleanup block getting another run
    /// loop turn. This path is called only outside the event-tap callback.
    func shutdown() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let attempt {
            _ = attempt.lifecycle.cancel()
            attempt.cancellation.cancel()
            finish(attempt, outcome: attempt.lifecycle.hasMutated ? .unverified : .cancelled)
        }
        overlay.cancel()
        performance.cancelGesture()
    }

    func convertAtCursor(releaseTime: Double, isInputUnchanged: @escaping () -> Bool,
                         isActivityUnchanged: @escaping () -> Bool, modifiersClear: @escaping () -> Bool,
                         observedModifiersClear: @escaping () -> Bool,
                         completion: @escaping (Outcome) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard attempt == nil else { completion(.ignored); return }
        if unconfirmedInput?() == true {
            completion(.failure("Предыдущая замена не подтверждена. Проверьте текст и поставьте курсор заново")); return
        }
        unconfirmedInput = nil
        guard AXIsProcessTrusted() else {
            ax.invalidate(); localAX.invalidate(); completion(.failure("Разрешите «Универсальный доступ» в меню SSwitcher")); return
        }
        guard !IsSecureEventInputEnabled() else { completion(.failure("Преобразование недоступно при защищённом вводе")); return }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { completion(.failure("Нет активного приложения")); return }
        let trace = performance.startAttempt(release: releaseTime)
        let attempt = ConversionAttempt(frontmostPID: frontmost.processIdentifier, trace: trace,
                                        unchanged: isInputUnchanged, activityUnchanged: isActivityUnchanged,
                                        modifiersClear: modifiersClear, observedModifiersClear: observedModifiersClear,
                                        completion: completion)
        self.attempt = attempt
        diagnosticDetails = "Проверка редактора"
        read(attempt, operation: { $0.target(fallbackPID: frontmost.processIdentifier) }) { [weak self] target in
            guard let self else { return }
            guard let target, let app = NSRunningApplication(processIdentifier: target.pid) else {
                self.finish(attempt, outcome: .failure("Нет активного поля ввода")); return
            }
            let application = EditorApplication(app)
            attempt.targetPID = application.pid
            self.read(attempt, operation: { $0.context(application: application, focus: target.focused, cancellation: attempt.cancellation) }) { context in
                guard let context else { self.finish(attempt, outcome: .cancelled); return }
                attempt.context = context
                self.begin(attempt, context: context)
            }
        }
    }

    private func valid(_ attempt: ConversionAttempt, mutation: Bool = false) -> Bool {
        guard self.attempt === attempt, attempt.lifecycle.canContinue, !attempt.cancellation.isCancelled,
              attempt.unchanged(), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == attempt.frontmostPID else { return false }
        return !mutation || attempt.modifiersClear()
    }

    private func read<T>(_ attempt: ConversionAttempt, operation: @escaping (AXClient) -> T?, completion: @escaping (T?) -> Void) {
        let client = attempt.targetPID.map { self.client(for: $0) } ?? ax
        client.perform(cancellation: attempt.cancellation, operation: operation) { [weak self] value, duration in
            guard let self, self.attempt === attempt else { return }
            attempt.trace.addAX(duration)
            guard self.valid(attempt) else {
                self.finish(attempt, outcome: attempt.lifecycle.hasMutated ? .unverified : .cancelled); return
            }
            completion(value)
        }
    }

    private func begin(_ attempt: ConversionAttempt, context: AXEditorContext) {
        guard valid(attempt, mutation: true) else { finish(attempt, outcome: .cancelled); return }
        if context.snapshot?.isSecure == true { finish(attempt, outcome: .failure("В защищённых полях преобразование отключено")); return }
        let previous = verifiedCanvasSelection.flatMap { $0.matches(context) ? $0 : nil }
        let selection = context.snapshot?.range
        if selection?.length ?? 0 > 0 || (context.policy.usesCanvasSelection && previous != nil) || selection == nil {
            attempt.trace.setMode(application: context.application, selected: true)
            diagnosticDetails = "Выделение: \(context.application.name)"
            let expected = previous?.text ?? context.snapshot?.selectedText
            attempt.previousEntireDocument = previous?.entireDocument == true
            verifiedCanvasSelection = nil
            if context.policy.requiresMatchingInitialCopy, expected?.isEmpty != false {
                finish(attempt, outcome: .failure("В Figma выделите символы внутри редактируемого текста")); return
            }
            copySelection(attempt, expected: expected, verification: false)
            return
        }
        verifiedCanvasSelection = nil
        attempt.trace.setMode(application: context.application, selected: false)
        guard let selection, let document = context.snapshot?.value else { finish(attempt, outcome: .failure("Редактор не предоставляет текст у курсора")); return }
        guard context.valueEditable else { finish(attempt, outcome: .failure("Это поле не подтверждает возможность редактирования")); return }
        guard let plan = WordCursorPlan(value: document, caret: selection.location) else { finish(attempt, outcome: .ignored); return }
        guard let conversion = InputSources.prepare(plan.text) else { finish(attempt, outcome: .failure("Добавьте английскую и русскую раскладки")); return }
        guard conversion.text != plan.text else { finish(attempt, outcome: .ignored); return }
        guard plan.replacingText(with: conversion.text) != nil else { finish(attempt, outcome: .failure("Для этого слова выделите текст вручную")); return }
        attempt.originalDocument = document
        attempt.originalRange = selection
        attempt.converted = conversion
        attempt.deletingCharacters = plan.selectionSteps
        let range = NSRange(location: selection.location - plan.text.utf16.count, length: plan.text.utf16.count)
        attempt.resultRange = NSRange(location: range.location, length: conversion.text.utf16.count)
        attempt.expectedDocument = (document as NSString).replacingCharacters(in: range, with: conversion.text)
        guard let clipboard = PasteboardTransaction() else { finish(attempt, outcome: .failure("Не удалось сохранить буфер обмена")); return }
        attempt.clipboard = clipboard
        diagnosticDetails = "Без выделения: \(context.application.name)"
        prepareOverlay(attempt, range: range, text: plan.text)
    }

    /// Initial/native Copy is posted once. Canvas verification may repeat only
    /// Copy within a fixed budget; final proof is always the exact copied text.
    private func copySelection(_ attempt: ConversionAttempt, expected: String?, verification: Bool) {
        if verification, attempt.context?.policy.usesCanvasSelection == true {
            beginCanvasVerification(attempt)
            return
        }
        if verification, valid(attempt), !attempt.observedModifiersClear() {
            awaitSelectionModifiers(attempt, hardware: false) {
                self.copySelection(attempt, expected: expected, verification: true)
            }
            return
        }
        // Verification follows an already guarded restore. Our queued arrows
        // can temporarily appear as held Shift in HID state; unmarked physical
        // transitions still block this non-destructive Copy and every batch.
        let modifiersClear = verification ? attempt.observedModifiersClear() : attempt.modifiersClear()
        guard let context = attempt.context, valid(attempt), modifiersClear else {
            finish(attempt, outcome: attempt.lifecycle.hasMutated ? .unverified : .cancelled); return
        }
        if attempt.clipboard == nil { attempt.clipboard = PasteboardTransaction() }
        guard let clipboard = attempt.clipboard,
              clipboard.write("SSwitcher-copy-\(UUID().uuidString)"), KeyboardEvents.command(8) else {
            finish(attempt, outcome: attempt.lifecycle.hasMutated ? .unverified : .failure("Не удалось прочитать выделение")); return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + ConversionTiming.copyDeadline
        func inspect() {
            guard self.valid(attempt) else { self.finish(attempt, outcome: attempt.lifecycle.hasMutated ? .unverified : .cancelled); return }
            if clipboard.hasCopyResult {
                guard let selected = clipboard.acceptCopyResult(expectedSelectedText: expected,
                                                                requireMatch: verification || context.policy.requiresMatchingInitialCopy), !selected.isEmpty else {
                    self.finish(attempt, outcome: verification ? .unverified : .failure("Выделите символы текста внутри редактора и повторите")); return
                }
                if verification {
                    self.confirmSelection(attempt, text: selected)
                } else { self.prepareSelection(attempt, selected: selected) }
            } else if ProcessInfo.processInfo.systemUptime >= deadline {
                self.finish(attempt, outcome: verification ? .unverified : .failure("Редактор не подтвердил выделение через Copy"))
            } else { self.schedule(attempt, delay: 0.015, inspect) }
        }
        schedule(attempt, delay: 0.015, inspect)
    }

    private func beginCanvasVerification(_ attempt: ConversionAttempt) {
        guard let expected = attempt.converted?.text else { finish(attempt, outcome: .unverified); return }
        awaitSelectionModifiers(attempt, hardware: false) {
            attempt.canvasVerification = CanvasSelectionVerification(expected: expected, previouslyCopied: attempt.originalSelectedText,
                                                                      start: ProcessInfo.processInfo.systemUptime,
                                                                      timeout: ConversionTiming.copyDeadline)
            self.postCanvasVerificationCopy(attempt)
        }
    }

    private func postCanvasVerificationCopy(_ attempt: ConversionAttempt) {
        awaitSelectionModifiers(attempt, hardware: false) {
            guard var verification = attempt.canvasVerification, let clipboard = attempt.clipboard,
                  verification.beginCopy(at: ProcessInfo.processInfo.systemUptime), clipboard.retainsOwnership,
                  let events = KeyboardEvents.sequence([(8, .maskCommand)]),
                  clipboard.write("SSwitcher-copy-\(UUID().uuidString)"), self.valid(attempt),
                  attempt.observedModifiersClear() else {
                self.diagnosticDetails += "; проверка выделения остановлена"
                self.finish(attempt, outcome: .unverified); return
            }
            attempt.canvasVerification = verification
            KeyboardEvents.postAndAwaitDelivery(events) { delivered in
                guard delivered, self.valid(attempt) else {
                    self.diagnosticDetails += "; доставка Copy не подтверждена"
                    self.finish(attempt, outcome: .unverified); return
                }
                self.inspectCanvasVerification(attempt)
            }
        }
    }

    private func inspectCanvasVerification(_ attempt: ConversionAttempt) {
        guard valid(attempt), let verification = attempt.canvasVerification, let clipboard = attempt.clipboard else {
            finish(attempt, outcome: .unverified); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now < verification.expiresAt else {
            diagnosticDetails += "; истёк срок подтверждения выделения"
            finish(attempt, outcome: .unverified); return
        }
        switch clipboard.acceptVerificationCopy(verification) {
        case .waiting:
            schedule(attempt, delay: min(ConversionTiming.pollInterval, verification.expiresAt - now)) {
                self.inspectCanvasVerification(attempt)
            }
        case .rejected:
            diagnosticDetails += "; Copy не совпал с заменённым выделением"
            finish(attempt, outcome: .unverified)
        case .copied(let text):
            switch verification.decision(copied: text, at: now) {
            case .confirmed: confirmSelection(attempt, text: text)
            case .retry:
                diagnosticDetails += "; повторная проверка Copy"
                schedule(attempt, delay: ConversionTiming.pollInterval) { self.postCanvasVerificationCopy(attempt) }
            case .unverified:
                diagnosticDetails += "; выделение осталось неполным"
                finish(attempt, outcome: .unverified)
            }
        }
    }

    /// A second Shift gesture is drained, not queued as another replacement.
    /// At these non-destructive boundaries it may release before we continue;
    /// all other input/focus changes still invalidate the attempt immediately.
    private func awaitSelectionModifiers(_ attempt: ConversionAttempt, hardware: Bool,
                                         readiness: ModifierReleaseReadiness? = nil, _ operation: @escaping () -> Void) {
        guard valid(attempt) else { finish(attempt, outcome: .unverified); return }
        let clear = hardware ? attempt.modifiersClear() : attempt.observedModifiersClear()
        if readiness == nil, clear { operation(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let wait = readiness ?? ModifierReleaseReadiness(start: now, timeout: ConversionTiming.modifierReleaseDeadline,
                                                        pollInterval: ConversionTiming.pollInterval)
        switch wait.decision(at: now, inputUnchanged: valid(attempt), modifiersClear: clear) {
        case .ready: operation()
        case .wait(let delay):
            schedule(attempt, delay: delay) {
                self.awaitSelectionModifiers(attempt, hardware: hardware, readiness: wait, operation)
            }
        case .cancelled: finish(attempt, outcome: .unverified)
        case .timedOut:
            diagnosticDetails += "; Shift не отпущен для восстановления выделения"
            finish(attempt, outcome: .unverified)
        }
    }

    private func prepareSelection(_ attempt: ConversionAttempt, selected: String) {
        guard let context = attempt.context, let conversion = InputSources.prepare(selected) else {
            finish(attempt, outcome: .failure("Добавьте английскую и русскую раскладки")); return
        }
        guard conversion.text != selected else { finish(attempt, outcome: .ignored); return }
        attempt.selected = true
        attempt.converted = conversion
        attempt.originalSelectedText = selected
        attempt.canvasSelectionPlan = attempt.previousEntireDocument ? .entireDocument :
            CanvasSelectionPlan(copiedText: selected, replacementText: conversion.text,
                                document: context.snapshot?.value, range: context.snapshot?.range)
        if let range = context.snapshot?.range, range.length > 0,
           let document = context.snapshot?.value, range.location <= document.utf16.count,
           range.length <= document.utf16.count - range.location,
           (document as NSString).substring(with: range) == selected {
            attempt.originalDocument = document
            attempt.originalRange = range
            attempt.expectedDocument = (document as NSString).replacingCharacters(in: range, with: conversion.text)
            attempt.resultRange = NSRange(location: range.location, length: conversion.text.utf16.count)
        } else if context.snapshot?.value != nil, context.snapshot?.range?.length ?? 0 > 0,
                  context.selectionSettable && context.policy.canSetSelectionThroughAX {
            // Never guess a native range when Copy and AX disagree.
            finish(attempt, outcome: .failure("Редактор изменил выделение — повторите")); return
        }
        prepareOverlay(attempt, range: attempt.originalRange, text: selected)
    }

    private func prepareOverlay(_ attempt: ConversionAttempt, range: NSRange?, text: String) {
        guard let context = attempt.context else { finish(attempt, outcome: .cancelled); return }
        if text.contains("\n") || text.contains("\r") { overlay.skipMultiline(); validateBeforeMutation(attempt); return }
        guard overlay.canCapture, let range else { validateBeforeMutation(attempt); return }
        read(attempt, operation: { $0.bounds(context, range: range) }) { bounds in
            attempt.trace.begin(.capture)
            self.overlay.prepare(bounds: bounds, valid: { self.valid(attempt) && attempt.activityUnchanged() }) { result in
                attempt.trace.end(.capture)
                guard self.valid(attempt) else { self.finish(attempt, outcome: .cancelled); return }
                switch result {
                case .cancelled: self.finish(attempt, outcome: .cancelled)
                case .skipped: self.validateBeforeMutation(attempt)
                case .ready(let image): attempt.image = image; self.validateBeforeMutation(attempt)
                }
            }
        }
    }

    private func validateBeforeMutation(_ attempt: ConversionAttempt) {
        guard let context = attempt.context else { finish(attempt, outcome: .cancelled); return }
        read(attempt, operation: { client -> Bool? in
            guard client.focusMatches(context) else { return false }
            guard context.element != nil else { return attempt.selected }
            // Copy may collapse Figma's AX mirror while the real characters
            // remain selected. Initial matching Copy is the evidence here;
            // preserve the exact range guard only for word/truthful-native mode.
            let range = attempt.selected && context.policy.usesCanvasSelection ? nil : attempt.originalRange
            return client.validate(context, document: attempt.originalDocument, range: range, includeContext: true) != nil
        }) { result in
            guard result == true, self.valid(attempt, mutation: true), let conversion = attempt.converted,
                  let clipboard = attempt.clipboard else { self.finish(attempt, outcome: .cancelled); return }
            // Build all word-deletion events and acquire clipboard ownership
            // before the single irreversible mutation reservation.
            var keys = Array(repeating: (CGKeyCode(51), CGEventFlags()), count: attempt.deletingCharacters)
            keys.append((9, .maskCommand))
            guard let events = KeyboardEvents.sequence(keys), clipboard.write(conversion.text),
                  self.valid(attempt, mutation: true), attempt.lifecycle.commitMutation() else {
                self.finish(attempt, outcome: .cancelled); return
            }
            attempt.image?.show()
            attempt.trace.begin(.mutation)
            KeyboardEvents.post(events)
            attempt.trace.end(.mutation)
            attempt.trace.begin(.confirmation)
            attempt.pastedAt = ProcessInfo.processInfo.systemUptime
            attempt.readiness = ReadinessDeadline(start: attempt.pastedAt, timeout: ConversionTiming.pasteDeadline,
                                                  pollInterval: ConversionTiming.pollInterval)
            self.awaitPaste(attempt)
        }
    }

    private func awaitPaste(_ attempt: ConversionAttempt) {
        guard valid(attempt), let context = attempt.context, var deadline = attempt.readiness else {
            finish(attempt, outcome: .unverified); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if deadline.expired(at: now) { finish(attempt, outcome: .unverified); return }
        guard deadline.shouldRead(at: now) else { schedule(attempt, delay: deadline.delay(at: now)) { self.awaitPaste(attempt) }; return }
        attempt.readiness = deadline
        read(attempt, operation: { client -> PasteReadiness? in
            guard client.focusMatches(context) else { return PasteReadiness(focusMatches: false, snapshot: nil) }
            let snapshot = context.element.flatMap { client.read($0, application: context.application, includeContext: false) }
            return PasteReadiness(focusMatches: true, snapshot: snapshot)
        }) { readiness in
            guard readiness?.focusMatches == true else { self.finish(attempt, outcome: .unverified); return }
            let acknowledged = attempt.expectedDocument != nil && readiness?.snapshot?.value == attempt.expectedDocument
            if !attempt.selected {
                if acknowledged { self.confirmed(attempt) }
                else { self.schedule(attempt, delay: ConversionTiming.pollInterval) { self.awaitPaste(attempt) } }
                return
            }
            let fallbackReady = ProcessInfo.processInfo.systemUptime - attempt.pastedAt >= ConversionTiming.canvasPasteFallback
            let canRestoreAtomically = context.selectionSettable && context.policy.canSetSelectionThroughAX && attempt.expectedDocument != nil && attempt.resultRange != nil
            if acknowledged || (fallbackReady && !canRestoreAtomically) {
                self.restoreSelection(attempt)
            } else { self.schedule(attempt, delay: ConversionTiming.pollInterval) { self.awaitPaste(attempt) } }
        }
    }

    private func restoreSelection(_ attempt: ConversionAttempt) {
        awaitSelectionModifiers(attempt, hardware: true) { self.restoreSelectionWithModifiersReleased(attempt) }
    }

    private func restoreSelectionWithModifiersReleased(_ attempt: ConversionAttempt) {
        guard valid(attempt, mutation: true), let context = attempt.context, let conversion = attempt.converted else { finish(attempt, outcome: .unverified); return }
        if context.selectionSettable, context.policy.canSetSelectionThroughAX,
           let document = attempt.expectedDocument, let range = attempt.resultRange {
            // A single native range update avoids fragmented long-selection
            // rendering. This path is never used in word mode or Figma canvas.
            read(attempt, operation: { $0.restoreSelection(context, document: document, range: range, cancellation: attempt.cancellation) }) { restored in
                guard restored == true else { self.finish(attempt, outcome: .unverified); return }
                self.copySelection(attempt, expected: conversion.text, verification: true)
            }
        } else {
            // The full hardware guard above is required before the first
            // arrow. Between batches, own queued Shift must not look physical.
            let plan = context.policy.usesCanvasSelection ? attempt.canvasSelectionPlan : .characters(conversion.text.count)
            diagnosticDetails += plan == .entireDocument ? "; восстановление всего текста" : "; восстановление части текста"
            KeyboardEvents.restoreCanvasSelection(plan: plan,
                                                   valid: { self.valid(attempt) }, modifiersClear: attempt.observedModifiersClear) { restored in
                guard restored else {
                    self.diagnosticDetails += "; доставка выделения не подтверждена"
                    self.finish(attempt, outcome: .unverified); return
                }
                self.copySelection(attempt, expected: conversion.text, verification: true)
            }
        }
    }

    private func confirmSelection(_ attempt: ConversionAttempt, text: String) {
        guard let context = attempt.context, text == attempt.converted?.text else { finish(attempt, outcome: .unverified); return }
        if context.policy.usesCanvasSelection {
            diagnosticDetails += "; выделение подтверждено Copy"
            verifiedCanvasSelection = VerifiedCanvasSelection(context: context, text: text,
                                                              entireDocument: attempt.canvasSelectionPlan == .entireDocument,
                                                              unchanged: attempt.unchanged)
            confirmed(attempt)
        } else {
            read(attempt, operation: { client -> Bool? in
                if let document = attempt.expectedDocument, let range = attempt.resultRange {
                    return client.validate(context, document: document, range: range) != nil
                }
                return client.focusMatches(context)
            }) { result in
                guard result == true else { self.finish(attempt, outcome: .unverified); return }
                self.diagnosticDetails += "; выделение подтверждено Copy"
                self.confirmed(attempt)
            }
        }
    }

    private func confirmed(_ attempt: ConversionAttempt) {
        guard valid(attempt), let conversion = attempt.converted else { finish(attempt, outcome: .unverified); return }
        attempt.trace.end(.confirmation)
        attempt.trace.end(.total)
        TISSelectInputSource(conversion.target)
        if let image = attempt.image {
            attempt.trace.begin(.reveal)
            image.reveal { attempt.trace.end(.reveal) }
        }
        finish(attempt, outcome: .converted)
    }

    private func schedule(_ attempt: ConversionAttempt, delay: Double, _ operation: @escaping () -> Void) {
        attempt.poll?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.attempt === attempt, attempt.lifecycle.canContinue else { return }
            operation()
        }
        attempt.poll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    private func finish(_ attempt: ConversionAttempt, outcome: Outcome) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.attempt === attempt, attempt.lifecycle.finish() else { return }
        attempt.cancellation.cancel()
        attempt.poll?.cancel(); attempt.poll = nil
        KeyboardEvents.cancelDelivery()
        attempt.clipboard?.restore(); attempt.clipboard = nil
        let confirmed: Bool
        if case .converted = outcome { confirmed = true } else { confirmed = false; attempt.image?.close(); overlay.cancel() }
        if case .unverified = outcome { unconfirmedInput = attempt.unchanged; diagnosticDetails += "; результат не подтверждён" }
        if case .cancelled = outcome { diagnosticDetails += "; отменено до вставки" }
        attempt.trace.finish(confirmed: confirmed)
        self.attempt = nil
        attempt.completion(outcome)
    }
}

private struct PasteReadiness { let focusMatches: Bool; let snapshot: AXEditorSnapshot? }

private final class ConversionAttempt {
    let cancellation = AttemptCancellation()
    var lifecycle = ConversionLifecycle()
    let frontmostPID: pid_t
    let trace: ConversionTrace
    let unchanged: () -> Bool
    let activityUnchanged: () -> Bool
    let modifiersClear: () -> Bool
    let observedModifiersClear: () -> Bool
    let completion: (ConversionCoordinator.Outcome) -> Void
    var context: AXEditorContext?
    var targetPID: pid_t?
    var clipboard: PasteboardTransaction?
    var converted: InputSources.Conversion?
    var originalDocument: String?
    var originalRange: NSRange?
    var resultRange: NSRange?
    var expectedDocument: String?
    var deletingCharacters = 0
    var selected = false
    var originalSelectedText = ""
    var previousEntireDocument = false
    var canvasSelectionPlan = CanvasSelectionPlan.characters(0)
    var canvasVerification: CanvasSelectionVerification?
    var image: ImageOverlay?
    var pastedAt = 0.0
    var readiness: ReadinessDeadline?
    var poll: DispatchWorkItem?
    init(frontmostPID: pid_t, trace: ConversionTrace, unchanged: @escaping () -> Bool, activityUnchanged: @escaping () -> Bool,
         modifiersClear: @escaping () -> Bool, observedModifiersClear: @escaping () -> Bool,
         completion: @escaping (ConversionCoordinator.Outcome) -> Void) {
        self.frontmostPID = frontmostPID; self.trace = trace; self.unchanged = unchanged
        self.activityUnchanged = activityUnchanged; self.modifiersClear = modifiersClear
        self.observedModifiersClear = observedModifiersClear; self.completion = completion
    }
}
