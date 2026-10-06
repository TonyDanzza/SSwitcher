import AppKit
import Carbon
import SwitcherCore

/// Main-thread state owner. Each attempt keeps its cancellation and callback
/// identity; remote AX messages run only through the serial client.
final class ConversionCoordinator {
    enum Outcome { case ignored, cancelled, converted, unverified, failure(String) }
    private let ax = AXClient(policy: .remoteApplication)
    private let localAX = AXClient(policy: .localApplication)
    let overlay = ReplacementOverlay()
    let performance = PerformanceRecorder()
    private var attempt: ConversionAttempt?
    private var unconfirmedInput: (() -> Bool)?
    private(set) var diagnosticDetails = ""
    var isConverting: Bool { attempt != nil }

    private func client(for pid: pid_t) -> AXClient {
        pid == ProcessInfo.processInfo.processIdentifier ? localAX : ax
    }
    func prepareAccessibility(for app: NSRunningApplication) { client(for: app.processIdentifier).prepareAccessibility(for: EditorApplication(app)) }

    func userInputChanged() {
        dispatchPrecondition(condition: .onQueue(.main))
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
              attempt.targetPID.map({ $0 == attempt.frontmostPID }) != false,
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
        guard let snapshot = context.snapshot, !snapshot.isSecure else {
            finish(attempt, outcome: .failure("Редактор не предоставил доступное поле ввода")); return
        }
        guard context.valueEditable, context.policy.permitsEditing(snapshot) else {
            finish(attempt, outcome: .failure("Это поле не подтверждает возможность редактирования")); return
        }
        guard let document = snapshot.value, let range = snapshot.range,
              AccessibilitySelectionPlan.checkedRange(range, in: document) != nil,
              AccessibilitySelectionPlan.hasSingleRange(range, selectedRanges: snapshot.selectedRanges) else {
            finish(attempt, outcome: .failure("Редактор не предоставил согласованный текст и диапазон")); return
        }
        attempt.originalDocument = document
        attempt.originalRange = range
        attempt.selected = range.length > 0
        attempt.trace.setMode(application: context.application, selected: attempt.selected)
        let selection: AccessibilitySelectionPlan
        if attempt.selected {
            guard let plan = snapshot.selectionPlan else {
                finish(attempt, outcome: .failure("Редактор не подтвердил выделенный текст — выделите его заново")); return
            }
            selection = plan
            attempt.selectionPlan = plan
        } else {
            guard AccessibilitySelectionPlan.confirmsCaret(document: document, range: range, selectedText: snapshot.selectedText,
                                                           selectedRanges: snapshot.selectedRanges, expectedDocument: document, expectedCaret: range) else {
                finish(attempt, outcome: .failure("Редактор не подтвердил положение курсора")); return
            }
            guard let word = WordCursorPlan(value: document, caret: range.location) else { finish(attempt, outcome: .ignored); return }
            let wordRange = NSRange(location: range.location - word.text.utf16.count, length: word.text.utf16.count)
            guard let plan = AccessibilitySelectionPlan(document: document, range: wordRange, selectedText: word.text) else {
                finish(attempt, outcome: .cancelled); return
            }
            selection = plan
            attempt.deletingCharacters = word.selectionSteps
        }
        guard let conversion = InputSources.prepare(selection.text) else {
            finish(attempt, outcome: .failure("Добавьте английскую и русскую раскладки")); return
        }
        guard !AccessibilitySelectionPlan.exactlyEqual(conversion.text, selection.text) else { finish(attempt, outcome: .ignored); return }
        if !attempt.selected, selection.text.count != conversion.text.count {
            finish(attempt, outcome: .failure("Для этого слова выделите текст вручную")); return
        }
        guard let replacement = selection.replacing(with: conversion.text) else {
            finish(attempt, outcome: .failure("Для этого фрагмента нельзя безопасно восстановить выделение")); return
        }
        attempt.converted = conversion
        attempt.replacement = replacement
        attempt.canvasSelectionPlan = CanvasSelectionPlan(selection: selection, replacementText: conversion.text)
        diagnosticDetails = "\(attempt.selected ? "Выделение" : "Без выделения"): \(context.application.name)"
        prepareOverlay(attempt, range: selection.range, text: selection.text)
    }

    /// A second Shift gesture is drained, not queued as another replacement.
    /// It may release before selection restoration; other input/focus changes
    /// invalidate the attempt immediately. Polling never extends this budget.
    private func awaitSelectionModifiers(_ attempt: ConversionAttempt,
                                         readiness: ModifierReleaseReadiness? = nil, _ operation: @escaping () -> Void) {
        guard valid(attempt) else { finish(attempt, outcome: .unverified); return }
        let clear = attempt.modifiersClear()
        if readiness == nil, clear { operation(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let wait = readiness ?? ModifierReleaseReadiness(start: now, timeout: ConversionTiming.modifierReleaseDeadline,
                                                        pollInterval: ConversionTiming.pollInterval)
        switch wait.decision(at: now, inputUnchanged: valid(attempt), modifiersClear: clear) {
        case .ready: operation()
        case .wait(let delay):
            schedule(attempt, delay: delay) { self.awaitSelectionModifiers(attempt, readiness: wait, operation) }
        case .cancelled: finish(attempt, outcome: .unverified)
        case .timedOut:
            diagnosticDetails += "; Shift не отпущен для восстановления выделения"
            finish(attempt, outcome: .unverified)
        }
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
        read(attempt, operation: { client -> TextReplacementBackend? in
            guard let document = attempt.originalDocument, let range = attempt.originalRange,
                  let snapshot = client.validate(context, document: document, range: range, includeContext: true),
                  client.isEditable(context, snapshot: snapshot),
                  context.policy.isCanvasTextEditor(snapshot) == context.usesCanvasSelection else { return nil }
            let matches: Bool
            if let selection = attempt.selectionPlan {
                matches = selection.matches(document: snapshot.value, range: snapshot.range, selectedText: snapshot.selectedText,
                                            selectedRanges: snapshot.selectedRanges)
            } else {
                matches = AccessibilitySelectionPlan.confirmsCaret(document: snapshot.value, range: snapshot.range, selectedText: snapshot.selectedText,
                                                                    selectedRanges: snapshot.selectedRanges, expectedDocument: document, expectedCaret: range)
            }
            guard matches else { return nil }
            return client.replacementBackend(context, snapshot: snapshot, selected: attempt.selected)
        }) { backend in
            guard let backend, self.valid(attempt, mutation: true), let conversion = attempt.converted else {
                self.finish(attempt, outcome: .cancelled); return
            }
            if backend == .accessibilitySelectedText {
                guard let selection = attempt.selectionPlan, TextReplacementBackend.acceptsNativeText(conversion.text) else {
                    self.finish(attempt, outcome: .failure("Этот текст нельзя безопасно преобразовать в редакторе")); return
                }
                guard self.reserveMutation(attempt) else { self.finish(attempt, outcome: .cancelled); return }
                self.diagnosticDetails += "; прямая замена Accessibility"
                self.read(attempt, operation: {
                    $0.replaceSelectedText(context, selection: selection, replacement: conversion.text, cancellation: attempt.cancellation)
                }) { issued in
                    // Failure or false success must never fall through to
                    // Unicode input: an in-flight setter may already edit.
                    self.mutationDelivered(attempt, delivered: issued == true)
                }
            } else { self.postUnicodeReplacement(attempt, context: context, text: conversion.text) }
        }
    }

    private func reserveMutation(_ attempt: ConversionAttempt) -> Bool {
        guard valid(attempt, mutation: true), attempt.lifecycle.commitMutation() else { return false }
        attempt.image?.show()
        attempt.trace.begin(.mutation)
        return true
    }

    private func postUnicodeReplacement(_ attempt: ConversionAttempt, context: AXEditorContext, text: String) {
        // Construct every payload before reserving the one mutation. Neither
        // transport reads a shared clipboard or replaces the complete AXValue.
        let policy = context.policy.textControlPolicy(for: context.application, snapshot: context.snapshot)
        guard let input = UnicodeTextInput(text: text, controlPolicy: policy) else {
            finish(attempt, outcome: .failure("В этом приложении нельзя безопасно преобразовать такой текст")); return
        }
        guard CGPreflightPostEventAccess(), let batches = input.makeEventBatches(deletingCharacters: attempt.deletingCharacters),
              reserveMutation(attempt) else { finish(attempt, outcome: .cancelled); return }
        KeyboardEvents.postTextReplacement(batches, valid: { self.valid(attempt) }, modifiersClear: attempt.observedModifiersClear) { delivered in
            self.mutationDelivered(attempt, delivered: delivered)
        }
    }

    private func mutationDelivered(_ attempt: ConversionAttempt, delivered: Bool) {
        guard self.attempt === attempt else { return }
        attempt.trace.end(.mutation)
        guard delivered, valid(attempt) else { finish(attempt, outcome: .unverified); return }
        attempt.trace.begin(.confirmation)
        beginAcknowledgement(attempt)
        awaitAcknowledgement(attempt, selection: false)
    }

    private func beginAcknowledgement(_ attempt: ConversionAttempt) {
        attempt.readiness = ReadinessDeadline(start: ProcessInfo.processInfo.systemUptime, timeout: ConversionTiming.replacementDeadline,
                                              pollInterval: ConversionTiming.pollInterval)
    }

    /// Event receipt only paces delivery. A fixed AX polling budget must prove
    /// both the complete document and the exact resulting caret/selection.
    private func awaitAcknowledgement(_ attempt: ConversionAttempt, selection: Bool) {
        guard valid(attempt), let context = attempt.context, let replacement = attempt.replacement,
              var deadline = attempt.readiness else { finish(attempt, outcome: .unverified); return }
        let now = ProcessInfo.processInfo.systemUptime
        if deadline.expired(at: now) { finish(attempt, outcome: .unverified); return }
        guard deadline.shouldRead(at: now) else {
            schedule(attempt, delay: deadline.delay(at: now)) { self.awaitAcknowledgement(attempt, selection: selection) }; return
        }
        attempt.readiness = deadline
        read(attempt, operation: { $0.acknowledgement(context) }) { result in
            guard !deadline.expired(at: ProcessInfo.processInfo.systemUptime) else {
                self.finish(attempt, outcome: .unverified); return
            }
            let snapshot: AXEditorSnapshot
            switch result {
            case .snapshot(let value): snapshot = value
            case .busy:
                self.schedule(attempt, delay: ConversionTiming.pollInterval) { self.awaitAcknowledgement(attempt, selection: selection) }
                return
            case .invalid, nil: self.finish(attempt, outcome: .unverified); return
            }
            let acknowledged: Bool
            if selection {
                acknowledged = replacement.confirmsSelection(document: snapshot.value, range: snapshot.range,
                                                              selectedText: snapshot.selectedText, selectedRanges: snapshot.selectedRanges)
            } else {
                acknowledged = AccessibilitySelectionPlan.confirmsCaret(document: snapshot.value, range: snapshot.range,
                                                                         selectedText: snapshot.selectedText, selectedRanges: snapshot.selectedRanges,
                                                                         expectedDocument: replacement.document, expectedCaret: replacement.caret)
            }
            if acknowledged {
                if selection || !attempt.selected { self.confirmed(attempt) }
                else { self.restoreSelection(attempt) }
            } else {
                self.schedule(attempt, delay: ConversionTiming.pollInterval) { self.awaitAcknowledgement(attempt, selection: selection) }
            }
        }
    }

    private func restoreSelection(_ attempt: ConversionAttempt) {
        awaitSelectionModifiers(attempt) { self.restoreSelectionWithModifiersReleased(attempt) }
    }

    private func restoreSelectionWithModifiersReleased(_ attempt: ConversionAttempt) {
        guard valid(attempt, mutation: true), let context = attempt.context, let replacement = attempt.replacement else {
            finish(attempt, outcome: .unverified); return
        }
        if context.selectionSettable, context.policy.canSetSelectionThroughAX(context.snapshot) {
            // One range setter preserves native long-selection rendering. A
            // success reply still requires fresh AX proof and is never retried.
            read(attempt, operation: {
                $0.restoreSelection(context, document: replacement.document, caret: replacement.caret,
                                    range: replacement.range, cancellation: attempt.cancellation)
            }) { restored in
                guard restored == true else { self.finish(attempt, outcome: .unverified); return }
                self.beginAcknowledgement(attempt)
                self.awaitAcknowledgement(attempt, selection: true)
            }
        } else {
            // A physical Shift wait may outlive our first caret proof. Read it
            // again before sending one keyboard restoration, never a retry.
            read(attempt, operation: { client -> Bool? in
                guard let snapshot = client.validate(context, document: replacement.document, range: replacement.caret, includeContext: true),
                      client.isEditable(context, snapshot: snapshot),
                      context.policy.isCanvasTextEditor(snapshot) == context.usesCanvasSelection else { return false }
                return AccessibilitySelectionPlan.confirmsCaret(document: snapshot.value, range: snapshot.range, selectedText: snapshot.selectedText,
                                                                  selectedRanges: snapshot.selectedRanges, expectedDocument: replacement.document,
                                                                  expectedCaret: replacement.caret)
            }) { ready in
                guard ready == true, self.valid(attempt, mutation: true) else { self.finish(attempt, outcome: .unverified); return }
                let plan = context.usesCanvasSelection ? attempt.canvasSelectionPlan : .characters(replacement.text.count)
                self.diagnosticDetails += plan == .entireDocument ? "; восстановление всего текста" : "; восстановление части текста"
                KeyboardEvents.restoreCanvasSelection(plan: plan, valid: { self.valid(attempt) }, modifiersClear: attempt.observedModifiersClear) { restored in
                    guard self.attempt === attempt else { return }
                    guard restored else {
                        self.diagnosticDetails += "; доставка выделения не подтверждена"
                        self.finish(attempt, outcome: .unverified); return
                    }
                    self.beginAcknowledgement(attempt)
                    self.awaitAcknowledgement(attempt, selection: true)
                }
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
        let confirmed: Bool
        if case .converted = outcome { confirmed = true } else { confirmed = false; attempt.image?.close(); overlay.cancel() }
        if case .unverified = outcome { unconfirmedInput = attempt.unchanged; diagnosticDetails += "; результат не подтверждён" }
        if case .cancelled = outcome { diagnosticDetails += "; отменено до ввода" }
        attempt.trace.finish(confirmed: confirmed)
        self.attempt = nil
        attempt.completion(outcome)
    }
}

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
    var converted: InputSources.Conversion?
    var originalDocument: String?
    var originalRange: NSRange?
    var selectionPlan: AccessibilitySelectionPlan?
    var replacement: AccessibilityReplacementPlan?
    var deletingCharacters = 0
    var selected = false
    var canvasSelectionPlan = CanvasSelectionPlan.characters(0)
    var image: ImageOverlay?
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
