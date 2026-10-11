import AppKit
import Carbon
import InputMethodSupport
import SwitcherCore

/// Native selected-text and word Services paths for one MAX gesture.
/// Window identity is captured outside the service callback: the waiting host
/// must never receive AX IPC. Publishing a response is not acknowledgement of
/// editor text or its caret.
final class NativeSelectionServiceProof {
    fileprivate struct WindowIdentity {
        let pid: pid_t
        let window: AXUIElement
        let sourceID: String
    }
    private final class Automatic {
        let identity: WindowIdentity
        let deadline: ReadinessDeadline
        let valid: () -> Bool
        let completion: (NativeServiceDispatchState.Outcome, TISInputSource?) -> Void
        var state = NativeServiceDispatchState()
        var target: TISInputSource?
        var word: NativeWordServiceCoordinator?
        var failure: String?
        /// One response publication per gesture; the first callback consumes it.
        var commitAvailable = true
        init(identity: WindowIdentity, deadline: ReadinessDeadline, valid: @escaping () -> Bool,
             completion: @escaping (NativeServiceDispatchState.Outcome, TISInputSource?) -> Void) {
            self.identity = identity; self.deadline = deadline; self.valid = valid; self.completion = completion
        }
    }
    private var expiry: DispatchWorkItem?
    private let boundsWorker = DispatchQueue(label: "SSwitcher.native-window-bounds", qos: .userInitiated)
    private var generation = 0
    private let visualShield = NativeWordVisualShield()
    private var automatic: Automatic?
    private(set) var status = "Служба выделения MAX: не запускалась"

    var isConverting: Bool { automatic != nil }

    /// Text the last submitted direct word conversion produced, for the
    /// caller's typed-word memory. Cleared by the next request.
    private(set) var lastDirectConversion: String?

    func convertAtCursor(valid: @escaping () -> Bool, knownNoSelection: Bool = false,
                         completion: @escaping (NativeServiceDispatchState.Outcome, TISInputSource?) -> Void) {
        guard Thread.isMainThread, automatic == nil else { completion(.cancelled, nil); return }
        lastDirectConversion = nil
        cancel(keepingEarlyShield: true)
        let deadline = ReadinessDeadline(start: ProcessInfo.processInfo.systemUptime, timeout: ConversionTiming.nativeWordDeadline)
        let capture = captureWindow(armDeadline: deadline)
        guard valid(), let identity = capture.identity else { completion(.cancelled, nil); return }
        let request = Automatic(identity: identity, deadline: deadline, valid: valid, completion: completion)
        automatic = request
        let epoch = generation
        record(["stage": "nativeResponderRequest", "automatic": true, "windowProvenAtArm": true])
        expire(after: max(0, deadline.expiresAt - ProcessInfo.processInfo.systemUptime), epoch: epoch)
        // Our static Services are registered at launch. Their actual callbacks
        // prove current capability; scanning cached menu leaves adds IPC but
        // no editor authority. Missing callbacks still fail at the deadline.
        startWord(request, direct: knownNoSelection, deadline: deadline, epoch: epoch)
    }

    private func startWord(_ request: Automatic, direct: Bool, deadline: ReadinessDeadline, epoch: Int) {
        let identity = request.identity
        func localReady() -> Bool {
            generation == epoch && automatic === request && request.valid() &&
                !deadline.expired(at: ProcessInfo.processInfo.systemUptime) && foregroundMatches(identity) &&
                ordinarySourceID() == identity.sourceID && !IsSecureEventInputEnabled()
        }
        guard localReady() else { finishAutomatic(.cancelled); return }
        let word = NativeWordServiceCoordinator(pid: identity.pid, window: identity.window, direct: direct,
            valid: { [weak self, weak request] in
                guard let self, let request else { return false }
                return self.generation == epoch && self.automatic === request && request.valid() &&
                    !deadline.expired(at: ProcessInfo.processInfo.systemUptime) && self.foregroundMatches(identity) &&
                    self.ordinarySourceID() == identity.sourceID && !IsSecureEventInputEnabled()
            }, beforeKeys: { [weak self] in
                guard let self else { return false }
                let capture = self.captureWindow(armDeadline: deadline)
                return capture.identity.map { $0.pid == identity.pid && $0.sourceID == identity.sourceID &&
                    CFEqual($0.window, identity.window) } == true

            }, prepareWord: { [weak self, weak request] resume in
                guard let self, let request, self.generation == epoch, self.automatic === request else { return }
                // Capture only when navigation will be needed, and never make
                // remote AX calls inside a synchronous Services callback.
                self.boundsWorker.async { [weak self, weak request] in
                    guard let self, let request else { return }
                    let bounds = NativeWindowLocator.windowBounds(identity.window, pid: identity.pid)
                    DispatchQueue.main.async { [weak self, weak request] in
                        guard let self, let request, self.generation == epoch, self.automatic === request else { return }
                        self.visualShield.prepare(bounds: bounds, valid: { [weak self, weak request] in
                            guard let self, let request else { return false }
                            return self.generation == epoch && self.automatic === request && localReady()
                        }) { [weak self, weak request] in
                            guard let self, let request, self.generation == epoch, self.automatic === request else { return }
                            guard localReady() else { self.finishAutomatic(.cancelled); return }
                            resume()
                        }
                    }
                }
            }) { [weak self, weak request] ready, reason in
                guard let self, let request, self.generation == epoch, self.automatic === request else { return }
                guard ready else {
                    request.failure = reason
                    self.finishAutomatic(request.state.stopped(cancelled: false)); return
                }
                request.state.pressed(true)
                if let outcome = request.state.completed { self.finishAutomatic(outcome) }
            }
        request.word = word
        record(["stage": "nativeWordBoundary", "automatic": true])
        word.start()
    }

    func cancelVisualShield() { visualShield.cancel() }

    /// Called right after the second Shift release when a direct MAX word
    /// request is expected. Only presentation; it grants nothing.
    func prepareEarlyShield(valid: @escaping () -> Bool) {
        guard Thread.isMainThread, automatic == nil else { return }
        let deadline = ReadinessDeadline(start: ProcessInfo.processInfo.systemUptime, timeout: ConversionTiming.nativeVisualEarlyClaim)
        guard let identity = captureWindow(armDeadline: deadline).identity else { return }
        boundsWorker.async { [weak self] in
            let bounds = NativeWindowLocator.windowBounds(identity.window, pid: identity.pid)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.automatic == nil || self.automatic?.identity.pid == identity.pid, valid() else { return }
                self.visualShield.prepareEarly(bounds: bounds, valid: valid)
            }
        }
    }

    func cancelAutomatic() {
        guard Thread.isMainThread, let automatic else { return }
        finishAutomatic(automatic.state.stopped(cancelled: true))
    }

    private func finishAutomatic(_ outcome: NativeServiceDispatchState.Outcome) {
        guard let request = automatic else { return }
        let outcome = outcome == .submitted && (!request.valid() || !foregroundMatches(request.identity) ||
            ordinarySourceID() != request.identity.sourceID || IsSecureEventInputEnabled()) ? .unverified : outcome
        if outcome == .submitted { lastDirectConversion = request.word?.convertedText }
        request.word?.cancel()
        automatic = nil
        expiry?.cancel(); expiry = nil
        generation += 1
        // Closing a pending snapshot can synchronously resume preparation.
        // Retire the transaction first so its completion cannot start keys
        // during cancellation or shutdown.
        visualShield.finish(submitted: outcome == .submitted)
        status = outcome == .submitted ? "Нативная замена MAX принята" : (request.failure ?? "Нативная замена MAX не подтверждена")
        record(["stage": String(describing: outcome), "automatic": true,
                "responsePublished": request.state.publication == true,
                "nativeActionAccepted": request.state.pressAccepted == true])
        // Return from a Services callback before the caller can change the
        // ordinary keyboard source. Keep only receipts/context, never text.
        DispatchQueue.main.async { [weak self] in
            guard let self else { request.completion(.cancelled, nil); return }
            let fresh = request.valid() && self.foregroundMatches(request.identity) &&
                self.ordinarySourceID() == request.identity.sourceID && !IsSecureEventInputEnabled()
            let final = outcome == .submitted && !fresh ? NativeServiceDispatchState.Outcome.unverified : outcome
            if final != outcome {
                self.record(["stage": "unverified", "automatic": true,
                             "responsePublished": request.state.publication == true,
                             "nativeActionAccepted": request.state.pressAccepted == true])
            }
            request.completion(final, final == .submitted ? request.target : nil)
        }
    }

    func cancel(keepingEarlyShield: Bool = false) {
        guard Thread.isMainThread else { return }
        cancelAutomatic()
        if !keepingEarlyShield { visualShield.cancel() }
        expiry?.cancel(); expiry = nil
        generation += 1
    }

    /// Return-only requestor (Cmd+F20): a barrier proving that MAX finished
    /// the preceding request. Never returns replacement data.
    func receiveBarrier(_ packet: NSPasteboard, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let error else { return }
        error.pointee = "SSwitcher: проверка ввода завершена, текст не изменён" as NSString
        guard Thread.isMainThread, let request = automatic, request.word != nil, request.valid(),
              foregroundMatches(request.identity), ordinarySourceID() == request.identity.sourceID,
              !IsSecureEventInputEnabled(), ![NSPasteboard.Name.general, .find, .font, .ruler, .drag].contains(packet.name) else { return }
        // A barrier is a successful zero-write request, not a diagnostic
        // error. Clear only this dedicated packet; never return an empty
        // string or let stale formats reinsert text in Qt.
        guard NativeServicePacket.discardReturnValue(packet) else { return }
        error.pointee = nil
        request.word?.receiveBarrier()
    }

    /// The two-way native request performs the word replacement in its first
    /// callback only while our current gesture owns the commit. Boundary reads
    /// remain zero-write.
    func convertWordPacketIfRequested(_ packet: NSPasteboard,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        guard Thread.isMainThread, automatic?.word?.isAwaitingConversion == true else { return false }
        convert(packet, error: error)
        return true
    }

    /// Readonly selected packet for the native word transaction. No remote AX
    /// calls or returned data: the requestor retains its current selection.
    func receiveWordPacket(_ packet: NSPasteboard) -> Bool {
        guard Thread.isMainThread, let request = automatic, let word = request.word else { return false }
        DiagnosticReports.shared.record("NativeWordPacketReport", ["stage": "callbackReceived",
            "foregroundMAX": foregroundMatches(request.identity),
            "foregroundOwn": NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
            "providerActive": NSApp.isActive, "inputUnchanged": request.valid(),
            "hostActive": NSRunningApplication(processIdentifier: request.identity.pid)?.isActive == true,
            "menuOwnerMAX": NSWorkspace.shared.menuBarOwningApplication?.processIdentifier == request.identity.pid])
        guard request.valid(), foregroundMatches(request.identity), ordinarySourceID() == request.identity.sourceID,
              !IsSecureEventInputEnabled(), ![NSPasteboard.Name.general, .find, .font, .ruler, .drag].contains(packet.name),
              packet.availableType(from: [.string]) == .string, let text = packet.string(forType: .string) else { return true }
        _ = word.receivePacket(text)
        return true
    }

    private func convert(_ pasteboard: NSPasteboard, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let error else { return }
        error.pointee = "SSwitcher: замена выделения не выполнена" as NSString
        defer {
            if error.pointee != nil { NativeServicePacket.discardReturnValue(pasteboard) }
        }
        guard Thread.isMainThread, let request = automatic, request.commitAvailable else { return }
        request.commitAvailable = false
        let epoch = generation
        let callbackStartedAt = ProcessInfo.processInfo.systemUptime
        let callback = ReadinessDeadline(start: callbackStartedAt, timeout: 0.6)
        var report: [String: Any] = ["callCount": 1, "hasErrorPointer": true, "windowProvenAtArm": true,
                                     "windowRevalidatedInCallback": false,
                                     "wordRequest": request.word != nil]
        func ready() -> Bool {
            let secure = !IsSecureEventInputEnabled()
            let foreground = foregroundMatches(request.identity)
            let ordinary = ordinarySourceID() == request.identity.sourceID
            report["secureGuardPassed"] = secure
            report["foregroundMAX"] = foreground
            report["ordinarySourceUnchanged"] = ordinary
            return (automatic?.valid() ?? true) && generation == epoch && !request.deadline.expired(at: ProcessInfo.processInfo.systemUptime) &&
                !callback.expired(at: ProcessInfo.processInfo.systemUptime) && secure && foreground && ordinary
        }
        func complete(_ stage: String) {
            guard generation == epoch else { return }
            report["callbackMilliseconds"] = max(0, (ProcessInfo.processInfo.systemUptime - callbackStartedAt) * 1000)
            // The aggregate outcome is recorded again after dispatch returns.
            // Preserve the callback refusal separately, without retaining text.
            var callbackReport = report
            callbackReport["stage"] = stage
            DiagnosticReports.shared.record("NativeSelectionCallbackReport", callbackReport)
            finish(stage, report: report)
            if let automatic {
                automatic.state.published(stage == "responsePublished")
                automatic.word?.didPublish(stage == "responsePublished")
                if let outcome = automatic.state.completed { finishAutomatic(outcome) }
            }
        }
        guard ready() else { complete("contextRejected"); return }
        let name = pasteboard.name
        report["nonGeneralBoard"] = name != .general
        guard ![NSPasteboard.Name.general, .find, .font, .ruler, .drag].contains(name) else {
            complete("standardBoardRejected"); return
        }
        guard pasteboard.availableType(from: [.string]) == .string,
              let text = pasteboard.string(forType: .string) else { complete("stringUnavailable"); return }
        report["hasString"] = true
        guard NativeServicePayload.accepts(text) else { complete("payloadRejected"); return }
        if let word = automatic?.word, !word.permitsCommit(text) {
            automatic?.failure = "Редактор не подтвердил точное слово перед заменой"
            complete("wordScopeRejected"); return
        }
        guard ready() else { complete("contextChanged"); return }
        let prepareStartedAt = ProcessInfo.processInfo.systemUptime
        let prepared: InputSources.Conversion?
        if let word = automatic?.word { prepared = word.prepareCommit(text) }
        else { prepared = InputSources.prepare(text) }
        report["prepareMilliseconds"] = max(0, (ProcessInfo.processInfo.systemUptime - prepareStartedAt) * 1000)
        guard let conversion = prepared else { complete("mappingUnavailable"); return }
        guard NativeServicePayload.accepts(conversion.text) else { complete("responseRejected"); return }
        guard !text.utf16.elementsEqual(conversion.text.utf16) else { complete("unchangedText"); return }
        guard ready() else { complete("contextChanged"); return }
        // One private response transaction, removing stale rich formats. No
        // retry, fallback or ordinary source selection after either operation.
        let publishStartedAt = ProcessInfo.processInfo.systemUptime
        pasteboard.declareTypes([.string], owner: nil)
        guard ready() else {
            report["privatePublishMilliseconds"] = max(0, (ProcessInfo.processInfo.systemUptime - publishStartedAt) * 1000)
            complete("responseDeclarationCancelled"); return
        }
        let published = pasteboard.setString(conversion.text, forType: .string)
        report["privatePublishMilliseconds"] = max(0, (ProcessInfo.processInfo.systemUptime - publishStartedAt) * 1000)
        guard generation == epoch else { return }
        report["responsePublished"] = published
        guard published else { complete("responsePublishFailed"); return }
        guard ready() else { complete("responsePublishedUnverified"); return }
        automatic?.target = conversion.target
        error.pointee = nil
        complete("responsePublished")
    }

    private func foregroundMatches(_ identity: WindowIdentity) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        return app.bundleIdentifier == "ru.oneme.desktop" && app.processIdentifier == identity.pid && !app.isTerminated
    }

    private func ordinarySourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              InputMethodIdentity.string(kTISPropertyInputSourceType, of: source) == kTISTypeKeyboardLayout as String,
              InputMethodIdentity.boolean(kTISPropertyInputSourceIsEnabled, of: source),
              InputMethodIdentity.boolean(kTISPropertyInputSourceIsSelectCapable, of: source),
              let id = InputMethodIdentity.string(kTISPropertyInputSourceID, of: source), !id.isEmpty else { return nil }
        return id
    }

    /// Remote AX for the gesture start and before each key batch, never from
    /// a Services handler while the host waits for us.
    private func captureWindow(armDeadline: ReadinessDeadline) -> (identity: WindowIdentity?, reason: String, error: AXError?) {
        let now = ProcessInfo.processInfo.systemUptime
        let deadline = ReadinessDeadline(start: now, timeout: max(0, min(0.36, armDeadline.expiresAt - now)))
        guard AXIsProcessTrusted() else { return (nil, "permission", nil) }
        guard !IsSecureEventInputEnabled() else { return (nil, "secure", nil) }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "ru.oneme.desktop",
              !app.isTerminated else { return (nil, "foreground", nil) }
        guard let sourceID = ordinarySourceID() else { return (nil, "ordinarySource", nil) }
        guard !deadline.expired(at: ProcessInfo.processInfo.systemUptime) else { return (nil, "expired", nil) }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let applicationTimeout = AXUIElementSetMessagingTimeout(application, Float(min(0.12, deadline.expiresAt - ProcessInfo.processInfo.systemUptime)))
        guard applicationTimeout == .success else { return (nil, "axWindow", applicationTimeout) }
        guard !deadline.expired(at: ProcessInfo.processInfo.systemUptime) else { return (nil, "expired", nil) }
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &raw)
        guard !deadline.expired(at: ProcessInfo.processInfo.systemUptime) else { return (nil, "expired", nil) }
        let reply = AccessibilityElementReply(error: result, value: raw)
        guard let window = reply.element else { return (nil, "axWindow", reply.error) }
        var pid: pid_t = 0
        let ownerResult = AXUIElementGetPid(window, &pid)
        guard ownerResult == .success else { return (nil, "axWindow", ownerResult) }
        guard pid == app.processIdentifier else { return (nil, "axWindow", nil) }
        guard !deadline.expired(at: ProcessInfo.processInfo.systemUptime) else { return (nil, "expired", nil) }
        let windowTimeout = AXUIElementSetMessagingTimeout(window, Float(min(0.12, deadline.expiresAt - ProcessInfo.processInfo.systemUptime)))
        guard windowTimeout == .success else { return (nil, "axWindow", windowTimeout) }
        guard !deadline.expired(at: ProcessInfo.processInfo.systemUptime) else { return (nil, "expired", nil) }
        var role: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
        guard !deadline.expired(at: ProcessInfo.processInfo.systemUptime) else { return (nil, "expired", nil) }
        guard roleResult == .success else { return (nil, "axWindow", roleResult) }
        guard (AccessibilityValue.usable(role) as? String) == kAXWindowRole else { return (nil, "axWindow", nil) }
        guard !IsSecureEventInputEnabled() else { return (nil, "secure", nil) }
        let identity = WindowIdentity(pid: pid, window: window, sourceID: sourceID)
        guard foregroundMatches(identity) else { return (nil, "foreground", nil) }
        guard ordinarySourceID() == sourceID else { return (nil, "ordinarySource", nil) }
        return (identity, "available", nil)
    }

    private func finish(_ stage: String, report: [String: Any]) {
        var report = report
        report["stage"] = stage
        record(report)
        if stage == "responsePublished" {
            status = "Служба MAX: ответ передан; замена редактором ещё не подтверждена"
        } else if stage == "responsePublishedUnverified" {
            status = "Служба MAX: пакет записан, возврат отменён; результат не подтверждён"
        } else {
            status = "Служба MAX: ответ не передан, попытка завершена"
        }
    }

    private func record(_ report: [String: Any]) {
        DiagnosticReports.shared.record("NativeSelectionServiceReport", report, includeVersion: true)
    }

    private func expire(after delay: Double, epoch: Int) {
        guard generation == epoch else { return }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == epoch, let automatic = self.automatic else { return }
            self.finishAutomatic(automatic.state.stopped(cancelled: false))
        }
        expiry = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timeout)
    }

    deinit { expiry?.cancel() }
}
