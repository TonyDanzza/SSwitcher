import AppKit
import Carbon
import SwitcherCore

/// Native MAX transaction: ask the current responder about selection first,
/// then select and replace the word before the caret in one request.
/// No ordinary clipboard, modifier presses or text injection.
final class NativeWordServiceCoordinator {
    private let pid: pid_t
    private let window: AXUIElement
    private let valid: () -> Bool
    private let beforeKeys: () -> Bool
    private let prepareWord: (@escaping () -> Void) -> Void
    private let completion: (Bool, String) -> Void
    /// One Option+Shift+Left + conversion request replaces the word before
    /// the caret, keeping whitespace the caret followed. Set from the start
    /// when the caller tracked that no selection can exist (the selection
    /// probe and its native return settle are skipped), or after the probe
    /// found no selection. A caret inside a word converts the part to its left.
    private var direct: Bool
    /// Converted packet text after a published direct response, for the
    /// caller's typed-word memory; never stored.
    private(set) var convertedText: String?
    private var timeout: DispatchWorkItem?
    private var finished = false
    private var committing = false
    private var commitState = NativeServiceDispatchState()
    private var selectionState = NativeSelectionDispatchState()
    private var wordIssuedAt: Double?
    private var modifierWait: ModifierReleaseReadiness?
    private var plan: NativeWordBoundaryPlan?
    private let started = ProcessInfo.processInfo.systemUptime
    private var phase = "created"
    private(set) var status = "Проверяю слово MAX"

    init(pid: pid_t, window: AXUIElement, direct: Bool = false, valid: @escaping () -> Bool,
         beforeKeys: @escaping () -> Bool,
         prepareWord: @escaping (@escaping () -> Void) -> Void,
         completion: @escaping (Bool, String) -> Void) {
        self.pid = pid; self.window = window; self.direct = direct; self.valid = valid
        self.beforeKeys = beforeKeys; self.prepareWord = prepareWord; self.completion = completion
    }

    func start() {
        guard live else { return }
        if direct {
            phase = "preparingWord"
            record("directWord")
            prepareWord { [weak self] in
                guard let self, self.live else { return }
                self.selectWord()
            }
            return
        }
        guard waitForModifiers({ [weak self] in self?.start() }) else { return }
        issue([(CGKeyCode(kVK_F19), .maskCommand), (CGKeyCode(kVK_F20), .maskCommand)],
              unavailable: "Нативная проверка выделения MAX недоступна", before: {
            phase = "selection"
            committing = true
            record("selectionIssued")
            armTimeout("MAX не подтвердил завершение запроса выделения")
        }) { [weak self] delivered in
            guard let self, self.live, self.phase == "selection" else { return }
            self.selectionState.delivery(delivered)
            self.completeSelection()
        }
    }

    private func completeSelection() {
        guard live, phase == "selection", let result = selectionState.result else { return }
        timeout?.cancel(); timeout = nil
        switch result {
        case .submitted:
            record("selectionSubmitted")
            completion(true, "Выделение передано нативному редактору MAX")
        case .rejected:
            fail("Нативная замена выделения MAX не подтверждена")
        case .empty:
            // Both queued requests have returned without any replacement
            // publication. A stale AXEnabled menu value is not consulted.
            committing = false
            direct = true
            phase = "preparingWord"
            record("selectionEmpty")
            // Capture does not navigate or invoke another service. Prepare it
            // during the requestor-return settle, then wait only the remainder
            // before navigation. Both prerequisites must finish first.
            let readyAt = DispatchTime.now() + ConversionTiming.nativeServiceReturnSettle
            prepareWord { [weak self] in
                guard let self, self.live else { return }
                DispatchQueue.main.asyncAfter(deadline: readyAt) { [weak self] in
                    guard let self, self.live else { return }
                    self.selectWord()
                }
            }
        }
    }

    private func selectWord() {
        guard live else { return }
        guard waitForModifiers({ [weak self] in self?.selectWord() }) else { return }
        // Both commands share one native window/event queue. The service
        // receives the actual selection, validates it, and returns its
        // replacement in that same call. No extra read/navigation/AX action
        // occurs while the word is selected.
        issue([(CGKeyCode(kVK_LeftArrow), [.maskAlternate, .maskShift]), (CGKeyCode(kVK_F19), .maskCommand)],
              unavailable: "Нативная замена слова недоступна", before: {
            phase = "wordCommit"
            committing = true
            wordIssuedAt = ProcessInfo.processInfo.systemUptime
            armTimeout("MAX не предоставил слово для нативной замены")
            record("wordCommitIssued")
        }) { [weak self] delivered in
            guard let self, self.live else { return }
            self.commitState.pressed(delivered)
            if !delivered { self.fail("Нативный вызов замены не доставлен MAX"); return }
            self.completeCommit()
        }
    }

    var isAwaitingConversion: Bool { live && committing && (phase == "selection" || phase == "wordCommit") }

    func permitsCommit(_ text: String) -> Bool {
        if live, committing, phase == "selection" { return NativeServicePayload.accepts(text) }
        return live && committing && phase == "wordCommit" && wordPlan(text) != nil &&
            (plan == nil || plan?.matches(text) == true)
    }

    private func wordPlan(_ text: String) -> NativeWordBoundaryPlan? {
        direct ? NativeWordBoundaryPlan(directSelection: text) : NativeWordBoundaryPlan(selection: text)
    }

    func prepareCommit(_ text: String) -> InputSources.Conversion? {
        if live, committing, phase == "selection", NativeServicePayload.accepts(text) {
            return InputSources.prepare(text)
        }
        guard permitsCommit(text), let exact = wordPlan(text),
              let converted = InputSources.prepare(exact.word) else { return nil }
        let conversion = InputSources.Conversion(text: converted.text + exact.trailing, target: converted.target)
        plan = exact
        if direct { convertedText = conversion.text }
        DiagnosticReports.shared.record("NativeWordScopeReport", ["selectedGraphemes": text.count, "singleNativeCall": true])
        return conversion
    }

    func didPublish(_ success: Bool) {
        guard live, committing else { return }
        if phase == "selection" {
            selectionState.published(success)
            RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.completeSelection() }
            return
        }
        commitState.published(success)
        // Let the provider callback return before changing ordinary sources.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.completeCommit() }
    }

    private func completeCommit() {
        guard live, let outcome = commitState.completed else { return }
        timeout?.cancel(); timeout = nil
        if direct, commitState.publication == false {
            // The request reached us, so MAX holds our word selection.
            // Collapse it to its right end (the original caret) after the
            // requestor resumes, then report the refusal.
            convertedText = nil
            phase = "collapsing"
            DispatchQueue.main.asyncAfter(deadline: .now() + ConversionTiming.nativeServiceReturnSettle) { [weak self] in
                guard let self, self.live else { return }
                self.perform(kVK_RightArrow) { [weak self] in
                    self?.fail("Слово перед курсором не требует замены или не подходит для неё")
                }
            }
            return
        }
        guard outcome == .submitted else {
            fail("Нативная замена слова не подтверждена"); return
        }
        record("wordCommitSubmitted")
        completion(true, "Слово передано нативному редактору MAX")
    }

    private var live: Bool { !finished && valid() }

    /// The window server number of the transaction's window, resolved once.
    /// `beforeKeys` still proves the same focused AX window before each batch.
    private var resolvedWindowNumber: Int?
    private func windowNumber() -> Int? {
        if let resolvedWindowNumber { return resolvedWindowNumber }
        resolvedWindowNumber = NativeWindowLocator.windowNumber(window, pid: pid)
        return resolvedWindowNumber
    }

    /// Posts one batch bound to the transaction's window: `beforeKeys` proves
    /// the same focused window, then the batch is built and bound to its
    /// number; any failure ends with `unavailable`. `before` runs right
    /// before posting, `delivered` receives MAX's delivery receipt.
    private func issue(_ keys: [(CGKeyCode, CGEventFlags)], unavailable: String,
                       before: () -> Void, delivered: @escaping (Bool) -> Void) {
        guard beforeKeys(), let number = windowNumber(),
              let raw = NativeServiceBarrierEvents.batch(keys),
              let events = NativeServiceBarrierEvents.boundToWindow(raw, number: number) else {
            fail(unavailable); return
        }
        before()
        KeyboardEvents.postAndAwaitDelivery(events, targetPID: pid, completion: delivered)
    }

    /// One plain navigation key, then a settle before `then`.
    private func perform(_ key: Int, then: @escaping () -> Void) {
        guard live else { return }
        guard waitForModifiers({ [weak self] in self?.perform(key, then: then) }) else { return }
        issue([(CGKeyCode(key), [])], unavailable: "Замена отменена: исходное окно или клавиши недоступны", before: {
            armTimeout("MAX не подтвердил доставку навигации")
        }) { [weak self] delivered in
            guard let self, self.live else { return }
            self.timeout?.cancel(); self.timeout = nil
            guard delivered else { self.fail("Навигация не доставлена MAX"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + ConversionTiming.nativeNavigationSettle) { [weak self] in
                guard self?.live == true else { return }
                then()
            }
        }
    }

    /// Called only by the native return-only requestor after the selection
    /// request. No AX IPC is made while that responder waits on us.
    func receiveBarrier() {
        guard live, phase == "selection" else { return }
        selectionState.receiveBarrier()
        RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.completeSelection() }
    }


    private func waitForModifiers(_ retry: @escaping () -> Void) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let clear = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskShift, .maskAlternate, .maskControl, .maskCommand]).isEmpty
        let wait = modifierWait ?? ModifierReleaseReadiness(start: now,
            timeout: ConversionTiming.modifierReleaseDeadline, pollInterval: ConversionTiming.pollInterval)
        switch wait.decision(at: now, inputUnchanged: live, modifiersClear: clear) {
        case .ready: modifierWait = nil; return true
        case .wait(let delay):
            modifierWait = wait
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.live == true else { return }
                retry()
            }
        case .cancelled, .timedOut: fail("Замена отменена: дождитесь отпускания Shift")
        }
        return false
    }

    private func armTimeout(_ reason: String) {
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fail(reason) }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + ConversionTiming.nativeServiceReplyDeadline, execute: item)
    }

    private func fail(_ reason: String) {
        guard !finished else { return }
        status = reason; record("failed", reason: reason)
        phase = "failed"
        cancel(); completion(false, reason)
    }

    func cancel() {
        guard !finished else { return }
        if phase != "failed" { record(committing ? "closed" : "cancelled") }
        finished = true; timeout?.cancel(); timeout = nil
        KeyboardEvents.cancelDelivery()
        plan = nil; modifierWait = nil
    }

    private func record(_ stage: String, reason: String? = nil) {
        var report: [String: Any] = ["stage": stage, "phase": phase,
            "elapsedMS": Int((ProcessInfo.processInfo.systemUptime - started) * 1000)]
        if let wordIssuedAt { report["wordCommitMS"] = Int((ProcessInfo.processInfo.systemUptime - wordIssuedAt) * 1000) }
        if let reason { report["reason"] = reason }
        DiagnosticReports.shared.record("NativeWordServiceReport", report)
    }
}
