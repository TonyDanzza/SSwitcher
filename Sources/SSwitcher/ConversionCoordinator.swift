import AppKit
import Carbon
import InputMethodSupport
import SwitcherCore

/// Main-thread state owner. Each attempt keeps its cancellation and callback
/// identity; remote AX messages run only through the serial client.
final class ConversionCoordinator {
    enum Outcome { case ignored, cancelled, converted, unverified, failure(String) }
    enum Refusal: String {
        case targetUnavailable, editorUnavailable, editingGuard
        case documentUnavailable, rangeUnavailable, invalidTextRange, contradictorySelectionRanges
        case attachmentInScope, selectedTextMismatch, caretUnconfirmed
        case rangeTextUnavailable, rangeTextMismatch, layoutsUnavailable, wordWidthChanged, replacementBoundary
        case spotlightCapabilities, nativePayloadUnsupported, unicodePayloadUnsupported
    }
    private enum PrewriteRead {
        case ready(TextReplacementBackend, AXTextScopeRead), scopeRefused(AXTextScopeRead)
    }
    private let ax = AXClient(policy: .remoteApplication)
    private let localAX = AXClient(policy: .localApplication)
    let performance = PerformanceRecorder()
    private var attempt: ConversionAttempt?
    private var unconfirmedInput: (() -> Bool)?
    /// Document-extent caches are filled only by attempts, so
    /// input after an idle period has nothing to invalidate.
    private var attemptCachesFilled = false
    private(set) var diagnosticDetails = ""
    /// Text-free phase and refusal of the last finished attempt.
    private(set) var lastSummary: [String: Any] = [:]
    var isConverting: Bool { attempt != nil }

    private func client(for pid: pid_t) -> AXClient {
        pid == ProcessInfo.processInfo.processIdentifier ? localAX : ax
    }
    func prepareAccessibility(for app: NSRunningApplication) { client(for: app.processIdentifier).prepareAccessibility(for: .describing(app)) }

    func userInputChanged() {
        dispatchPrecondition(condition: .onQueue(.main))
        unconfirmedInput = nil
        if attemptCachesFilled {
            attemptCachesFilled = false
            ax.invalidateDocumentExtents()
            localAX.invalidateDocumentExtents()
        }
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
        performance.cancelGesture()
    }

    func convertAtCursor(releaseTime: Double, isInputUnchanged: @escaping () -> Bool,
                         modifiersClear: @escaping () -> Bool,
                         observedModifiersClear: @escaping () -> Bool,
                         completion: @escaping (Outcome) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        lastSummary = ["phase": "start"]
        guard attempt == nil else { completion(.ignored); return }
        // Refuse a leftover experimental source, so legacy replacement cannot
        // run beside its separate input-method process. Ordinary layouts use AX.
        guard InputMethodIdentity.currentMode == nil else { completion(.ignored); return }
        if unconfirmedInput?() == true {
            lastSummary["refusal"] = "previousUnconfirmed"
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
                                        unchanged: isInputUnchanged,
                                        modifiersClear: modifiersClear, observedModifiersClear: observedModifiersClear,
                                        completion: completion)
        self.attempt = attempt
        attemptCachesFilled = true
        DiagnosticReports.shared.remove("LastEditingRefusalDiagnostic")
        diagnosticDetails = "Проверка редактора"
        read(attempt, operation: { $0.target(fallbackPID: frontmost.processIdentifier) }) { [weak self] target in
            guard let self else { return }
            guard let target, let app = NSRunningApplication(processIdentifier: target.pid) else {
                self.refuse(attempt, .targetUnavailable, "Нет активного поля ввода"); return
            }
            let application = EditorApplication.describing(app)
            attempt.targetPID = application.pid
            attempt.spotlightFocus = target.spotlight
            guard SpotlightSearchScope.permitsTarget(foregroundPID: attempt.frontmostPID, targetPID: application.pid,
                                                      verifiedOverlay: target.spotlight != nil) else {
                self.finish(attempt, outcome: .cancelled); return
            }
            self.read(attempt, operation: {
                $0.context(application: application, focus: target.focused, spotlight: target.spotlight,
                           focusDiscovery: target.focusDiscovery, cancellation: attempt.cancellation)
            }) { context in
                guard let context else { self.finish(attempt, outcome: .cancelled); return }
                attempt.context = context
                self.begin(attempt, context: context)
            }
        }
    }

    private func valid(_ attempt: ConversionAttempt, mutation: Bool = false) -> Bool {
        guard self.attempt === attempt, attempt.lifecycle.canContinue, !attempt.cancellation.isCancelled,
              InputMethodIdentity.currentMode == nil,
              attempt.unchanged(), !IsSecureEventInputEnabled(),
              attempt.targetPID.map({ SpotlightSearchScope.permitsTarget(foregroundPID: attempt.frontmostPID, targetPID: $0,
                                                                         verifiedOverlay: attempt.spotlightFocus != nil) }) != false,
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
        attempt.phase = "inputProof"
        guard valid(attempt, mutation: true) else { finish(attempt, outcome: .cancelled); return }
        guard let snapshot = context.snapshot, !snapshot.isSecure else {
            refuse(attempt, .editorUnavailable, "Редактор не предоставил доступное поле ввода"); return
        }
        guard context.valueEditable, context.policy.permitsEditing(snapshot) else {
            refuse(attempt, .editingGuard, context.editingRefusal(for: snapshot)); return
        }
        attempt.editingGuardPassed = true
        guard let document = snapshot.value else { refuse(attempt, .documentUnavailable, "Редактор не предоставил текст поля"); return }
        guard let range = snapshot.range else { refuse(attempt, .rangeUnavailable, "Редактор не предоставил диапазон текста"); return }
        guard AccessibilitySelectionPlan.checkedRange(range, in: document) != nil else {
            refuse(attempt, .invalidTextRange, "Диапазон редактора не совпадает с границами текста"); return
        }
        guard AccessibilitySelectionPlan.hasSingleRange(range, selectedRanges: snapshot.selectedRanges) else {
            refuse(attempt, .contradictorySelectionRanges, "Редактор предоставил несогласованные диапазоны выделения"); return
        }
        attempt.originalDocument = document
        attempt.originalRange = range
        attempt.selected = range.length > 0
        attempt.trace.setMode(application: context.application, selected: attempt.selected)
        let selection: AccessibilitySelectionPlan
        if attempt.selected {
            guard let plan = snapshot.selectionPlan else {
                if AccessibilitySelectionPlan.hasTextAttachment((document as NSString).substring(with: range)) {
                    refuse(attempt, .attachmentInScope, "Выделение содержит вложение; выделите только текст")
                } else {
                    attempt.mismatch = Self.mismatchDiagnostic(document: document, range: range, selectedText: snapshot.selectedText)
                    refuse(attempt, .selectedTextMismatch, "Редактор не подтвердил выделенный текст — выделите его заново")
                }
                return
            }
            selection = plan
            attempt.selectionPlan = plan
        } else {
            guard AccessibilitySelectionPlan.confirmsCaret(document: document, range: range, selectedText: snapshot.selectedText,
                                                           selectedRanges: snapshot.selectedRanges, expectedDocument: document, expectedCaret: range) else {
                refuse(attempt, .caretUnconfirmed, "Редактор не подтвердил положение курсора"); return
            }
            // A word typed inside brackets keeps the closing bracket after the caret.
            let neutral = InputSources.layoutNeutralCharacters()
            guard let word = WordCursorPlan(value: document, caret: range.location, ignoringTrailing: { neutral.contains($0) }) else {
                finish(attempt, outcome: .ignored); return
            }
            guard !AccessibilitySelectionPlan.hasTextAttachment(word.text) else {
                refuse(attempt, .attachmentInScope, "Рядом с курсором вложение; выделите только текст"); return
            }
            let wordRange = NSRange(location: range.location - word.text.utf16.count, length: word.text.utf16.count)
            guard let plan = AccessibilitySelectionPlan(document: document, range: wordRange, selectedText: word.text) else {
                finish(attempt, outcome: .cancelled); return
            }
            selection = plan
            attempt.deletingCharacters = word.deletingCharacters
        }
        attempt.scopePlan = selection
        if AccessibilitySelectionPlan.hasTextAttachment(document) {
            attempt.phase = "attachmentScope"
            read(attempt, operation: { client in
                guard client.focusMatches(context) else { return AXTextScopeRead.cancelled }
                return client.textScope(context, document: document, range: selection.range, cancellation: attempt.cancellation)
            }) { proof in
                guard let proof else { self.finish(attempt, outcome: .cancelled); return }
                attempt.scopeRead = proof
                guard proof.permitsUse else {
                    self.refuseScope(attempt, proof); return
                }
                self.prepareConversion(attempt, selection: selection, context: context)
            }
        } else { prepareConversion(attempt, selection: selection, context: context) }
    }

    private func prepareConversion(_ attempt: ConversionAttempt, selection: AccessibilitySelectionPlan, context: AXEditorContext) {
        attempt.phase = "conversionPlan"
        guard let conversion = InputSources.prepare(selection.text) else {
            refuse(attempt, .layoutsUnavailable, "Добавьте английскую и русскую раскладки"); return
        }
        guard !AccessibilitySelectionPlan.exactlyEqual(conversion.text, selection.text) else { finish(attempt, outcome: .ignored); return }
        if !attempt.selected, selection.text.count != conversion.text.count {
            refuse(attempt, .wordWidthChanged, "Для этого слова выделите текст вручную"); return
        }
        guard let replacement = selection.replacing(with: conversion.text) else {
            refuse(attempt, .replacementBoundary, "Для этого фрагмента нельзя безопасно определить конец замены"); return
        }
        attempt.converted = conversion
        attempt.replacement = replacement
        diagnosticDetails = "\(attempt.selected ? "Выделение" : "Без выделения"): \(context.application.name)"
        validateBeforeMutation(attempt)
    }

    /// A second Shift gesture is drained, not queued as another replacement.
    /// It may release before Spotlight's caret correction; other input/focus changes
    /// invalidate the attempt immediately. Polling never extends this budget.
    private func awaitCaretModifiers(_ attempt: ConversionAttempt,
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
            schedule(attempt, delay: delay) { self.awaitCaretModifiers(attempt, readiness: wait, operation) }
        case .cancelled: finish(attempt, outcome: .unverified)
        case .timedOut:
            diagnosticDetails += "; Shift не отпущен для возврата курсора"
            finish(attempt, outcome: .unverified)
        }
    }

    private func validateBeforeMutation(_ attempt: ConversionAttempt) {
        attempt.phase = "prewrite"
        guard let context = attempt.context else { finish(attempt, outcome: .cancelled); return }
        // The attempt belongs to the main thread; the worker gets copies.
        let original = (document: attempt.originalDocument, range: attempt.originalRange)
        let selected = attempt.selected, selectionPlan = attempt.selectionPlan, scopePlan = attempt.scopePlan
        let replacementText = attempt.converted?.text, cancellation = attempt.cancellation
        read(attempt, operation: { client -> PrewriteRead? in
            guard let document = original.document, let range = original.range,
                  let snapshot = client.validate(context, document: document, range: range, includeContext: true),
                  client.isEditable(context, snapshot: snapshot),
                  context.policy.isCanvasTextEditor(snapshot) == context.isCanvasTextEditor else { return nil }
            if selected, context.spotlightFocus != nil,
               !SpotlightSearchScope.hasRequiredNativeRangeCapability(verifiedOverlay: true, nativeRangeSettable: client.hasNativeRangeSetter(context)) { return nil }
            let matches: Bool
            if let selection = selectionPlan {
                matches = selection.matches(document: snapshot.value, range: snapshot.range, selectedText: snapshot.selectedText,
                                            selectedRanges: snapshot.selectedRanges)
            } else {
                matches = AccessibilitySelectionPlan.confirmsCaret(document: snapshot.value, range: snapshot.range, selectedText: snapshot.selectedText,
                                                                    selectedRanges: snapshot.selectedRanges, expectedDocument: document, expectedCaret: range)
            }
            guard matches else { return nil }
            guard let scope = scopePlan else { return nil }
            let proof = client.textScope(context, document: scope.document, range: scope.range,
                                         cancellation: cancellation)
            guard proof.permitsUse else { return .scopeRefused(proof) }
            let backend = client.replacementBackend(context, snapshot: snapshot, selected: selected,
                                                    replacementText: replacementText)
            if context.qtFocusedWindow != nil, !client.focusMatches(context) { return nil }
            return .ready(backend, proof)
        }) { prepared in
            guard let prepared, self.valid(attempt, mutation: true), let conversion = attempt.converted else {
                self.finish(attempt, outcome: .cancelled); return
            }
            let backend: TextReplacementBackend
            switch prepared {
            case .scopeRefused(let proof):
                attempt.scopeRead = proof
                self.refuseScope(attempt, proof); return
            case .ready(let selected, let proof): backend = selected; attempt.scopeRead = proof
            }
            if context.spotlightFocus != nil, backend == .unicodeEvents {
                self.refuse(attempt, .spotlightCapabilities, "Spotlight не подтвердил возможность нативной замены"); return
            }
            if backend == .accessibilitySpotlightQuery {
                guard let document = attempt.originalDocument, let caret = attempt.originalRange,
                      let replacement = attempt.replacement, !attempt.selected,
                      SpotlightSearchScope.wordReplacement(document: document, caret: caret, replacement: conversion.text) == replacement else {
                    self.finish(attempt, outcome: .cancelled); return
                }
                guard self.reserveMutation(attempt) else { self.finish(attempt, outcome: .cancelled); return }
                attempt.usesNativeSearchValue = true
                self.diagnosticDetails += "; нативная замена поисковой строки"
                self.read(attempt, operation: {
                    $0.replaceSpotlightWord(context, document: document, caret: caret, replacement: replacement,
                                           cancellation: attempt.cancellation)
                }) { issued in self.mutationDelivered(attempt, delivered: issued == true) }
            } else if backend == .accessibilitySelectedText {
                guard let selection = attempt.selectionPlan,
                      TextReplacementBackend.acceptsNativeText(conversion.text, permitsLineBreaks: context.spotlightFocus == nil) else {
                    self.refuse(attempt, .nativePayloadUnsupported, "Этот текст нельзя безопасно преобразовать в редакторе"); return
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
        attempt.phase = "mutation"
        attempt.trace.begin(.mutation)
        return true
    }

    private func postUnicodeReplacement(_ attempt: ConversionAttempt, context: AXEditorContext, text: String) {
        // Construct every payload before reserving the one mutation. Neither
        // keyboard transport nor ordinary native editors use full AXValue.
        guard context.spotlightFocus == nil else { finish(attempt, outcome: .cancelled); return }
        let policy = context.policy.textControlPolicy(for: context.application, snapshot: context.snapshot)
        guard let input = UnicodeTextInput(text: text, controlPolicy: policy) else {
            refuse(attempt, .unicodePayloadUnsupported, "Редактор не поддерживает безопасную замену такого фрагмента"); return
        }
        // A word is deleted first and typed only once the editor shows it
        // gone: web search fields can drop fast Backspaces while they rebuild.
        let deleting = attempt.selected ? 0 : attempt.deletingCharacters
        guard CGPreflightPostEventAccess(), let batches = input.makeEventBatches(deletingCharacters: 0),
              deleting == 0 || UnicodeTextInput.deletionBatch(count: deleting) != nil,
              reserveMutation(attempt) else { finish(attempt, outcome: .cancelled); return }
        let typeText = {
            KeyboardEvents.postTextReplacement(batches, valid: { self.valid(attempt) }, modifiersClear: attempt.observedModifiersClear) { delivered in
                self.mutationDelivered(attempt, delivered: delivered)
            }
        }
        guard deleting > 0, let scope = attempt.scopePlan else { typeText(); return }
        let deadline = ReadinessDeadline(start: ProcessInfo.processInfo.systemUptime, timeout: ConversionTiming.wordDeletionDeadline,
                                         pollInterval: ConversionTiming.pollInterval)
        // Browser pages can take ~60 ms per Backspace while they rebuild
        // suggestions. A letters-only word (whitespace-bounded by its token)
        // goes in one Option+Backspace; any rest is deleted below.
        let browser = context.application.isChromium || ["com.apple.Safari", "com.apple.SafariTechnologyPreview"].contains(context.application.bundleID)
        let asOneWord = browser && TypedWordTracker.deletesAsOneWord(scope.text, boundedStart: true)
        deleteWord(attempt, context: context, scope: scope, count: deleting, asOneWord: asOneWord, topUps: 0, deadline: deadline, then: typeText)
    }

    /// Posts `count` Backspaces, then waits for the editor to show the word gone.
    private func deleteWord(_ attempt: ConversionAttempt, context: AXEditorContext, scope: AccessibilitySelectionPlan,
                            count: Int, asOneWord: Bool = false, topUps: Int, deadline: ReadinessDeadline, then: @escaping () -> Void) {
        guard let batch = UnicodeTextInput.deletionBatch(count: count, asOneWord: asOneWord) else { finish(attempt, outcome: .unverified); return }
        KeyboardEvents.postTextReplacement([batch], valid: { self.valid(attempt) }, modifiersClear: attempt.observedModifiersClear) { delivered in
            guard delivered else { self.mutationDelivered(attempt, delivered: false); return }
            self.awaitDeletion(attempt, context: context, scope: scope, posted: count, topUps: topUps, deadline: deadline,
                               last: nil, stableSince: ProcessInfo.processInfo.systemUptime, then: then)
        }
    }

    /// Deletion that started (fewer than `posted` units left) and then stays
    /// unchanged for `deletionStableInterval` lost its Backspaces; the missing
    /// ones are sent again, at most twice. A page that has not applied any yet
    /// is only waited for, so queued Backspaces never delete past the word.
    private func awaitDeletion(_ attempt: ConversionAttempt, context: AXEditorContext, scope: AccessibilitySelectionPlan,
                               posted: Int, topUps: Int, deadline: ReadinessDeadline, last: DeletionProgress?, stableSince: Double,
                               then: @escaping () -> Void) {
        guard valid(attempt) else { finish(attempt, outcome: .unverified); return }
        guard !deadline.expired(at: ProcessInfo.processInfo.systemUptime) else {
            // The Backspaces were posted; never leave the word deleted. Type
            // the replacement as the single-batch path did; the
            // acknowledgement still decides whether it is confirmed.
            diagnosticDetails += "; редактор не подтвердил удаление слова"
            attempt.deletionUnconfirmed = last.map { "\($0)" } ?? "unread"
            then(); return
        }
        read(attempt, operation: { $0.validate(context) }) { snapshot in
            let progress = snapshot == nil ? nil : DeletionProgress.evaluate(document: scope.document, wordRange: scope.range,
                                                                              value: snapshot?.value, caret: snapshot?.range)
            let now = ProcessInfo.processInfo.systemUptime
            let since = progress == last ? stableSince : now
            switch progress ?? .unknown {
            case .done: then(); return
            case .unknown where snapshot != nil && now - since >= ConversionTiming.deletionUnreadableGrace:
                // The editor reads, but not as the word gone or partly gone:
                // waiting cannot confirm it, so type as the single batch did.
                self.diagnosticDetails += "; редактор не подтвердил удаление слова"
                attempt.deletionUnconfirmed = Self.deletionShape(scope: scope, snapshot: snapshot)
                then(); return
            case .remaining(let count) where count < posted && topUps < 2 && now - since >= ConversionTiming.deletionStableInterval:
                attempt.lostBackspaces += count
                self.deleteWord(attempt, context: context, scope: scope, count: count, topUps: topUps + 1, deadline: deadline, then: then)
                return
            default: break
            }
            self.schedule(attempt, delay: ConversionTiming.pollInterval) {
                self.awaitDeletion(attempt, context: context, scope: scope, posted: posted, topUps: topUps, deadline: deadline,
                                   last: progress, stableSince: since, then: then)
            }
        }
    }

    /// Text-free numbers for an unreadable deletion: value length and caret
    /// relative to the word gone, newlines and no-break spaces in the value.
    private static func deletionShape(scope: AccessibilitySelectionPlan, snapshot: AXEditorSnapshot?) -> String {
        guard let value = snapshot?.value, let caret = snapshot?.range else { return "unknown" }
        let expected = (scope.document as NSString).length - scope.range.length
        return "unknown len\((value as NSString).length - expected) caret\(caret.location - scope.range.location)/\(caret.length)"
            + " nl\(value.filter { $0 == "\n" }.count)/\(scope.document.filter { $0 == "\n" }.count) nbsp\(value.contains("\u{a0}") ? 1 : 0)"
    }

    private func mutationDelivered(_ attempt: ConversionAttempt, delivered: Bool) {
        guard self.attempt === attempt else { return }
        attempt.trace.end(.mutation)
        guard delivered, valid(attempt) else { finish(attempt, outcome: .unverified); return }
        attempt.trace.begin(.confirmation)
        beginAcknowledgement(attempt)
        awaitAcknowledgement(attempt)
    }

    private func beginAcknowledgement(_ attempt: ConversionAttempt) {
        attempt.readiness = ReadinessDeadline(start: ProcessInfo.processInfo.systemUptime, timeout: ConversionTiming.replacementDeadline,
                                              pollInterval: ConversionTiming.pollInterval)
    }

    /// Event receipt only paces delivery. A fixed AX polling budget must prove
    /// both the complete document and the exact empty caret at the edit's end.
    private func awaitAcknowledgement(_ attempt: ConversionAttempt) {
        guard valid(attempt), let context = attempt.context, let replacement = attempt.replacement,
              var deadline = attempt.readiness else { finish(attempt, outcome: .unverified); return }
        attempt.phase = "acknowledgement"
        let now = ProcessInfo.processInfo.systemUptime
        if deadline.expired(at: now) { finish(attempt, outcome: .unverified); return }
        guard deadline.shouldRead(at: now) else {
            schedule(attempt, delay: deadline.delay(at: now)) { self.awaitAcknowledgement(attempt) }; return
        }
        attempt.readiness = deadline
        read(attempt, operation: { $0.acknowledgement(context, replacement: replacement, cancellation: attempt.cancellation) }) { result in
            guard !deadline.expired(at: ProcessInfo.processInfo.systemUptime) else {
                self.finish(attempt, outcome: .unverified); return
            }
            let snapshot: AXEditorSnapshot
            switch result {
            case .snapshot(let value): snapshot = value
            case .busy:
                self.schedule(attempt, delay: ConversionTiming.pollInterval) { self.awaitAcknowledgement(attempt) }
                return
            case .invalid, nil: self.finish(attempt, outcome: .unverified); return
            }
            if replacement.confirmsCaret(document: snapshot.value, range: snapshot.range,
                                          selectedText: snapshot.selectedText, selectedRanges: snapshot.selectedRanges) {
                self.confirmed(attempt)
            } else if !attempt.selected, attempt.usesNativeSearchValue, !attempt.queryCaretRestored,
                      replacement.documentMatches(snapshot.value) {
                guard let caret = snapshot.range,
                      AccessibilitySelectionPlan.confirmsCaret(document: snapshot.value, range: caret,
                          selectedText: snapshot.selectedText, selectedRanges: snapshot.selectedRanges,
                          expectedDocument: replacement.document, expectedCaret: caret) else {
                    self.finish(attempt, outcome: .unverified); return
                }
                attempt.queryCaretRestored = true
                self.awaitCaretModifiers(attempt) {
                    guard self.valid(attempt, mutation: true),
                          !deadline.expired(at: ProcessInfo.processInfo.systemUptime) else {
                        self.finish(attempt, outcome: .unverified); return
                    }
                    self.read(attempt, operation: {
                        $0.restoreCaret(context, document: replacement.document, currentCaret: caret,
                            expectedCaret: replacement.caret, deadline: deadline, cancellation: attempt.cancellation)
                    }) { restored in
                        guard restored == true else { self.finish(attempt, outcome: .unverified); return }
                        // Keep the original deadline: one caret correction
                        // cannot renew or retry document/caret verification.
                        self.awaitAcknowledgement(attempt)
                    }
                }
            } else {
                self.schedule(attempt, delay: ConversionTiming.pollInterval) { self.awaitAcknowledgement(attempt) }
            }
        }
    }

    private func confirmed(_ attempt: ConversionAttempt) {
        guard valid(attempt), let conversion = attempt.converted else { finish(attempt, outcome: .unverified); return }
        attempt.trace.end(.confirmation)
        attempt.trace.end(.total)
        InputSources.selectAfterConversion(conversion.target)
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

    /// Text-free numbers for a selected-text mismatch: where the reported
    /// selected text actually occurs relative to the reported range.
    private static func mismatchDiagnostic(document: String, range: NSRange, selectedText: String?) -> [String: Any] {
        let string = document as NSString
        var report: [String: Any] = ["documentUTF16": string.length, "rangeLocation": range.location, "rangeLength": range.length,
                                     "documentNewlines": document.filter { $0 == "\n" || $0 == "\r\n" }.count,
                                     "documentHasCR": document.unicodeScalars.contains { $0 == "\r" },
                                     "documentHasNBSP": document.contains("\u{a0}")]
        guard let selectedText else { report["selectedText"] = "absent"; return report }
        let selected = selectedText as NSString
        report["selectedUTF16"] = selected.length
        report["selectedHasNBSP"] = selectedText.contains("\u{a0}")
        report["selectedNewlines"] = selectedText.filter { $0 == "\n" || $0 == "\r\n" }.count
        var deltas: [Int] = []
        var search = NSRange(location: 0, length: string.length)
        while selected.length > 0, deltas.count < 8 {
            let found = string.range(of: selectedText, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            deltas.append(found.location - range.location)
            search = NSRange(location: found.location + 1, length: string.length - found.location - 1)
        }
        report["occurrenceDeltas"] = deltas
        report["newlinesBeforeRange"] = string.substring(to: min(range.location, string.length)).filter { $0 == "\n" || $0 == "\r\n" }.count
        return report
    }

    private func refuse(_ attempt: ConversionAttempt, _ reason: Refusal, _ message: String) {
        attempt.refusal = reason
        finish(attempt, outcome: .failure(message))
    }

    private func refuseScope(_ attempt: ConversionAttempt, _ proof: AXTextScopeRead) {
        let reason: Refusal
        if case .mismatch = proof { reason = .rangeTextMismatch } else { reason = .rangeTextUnavailable }
        refuse(attempt, reason, "Редактор не подтвердил текст фрагмента рядом с вложением")
    }

    private func finish(_ attempt: ConversionAttempt, outcome: Outcome) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.attempt === attempt, attempt.lifecycle.finish() else { return }
        attempt.cancellation.cancel()
        attempt.poll?.cancel(); attempt.poll = nil
        KeyboardEvents.cancelDelivery()
        let confirmed: Bool = if case .converted = outcome { true } else { false }
        if case .unverified = outcome { unconfirmedInput = attempt.unchanged; diagnosticDetails += "; результат не подтверждён" }
        if case .cancelled = outcome { diagnosticDetails += "; отменено до ввода" }
        lastSummary = ["phase": attempt.phase, "elapsedMS": Int((ProcessInfo.processInfo.systemUptime - attempt.started) * 1000)]
        if let refusal = attempt.refusal { lastSummary["refusal"] = refusal.rawValue }
        if attempt.lostBackspaces > 0 { lastSummary["lostBackspaces"] = attempt.lostBackspaces }
        if let unconfirmed = attempt.deletionUnconfirmed { lastSummary["deletionUnconfirmed"] = unconfirmed }
        if let context = attempt.context {
            var report = context.conversionDiagnostic()
            switch outcome {
            case .converted: report["outcome"] = "converted"
            case .cancelled: report["outcome"] = "cancelled"
            case .failure: report["outcome"] = "refused"
            case .unverified: report["outcome"] = "unverified"
            case .ignored: report["outcome"] = "ignored"
            }
            report["editingGuardPassed"] = attempt.editingGuardPassed
            report["phase"] = attempt.phase
            if let refusal = attempt.refusal { report["refusalCode"] = refusal.rawValue }
            if let mismatch = attempt.mismatch { report["selectionMismatch"] = mismatch }
            if let proof = attempt.scopeRead {
                report["attachmentRangeText"] = proof.diagnosticCode
                if case .unavailable(let error) = proof { report["attachmentRangeTextAXError"] = Int(error.rawValue) }
            }
            if let snapshot = context.snapshot {
                report["documentHasAttachment"] = snapshot.value.map(AccessibilitySelectionPlan.hasTextAttachment) ?? false
                report["inputScope"] = snapshot.range.map { $0.length == 0 ? "caret" : "selection" } ?? "unavailable"
                report["selectionRanges"] = snapshot.selectedRanges.map { $0.isEmpty ? "empty" : ($0.count == 1 ? "single" : "multiple") } ?? "absent"
            }
            if let scope = attempt.scopePlan {
                report["targetHasAttachment"] = AccessibilitySelectionPlan.hasTextAttachment(scope.text)
                report["targetHasLineBreaks"] = scope.text.contains("\n") || scope.text.contains("\u{2028}")
            }
            report["timestamp"] = Date().timeIntervalSince1970
            DiagnosticReports.shared.record("LastEditingRefusalDiagnostic", report, includeVersion: true)
        }
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
    let modifiersClear: () -> Bool
    let observedModifiersClear: () -> Bool
    let completion: (ConversionCoordinator.Outcome) -> Void
    var context: AXEditorContext?
    var targetPID: pid_t?
    var spotlightFocus: AXSpotlightFocus?
    var converted: InputSources.Conversion?
    var originalDocument: String?
    var originalRange: NSRange?
    var selectionPlan: AccessibilitySelectionPlan?
    var scopePlan: AccessibilitySelectionPlan?
    var scopeRead: AXTextScopeRead?
    var refusal: ConversionCoordinator.Refusal?
    var mismatch: [String: Any]?
    var phase = "discovery"
    let started = ProcessInfo.processInfo.systemUptime
    var replacement: AccessibilityReplacementPlan?
    var deletingCharacters = 0
    /// Backspaces the editor dropped and that were sent again.
    var lostBackspaces = 0
    /// Last deletion state seen when its confirmation timed out.
    var deletionUnconfirmed: String?
    var selected = false
    var editingGuardPassed = false
    var usesNativeSearchValue = false
    var queryCaretRestored = false
    var readiness: ReadinessDeadline?
    var poll: DispatchWorkItem?
    init(frontmostPID: pid_t, trace: ConversionTrace, unchanged: @escaping () -> Bool,
         modifiersClear: @escaping () -> Bool, observedModifiersClear: @escaping () -> Bool,
         completion: @escaping (ConversionCoordinator.Outcome) -> Void) {
        self.frontmostPID = frontmostPID; self.trace = trace; self.unchanged = unchanged
        self.modifiersClear = modifiersClear
        self.observedModifiersClear = observedModifiersClear; self.completion = completion
    }
}
