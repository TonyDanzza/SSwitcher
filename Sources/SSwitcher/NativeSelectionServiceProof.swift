import AppKit
import Carbon
import InputMethodSupport
import SwitcherCore

/// Native selected-text and word Services paths plus explicitly armed diagnostics.
/// Window identity is captured
/// outside the service callback: the waiting host must never receive AX IPC.
/// Publishing a response is not acknowledgement of editor text or its caret.
final class NativeSelectionServiceProof {
    fileprivate struct WindowIdentity {
        let pid: pid_t
        let window: AXUIElement
        let sourceID: String
    }
    private final class Grant {
        let identity: WindowIdentity
        let deadline: ReadinessDeadline
        var editableProbeCount = 0
        var editableActionAccepted = false
        var keyboardProbeStarted = false
        var keyboardProbeFinished = false
        var keyboardDelivered: Bool?
        var keyboardDeadline: ReadinessDeadline?
        var keyboardExpiry: DispatchWorkItem?
        init(identity: WindowIdentity, deadline: ReadinessDeadline) {
            self.identity = identity
            self.deadline = deadline
        }
        deinit { keyboardExpiry?.cancel() }
    }
    struct Readback {
        fileprivate let text: String
        fileprivate let identity: WindowIdentity
        let deadline: ReadinessDeadline
        func matches(_ packet: String) -> Bool { text.utf16.elementsEqual(packet.utf16) }
    }
    private struct Expected {
        let text: String
        let identity: WindowIdentity
        let deadline = ReadinessDeadline(start: ProcessInfo.processInfo.systemUptime, timeout: 60)
    }
    private var grant: Grant?
    private var expected: Expected?
    private var expiry: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?
    private var waitingDeadline: ReadinessDeadline?
    private var readbackCompletion: ((Readback?, String?) -> Void)?
    private let menuWorker = DispatchQueue(label: "SSwitcher.native-service-menu", qos: .userInitiated)
    private var menuCancellation: AttemptCancellation?
    private var editableCancellation: AttemptCancellation?
    private var generation = 0
    private let visualShield = NativeWordVisualShield()
    private final class Automatic {
        let identity: WindowIdentity
        let valid: () -> Bool
        let completion: (NativeServiceDispatchState.Outcome, TISInputSource?) -> Void
        var state = NativeServiceDispatchState()
        var target: TISInputSource?
        var word: NativeWordServiceCoordinator?
        var failure: String?
        init(identity: WindowIdentity, valid: @escaping () -> Bool,
             completion: @escaping (NativeServiceDispatchState.Outcome, TISInputSource?) -> Void) {
            self.identity = identity; self.valid = valid; self.completion = completion
        }
    }
    private var automatic: Automatic?
    private(set) var status = "Служба выделения MAX: не запускалась"

    var hasExpectedResponse: Bool { expected != nil }
    var isConverting: Bool {
        automatic != nil || (grant?.keyboardProbeStarted == true && grant?.keyboardProbeFinished == false)
    }

    func convertAtCursor(valid: @escaping () -> Bool,
                         completion: @escaping (NativeServiceDispatchState.Outcome, TISInputSource?) -> Void) {
        guard Thread.isMainThread, automatic == nil else { completion(.cancelled, nil); return }
        cancel()
        let deadline = ReadinessDeadline(start: ProcessInfo.processInfo.systemUptime, timeout: ConversionTiming.nativeWordDeadline)
        let capture = captureWindow(armDeadline: deadline)
        guard valid(), let identity = capture.identity else { completion(.cancelled, nil); return }
        let request = Automatic(identity: identity, valid: valid, completion: completion)
        automatic = request
        grant = Grant(identity: identity, deadline: deadline)
        let epoch = generation
        record(["stage": "nativeResponderRequest", "automatic": true, "windowProvenAtArm": true])
        expire(after: max(0, deadline.expiresAt - ProcessInfo.processInfo.systemUptime), epoch: epoch)
        // Our static Services are registered at launch. Their actual callbacks
        // prove current capability; scanning cached menu leaves adds IPC but
        // no editor authority. Missing callbacks still fail at the deadline.
        startWord(request, deadline: deadline, epoch: epoch)
    }

    private func startWord(_ request: Automatic, deadline: ReadinessDeadline, epoch: Int) {
        let identity = request.identity
        func localReady() -> Bool {
            generation == epoch && automatic === request && request.valid() &&
                !deadline.expired(at: ProcessInfo.processInfo.systemUptime) && foregroundMatches(identity) &&
                ordinarySourceID() == identity.sourceID && !IsSecureEventInputEnabled()
        }
        guard localReady() else { finishAutomatic(.cancelled); return }
        let word = NativeWordServiceCoordinator(pid: identity.pid, window: identity.window,
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
                self.menuWorker.async { [weak self, weak request] in
                    guard let self, let request else { return }
                    let bounds = NativeServiceMenuResolver.windowBounds(identity.window, pid: identity.pid)
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

    func cancelAutomatic() {
        guard Thread.isMainThread else { return }
        guard let automatic else {
            if grant?.keyboardProbeStarted == true && grant?.keyboardProbeFinished == false { cancelArm() }
            return
        }
        finishAutomatic(automatic.state.stopped(cancelled: true))
    }

    private func finishAutomatic(_ outcome: NativeServiceDispatchState.Outcome) {
        guard let request = automatic else { return }
        let outcome = outcome == .submitted && (!request.valid() || !foregroundMatches(request.identity) ||
            ordinarySourceID() != request.identity.sourceID || IsSecureEventInputEnabled()) ? .unverified : outcome
        request.word?.cancel()
        automatic = nil
        grant = nil
        menuCancellation?.cancel(); menuCancellation = nil
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

    func arm() {
        guard Thread.isMainThread else { return }
        let deadline = ReadinessDeadline(start: ProcessInfo.processInfo.systemUptime, timeout: 60)
        cancel()
        beginWaiting(deadline: deadline)
        // Menu discovery is readonly and can inspect the named running MAX
        // while our diagnostic window is active. It grants no conversion.
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "ru.oneme.desktop")
            .filter { !$0.isTerminated }
        if applications.count == 1, let app = applications.first {
            inspectMenu(pid: app.processIdentifier, epoch: generation)
        }
    }

    func cancelArm() {
        guard Thread.isMainThread, grant != nil || waitingDeadline != nil else { return }
        let completion = readbackCompletion
        if grant?.keyboardProbeStarted == true && grant?.keyboardProbeFinished == false { KeyboardEvents.cancelDelivery() }
        if completion != nil { expected = nil }
        readbackCompletion = nil; waitingDeadline = nil
        grant = nil
        menuCancellation?.cancel(); menuCancellation = nil
        editableCancellation?.cancel(); editableCancellation = nil
        detachActivation()
        expiry?.cancel(); expiry = nil
        generation += 1
        status = "Служба выделения MAX: попытка отменена"
        record(["stage": "cancelled"])
        completion?(nil, "cancelled")
    }

    func cancel() {
        guard Thread.isMainThread else { return }
        cancelAutomatic()
        visualShield.cancel()
        let wasArmed = grant != nil || waitingDeadline != nil
        if grant?.keyboardProbeStarted == true && grant?.keyboardProbeFinished == false { KeyboardEvents.cancelDelivery() }
        let completion = readbackCompletion
        readbackCompletion = nil; waitingDeadline = nil
        grant = nil; expected = nil
        menuCancellation?.cancel(); menuCancellation = nil
        editableCancellation?.cancel(); editableCancellation = nil
        detachActivation()
        expiry?.cancel(); expiry = nil
        generation += 1
        if wasArmed {
            status = "Служба выделения MAX: попытка отменена"
            record(["stage": "cancelled", "callCount": 0])
        }
        completion?(nil, "cancelled")
    }

    /// Explicit readback arm, before MAX waits for the readonly provider.
    /// Keep one expectation until matching activation, cancellation or expiry;
    /// its original deadline is never extended.
    func takeReadback(completion: @escaping (Readback?, String?) -> Void) {
        guard Thread.isMainThread else { return }
        guard let deadline = expected?.deadline else { completion(nil, "expectedUnavailable"); return }
        expiry?.cancel(); expiry = nil
        generation += 1
        readbackCompletion = completion
        beginWaiting(deadline: deadline)
    }

    /// Only an explicit click installs this finite observer. Its closure keeps
    /// an epoch, never a payload; activation cannot extend either deadline.
    private func beginWaiting(deadline: ReadinessDeadline) {
        detachActivation()
        waitingDeadline = deadline
        let epoch = generation
        status = "Служба MAX: перейдите в MAX до окончания разрешения"
        record(["stage": "waitingForMAX", "reason": "foreground", "windowProvenAtArm": false])
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.prepareActivatedWindow(epoch: epoch) }
        expire(after: max(0, deadline.expiresAt - ProcessInfo.processInfo.systemUptime), epoch: epoch)
        prepareActivatedWindow(epoch: epoch)
    }

    private func prepareActivatedWindow(epoch: Int) {
        guard generation == epoch, let deadline = waitingDeadline else { return }
        if deadline.expired(at: ProcessInfo.processInfo.systemUptime) { rejectWaiting("expired"); return }
        if !AXIsProcessTrusted() { rejectWaiting("permission"); return }
        if IsSecureEventInputEnabled() { rejectWaiting("secure"); return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "ru.oneme.desktop" else { return }
        let capture = captureWindow(armDeadline: deadline)
        guard generation == epoch, waitingDeadline != nil else { return }
        guard let identity = capture.identity else { rejectWaiting(capture.reason, axError: capture.error); return }
        guard !deadline.expired(at: ProcessInfo.processInfo.systemUptime) else { rejectWaiting("expired"); return }
        detachActivation()
        waitingDeadline = nil
        if let completion = readbackCompletion {
            readbackCompletion = nil
            guard let response = expected, identity.pid == response.identity.pid,
                  identity.sourceID == response.identity.sourceID, CFEqual(identity.window, response.identity.window) else {
                expected = nil
                expiry?.cancel(); expiry = nil
                finish("readbackArmRejected", report: ["reason": "axWindow", "windowProvenAtArm": false])
                completion(nil, "axWindow"); return
            }
            expected = nil
            expiry?.cancel(); expiry = nil
            status = "Служба MAX: исходное окно для проверки подтверждено"
            completion(Readback(text: response.text, identity: response.identity, deadline: response.deadline), nil)
        } else {
            grant = Grant(identity: identity, deadline: deadline)
            status = "Служба MAX: одна замена выделения разрешена до окончания минуты"
            record(["stage": "armed", "windowProvenAtArm": true])
            if let grant { inspectEditableRequestor(grant, epoch: epoch) }
        }
    }

    /// Explicit diagnostic arm only. One zero-write service is invoked on the
    /// same native window immediately after real MAX activation. The provider
    /// always returns an error; discovery/dispatch are not text-edit authority.
    private func inspectEditableRequestor(_ request: Grant, epoch: Int) {
        let cancellation = AttemptCancellation()
        editableCancellation?.cancel()
        editableCancellation = cancellation
        let identity = request.identity
        menuWorker.async { [weak self] in
            let result = NativeServiceMenuResolver.inspect(pid: identity.pid, cancellation: cancellation,
                                                          serviceTitle: NativeServiceMenuResolver.editableTitle)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == epoch, self.grant === request,
                      !cancellation.isCancelled else { return }
                var report = result.report
                report["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
                UserDefaults.standard.set(report, forKey: "NativeEditableMenuReport")
                guard let item = result.item, !request.deadline.expired(at: ProcessInfo.processInfo.systemUptime),
                      self.foregroundMatches(identity), self.ordinarySourceID() == identity.sourceID,
                      !IsSecureEventInputEnabled() else { return }
                self.menuWorker.async { [weak self] in
                    let reply = NativeServiceMenuResolver.press(item, pid: identity.pid, window: identity.window,
                        cancellation: cancellation, serviceTitle: NativeServiceMenuResolver.editableTitle)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == epoch, self.grant === request,
                              !cancellation.isCancelled else { return }
                        var report: [String: Any] = ["actionIssued": reply != nil,
                                                    "actionAccepted": reply == .success,
                                                    "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""]
                        if let reply { report["AXError"] = reply.rawValue }
                        UserDefaults.standard.set(report, forKey: "NativeEditableDispatchReport")
                        request.editableActionAccepted = reply == .success
                        self.beginKeyboardProbeIfReady(request, epoch: epoch)
                    }
                }
            }
        }
    }

    private func beginKeyboardProbeIfReady(_ request: Grant, epoch: Int) {
        guard generation == epoch, grant === request, request.editableActionAccepted,
              request.editableProbeCount == 1, !request.keyboardProbeStarted,
              !request.deadline.expired(at: ProcessInfo.processInfo.systemUptime),
              foregroundMatches(request.identity), ordinarySourceID() == request.identity.sourceID,
              !IsSecureEventInputEnabled() else { return }
        // Run only after the initial service callback and its AX action have
        // both returned. There must be no AX IPC to a waiting Services host.
        let fresh = captureWindow(armDeadline: request.deadline)
        let system = AXUIElementCreateSystemWide()
        var focusedApplication: CFTypeRef?
        _ = AXUIElementSetMessagingTimeout(system, 0.12)
        let focusedResult = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focusedApplication)
        var focusedPID: pid_t = 0
        let focusedElement = AccessibilityElementReply(error: focusedResult, value: focusedApplication).element
        let systemFocusMatches = focusedElement.map { AXUIElementGetPid($0, &focusedPID) == .success && focusedPID == request.identity.pid } ?? false
        UserDefaults.standard.set(["systemFocusMatches": systemFocusMatches, "ownApplicationActive": NSApp.isActive,
                                  "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""],
                                 forKey: "NativeKeyboardFocusReport")
        guard let identity = fresh.identity, CFEqual(identity.window, request.identity.window),
              identity.pid == request.identity.pid, identity.sourceID == request.identity.sourceID,
              NativeServiceMenuResolver.isOnBuiltInDisplay(identity.window, pid: identity.pid),
              let events = NativeServiceBarrierEvents.probe(), foregroundMatches(request.identity),
              ordinarySourceID() == request.identity.sourceID, !IsSecureEventInputEnabled(),
              !request.deadline.expired(at: ProcessInfo.processInfo.systemUptime) else { return }
        request.keyboardProbeStarted = true
        let deadline = ReadinessDeadline(start: ProcessInfo.processInfo.systemUptime, timeout: 0.6)
        request.keyboardDeadline = deadline
        let timeout = DispatchWorkItem { [weak self, weak request] in
            guard let self, let request, self.generation == epoch, self.grant === request else { return }
            self.finishKeyboardProbe(request, timedOut: true)
        }
        request.keyboardExpiry = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: timeout)
        KeyboardEvents.postAndAwaitDelivery(events, postingTap: .cgSessionEventTap) { [weak self, weak request] delivered in
            guard let self, let request, self.generation == epoch, self.grant === request else { return }
            request.keyboardDelivered = delivered
            self.finishKeyboardProbe(request, timedOut: deadline.expired(at: ProcessInfo.processInfo.systemUptime))
        }
    }

    private func finishKeyboardProbe(_ request: Grant, timedOut: Bool) {
        guard !request.keyboardProbeFinished else { return }
        let nativeInvoked = request.editableProbeCount == 2
        let delivered = request.keyboardDelivered == true
        guard timedOut || request.keyboardDelivered == false || (delivered && nativeInvoked) else { return }
        request.keyboardProbeFinished = true
        request.keyboardExpiry?.cancel(); request.keyboardExpiry = nil
        let context = foregroundMatches(request.identity) && ordinarySourceID() == request.identity.sourceID &&
            !IsSecureEventInputEnabled()
        UserDefaults.standard.set([
            "stage": delivered && nativeInvoked && context && !timedOut ? "nativeKeyboardRequestConfirmed" : "unconfirmed",
            "eventDelivered": delivered, "nativeRequestorInvoked": nativeInvoked,
            "contextUnchanged": context, "timedOut": timedOut,
            "specialCharacterDelivered": KeyboardEvents.lastNavigationHasSpecialCharacter,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        ] as [String: Any], forKey: "NativeKeyboardBarrierReport")
    }

    private func inspectMenu(pid: pid_t, epoch: Int) {
        menuCancellation?.cancel()
        let cancellation = AttemptCancellation()
        menuCancellation = cancellation
        menuWorker.async { [weak self] in
            let result = NativeServiceMenuResolver.inspect(pid: pid, cancellation: cancellation, inspectEditor: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == epoch, !cancellation.isCancelled else { return }
                self.recordMenu(result.report)
            }
        }
    }

    private func recordMenu(_ report: [String: Any]) {
        var report = report
        report["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        UserDefaults.standard.set(report, forKey: "NativeServiceMenuReport")
    }

    private func rejectWaiting(_ reason: String, axError: AXError? = nil) {
        let completion = readbackCompletion
        readbackCompletion = nil; waitingDeadline = nil
        if completion != nil { expected = nil }
        detachActivation()
        expiry?.cancel(); expiry = nil
        var report: [String: Any] = ["reason": reason, "windowProvenAtArm": false, "callCount": 0]
        if let axError { report["AXError"] = axError.rawValue }
        finish(completion == nil ? "armRejected" : "readbackArmRejected", report: report)
        completion?(nil, reason)
    }

    private func detachActivation() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    func readbackContextMatches(_ readback: Readback) -> Bool {
        foregroundMatches(readback.identity) && ordinarySourceID() == readback.identity.sourceID &&
            !readback.deadline.expired(at: ProcessInfo.processInfo.systemUptime)
    }

    /// Return-only requestor diagnostic: AppKit can validate an editable native
    /// client even at an empty selection. Never return replacement data.
    func probeEditable(_ packet: NSPasteboard, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let error else { return }
        error.pointee = "SSwitcher: проверка ввода завершена, текст не изменён" as NSString
        if Thread.isMainThread, let request = automatic, request.word != nil, request.valid(),
           foregroundMatches(request.identity), ordinarySourceID() == request.identity.sourceID,
           !IsSecureEventInputEnabled(), ![NSPasteboard.Name.general, .find, .font, .ruler, .drag].contains(packet.name) {
            // A barrier is a successful zero-write request, not a diagnostic
            // error. Clear only this dedicated packet; never return an empty
            // string or let stale formats reinsert text in Qt.
            guard NativeServicePacket.discardReturnValue(packet) else { return }
            error.pointee = nil
            request.word?.receiveBarrier()
            return
        }
        guard Thread.isMainThread, automatic == nil, let request = grant, request.editableProbeCount < 2,
              !request.deadline.expired(at: ProcessInfo.processInfo.systemUptime) else { return }
        if request.editableProbeCount == 1 {
            guard request.keyboardProbeStarted, !request.keyboardProbeFinished, let deadline = request.keyboardDeadline,
                  !deadline.expired(at: ProcessInfo.processInfo.systemUptime) else { return }
        }
        let secure = !IsSecureEventInputEnabled()
        let foreground = foregroundMatches(request.identity)
        let ordinary = ordinarySourceID() == request.identity.sourceID
        let privateBoard = ![NSPasteboard.Name.general, .find, .font, .ruler, .drag].contains(packet.name)
        guard secure, foreground, ordinary, privateBoard else { return }
        request.editableProbeCount += 1
        UserDefaults.standard.set([
            "stage": "nativeRequestorInvoked", "callCount": request.editableProbeCount,
            "privateBoard": true, "secureGuardPassed": true, "foregroundMAX": true,
            "ordinarySourceUnchanged": true,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        ] as [String: Any], forKey: "NativeEditableServiceReport")
        if request.editableProbeCount == 1 {
            let epoch = generation
            DispatchQueue.main.async { [weak self, weak request] in
                guard let self, let request else { return }
                self.beginKeyboardProbeIfReady(request, epoch: epoch)
            }
        } else {
            finishKeyboardProbe(request, timedOut: false)
        }
    }

    /// The existing two-way native request performs the word replacement in
    /// its first callback only while our current gesture owns the commit.
    /// Diagnostics and boundary reads remain zero-write.
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
        UserDefaults.standard.set(["stage": "callbackReceived",
            "foregroundMAX": foregroundMatches(request.identity),
            "foregroundOwn": NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
            "providerActive": NSApp.isActive, "inputUnchanged": request.valid(),
            "hostActive": NSRunningApplication(processIdentifier: request.identity.pid)?.isActive == true,
            "menuOwnerMAX": NSWorkspace.shared.menuBarOwningApplication?.processIdentifier == request.identity.pid,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""],
            forKey: "NativeWordPacketReport")
        guard request.valid(), foregroundMatches(request.identity), ordinarySourceID() == request.identity.sourceID,
              !IsSecureEventInputEnabled(), ![NSPasteboard.Name.general, .find, .font, .ruler, .drag].contains(packet.name),
              packet.availableType(from: [.string]) == .string, let text = packet.string(forType: .string) else { return true }
        _ = word.receivePacket(text)
        return true
    }

    func convert(_ pasteboard: NSPasteboard, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let error else { return }
        error.pointee = "SSwitcher: замена выделения не выполнена" as NSString
        defer {
            if error.pointee != nil { NativeServicePacket.discardReturnValue(pasteboard) }
        }
        guard Thread.isMainThread, let request = grant else { return }
        grant = nil
        if automatic == nil {
            menuCancellation?.cancel(); menuCancellation = nil
            editableCancellation?.cancel(); editableCancellation = nil
        }
        if automatic == nil { expiry?.cancel(); expiry = nil }
        let epoch = generation
        let callbackStartedAt = ProcessInfo.processInfo.systemUptime
        let callback = ReadinessDeadline(start: callbackStartedAt, timeout: 0.6)
        var report: [String: Any] = ["callCount": 1, "hasErrorPointer": true, "windowProvenAtArm": true,
                                     "windowRevalidatedInCallback": false,
                                     "wordRequest": automatic?.word != nil]
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
            callbackReport["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            UserDefaults.standard.set(callbackReport, forKey: "NativeSelectionCallbackReport")
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
        if let automatic { automatic.target = conversion.target }
        else { expected = Expected(text: conversion.text, identity: request.identity) }
        error.pointee = nil
        complete("responsePublished")
        if automatic == nil { expire(after: 60, epoch: epoch) }
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

    /// The only remote AX entry in this component, called by explicit arm
    /// actions, never from a Services handler while the host waits for us.
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
        var report = report
        report["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        report["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        UserDefaults.standard.set(report, forKey: "NativeSelectionServiceReport")
    }

    private func expire(after delay: Double, epoch: Int) {
        guard generation == epoch else { return }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == epoch else { return }
            if let automatic = self.automatic {
                self.finishAutomatic(automatic.state.stopped(cancelled: false)); return
            }
            if self.waitingDeadline != nil { self.rejectWaiting("expired"); return }
            let wasArmed = self.grant != nil
            self.grant = nil; self.expected = nil; self.expiry = nil
            self.menuCancellation?.cancel(); self.menuCancellation = nil
            self.editableCancellation?.cancel(); self.editableCancellation = nil
            self.generation += 1
            self.status = "Служба MAX: время разрешения или проверки истекло"
            if wasArmed { self.record(["stage": "expired", "callCount": 0]) }
        }
        expiry = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timeout)
    }

    deinit {
        menuCancellation?.cancel()
        editableCancellation?.cancel()
        expiry?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
}
