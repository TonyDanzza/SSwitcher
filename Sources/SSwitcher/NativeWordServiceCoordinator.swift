import AppKit
import Carbon
import SwitcherCore

/// Native MAX transaction: ask the current responder about selection first,
/// then prove the right boundary before selecting and replacing a word.
/// No ordinary clipboard, modifier presses or text injection.
final class NativeWordServiceCoordinator {
    private final class Packet {
        var state = NativeSelectionReadState()
        let noSelection: (() -> Void)?
        let completion: (String) -> Void
        init(_ completion: @escaping (String) -> Void, noSelection: (() -> Void)?) {
            self.completion = completion; self.noSelection = noSelection
        }
    }
    private let pid: pid_t
    private let window: AXUIElement
    private let valid: () -> Bool
    private let beforeKeys: () -> Bool
    private let prepareWord: (@escaping () -> Void) -> Void
    private let completion: (Bool, String) -> Void
    /// The caller tracked that no selection can exist, so the selection and
    /// boundary probes (each followed by a native return settle) are skipped:
    /// one Option+Shift+Left + conversion request replaces the word before
    /// the caret, keeping whitespace the caret followed.
    private let direct: Bool
    /// Converted packet text after a published direct response, for the
    /// caller's typed-word memory; never stored.
    private(set) var convertedText: String?
    private var packet: Packet?
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
        guard beforeKeys(), let number = NativeWindowLocator.windowNumber(window, pid: pid),
              let raw = NativeServiceBarrierEvents.batch([
                (CGKeyCode(kVK_F19), .maskCommand), (CGKeyCode(kVK_F20), .maskCommand)
              ]),
              let events = NativeServiceBarrierEvents.boundToWindow(raw, number: number) else {
            fail("Нативная проверка выделения MAX недоступна"); return
        }
        phase = "selection"
        committing = true
        record("selectionIssued")
        armTimeout("MAX не подтвердил завершение запроса выделения")
        KeyboardEvents.postAndAwaitDelivery(events, targetPID: pid, directToTarget: false,
            postingTap: .cgSessionEventTap) { [weak self] delivered in
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
                    self.startBoundary()
                }
            }
        }
    }

    private func startBoundary() {
        phase = "boundary"
        // The return-only service is an actual responder-loop barrier after
        // the selected-text request, including at an empty EOF caret. A
        // missing callback/timeout alone is never treated as EOF.
        read({ [weak self] following in
            guard let self, self.live else { return }
            guard NativeWordBoundaryPlan.isFollowingDelimiter(following) else {
                self.perform([(CGKeyCode(kVK_LeftArrow), [])]) { [weak self] in
                    self?.fail("Курсор должен стоять в конце преобразуемого слова")
                }
                return
            }
            self.selectWord(restoreBoundary: true)
        }, noSelection: { [weak self] in self?.selectWord() },
           navigation: [(CGKeyCode(kVK_RightArrow), .maskShift)])
    }

    private func selectWord(restoreBoundary: Bool = false) {
        guard live else { return }
        guard waitForModifiers({ [weak self] in self?.selectWord(restoreBoundary: restoreBoundary) }) else { return }
        // Both commands share one native window/event queue. The service
        // receives the actual selection, validates it, and returns its
        // replacement in that same call. No extra read/navigation/AX action
        // occurs while the word is selected.
        guard beforeKeys(), let number = NativeWindowLocator.windowNumber(window, pid: pid),
              let raw = NativeServiceBarrierEvents.batch(
                (restoreBoundary ? [(CGKeyCode(kVK_LeftArrow), CGEventFlags())] : []) + [
                    (CGKeyCode(kVK_LeftArrow), [.maskAlternate, .maskShift]),
                    (CGKeyCode(kVK_F19), .maskCommand)
                ]),
              let events = NativeServiceBarrierEvents.boundToWindow(raw, number: number) else {
            fail("Нативная замена слова недоступна"); return
        }
        phase = "wordCommit"
        committing = true
        wordIssuedAt = ProcessInfo.processInfo.systemUptime
        armTimeout("MAX не предоставил слово для нативной замены")
        record("wordCommitIssued")
        KeyboardEvents.postAndAwaitDelivery(events, targetPID: pid, directToTarget: false,
            postingTap: .cgSessionEventTap) { [weak self] delivered in
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
                self.perform([(CGKeyCode(kVK_RightArrow), [])]) { [weak self] in
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

    private func perform(_ steps: [(CGKeyCode, CGEventFlags)], then: @escaping () -> Void) {
        guard !steps.isEmpty else { then(); return }
        if steps.count > 1 {
            perform([steps[0]]) { [weak self] in
                self?.perform(Array(steps.dropFirst()), then: then)
            }
            return
        }
        guard live else { return }
        guard waitForModifiers({ [weak self] in self?.perform(steps, then: then) }) else { return }
        guard beforeKeys(), let number = NativeWindowLocator.windowNumber(window, pid: pid),
              let raw = NativeServiceBarrierEvents.batch(steps, state: .privateState),
              let events = NativeServiceBarrierEvents.boundToWindow(raw, number: number) else {
            fail("Замена отменена: исходное окно или клавиши недоступны"); return
        }
        armTimeout("MAX не подтвердил доставку навигации")
        KeyboardEvents.postAndAwaitDelivery(events, targetPID: pid, directToTarget: false,
            postingTap: .cgSessionEventTap) { [weak self] delivered in
            guard let self, self.live else { return }
            self.timeout?.cancel(); self.timeout = nil
            guard delivered else { self.fail("Навигация не доставлена MAX"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + ConversionTiming.nativeNavigationSettle) { [weak self] in
                guard self?.live == true else { return }
                then()
            }
        }
    }

    private func read(_ completion: @escaping (String) -> Void, noSelection: (() -> Void)? = nil,
                      navigation: [(CGKeyCode, CGEventFlags)] = []) {
        guard live else { return }
        guard waitForModifiers({ [weak self] in self?.read(completion, noSelection: noSelection, navigation: navigation) }) else { return }
        guard beforeKeys(), let number = NativeWindowLocator.windowNumber(window, pid: pid),
              let raw = NativeServiceBarrierEvents.batch(navigation + [
                (CGKeyCode(kVK_F19), .maskCommand), (CGKeyCode(kVK_F20), .maskCommand)
              ]),
              let events = NativeServiceBarrierEvents.boundToWindow(raw, number: number) else {
            fail("Нативное чтение MAX недоступно"); return
        }
        record("reading")
        let ticket = Packet(completion, noSelection: noSelection)
        packet = ticket
        armPacketTimeout(ticket)
        KeyboardEvents.postAndAwaitDelivery(events, targetPID: pid, directToTarget: false, postingTap: .cgSessionEventTap) { [weak self] delivered in
            guard let self, self.live, self.packet === ticket else { return }
            guard delivered else { self.fail("Вызов службы не доставлен MAX"); return }
            ticket.state.delivery(true)
            self.completePacket(ticket)
        }
    }

    private func armPacketTimeout(_ ticket: Packet) {
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self, weak ticket] in
            guard let self, let ticket, self.live, self.packet === ticket else { return }
            self.fail("MAX не подтвердил нативное чтение и завершение вызова")
        }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + ConversionTiming.nativeServiceReplyDeadline, execute: item)
    }

    /// Called only by the native return-only requestor after the preceding
    /// read service. No AX IPC is made while that responder waits on us.
    func receiveBarrier() {
        if live, phase == "selection" {
            selectionState.receiveBarrier()
            RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.completeSelection() }
            return
        }
        guard live, phase == "boundary", let ticket = packet else { return }
        ticket.state.receiveBarrier()
        RunLoop.main.perform(inModes: [.common]) { [weak self, weak ticket] in
            guard let self, let ticket, self.live, self.packet === ticket else { return }
            self.completePacket(ticket)
        }
    }

    func receivePacket(_ text: String) -> Bool {
        guard live, let ticket = packet, ticket.state.receive(text) else { return false }
        RunLoop.main.perform(inModes: [.common]) { [weak self, weak ticket] in
            guard let self, let ticket, self.packet === ticket else { return }
            guard self.live, self.beforeKeys() else { self.fail("Нативный контекст MAX изменился"); return }
            self.completePacket(ticket)
        }
        return true
    }

    private func completePacket(_ ticket: Packet) {
        guard live, packet === ticket, let result = ticket.state.result else { return }
        guard result != .rejected else { fail("MAX предоставил некорректный нативный ответ"); return }
        packet = nil; timeout?.cancel(); timeout = nil
        // A provider callback is not the requestor's resumed event loop.
        // Keep the established bounded return settle before the next native
        // navigation; never use a missing reply/timeout to infer EOF.
        DispatchQueue.main.asyncAfter(deadline: .now() + ConversionTiming.nativeServiceReturnSettle) { [weak self] in
            guard let self, self.live else { return }
            if case .selection(let text) = result {
                self.record("packetReady")
                ticket.completion(text)
                return
            }
            guard let noSelection = ticket.noSelection, self.beforeKeys() else {
                self.fail("MAX не предоставил нативный текст"); return
            }
            self.record("nativeEmptyBoundary")
            noSelection()
        }
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
        packet = nil; plan = nil; modifierWait = nil
    }

    private func record(_ stage: String, reason: String? = nil) {
        var report: [String: Any] = ["stage": stage, "phase": phase,
            "elapsedMS": Int((ProcessInfo.processInfo.systemUptime - started) * 1000)]
        if let wordIssuedAt { report["wordCommitMS"] = Int((ProcessInfo.processInfo.systemUptime - wordIssuedAt) * 1000) }
        if let reason { report["reason"] = reason }
        DiagnosticReports.shared.record("NativeWordServiceReport", report)
    }
}
