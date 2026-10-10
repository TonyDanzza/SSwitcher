import AppKit
import Carbon
import InputMethodKit
import InputMethodSupport
import SwitcherCore
import os

/// Own-mode lifecycle and request admission. A separate one-shot transaction
/// owns replacement proof; ordinary typing passes to the client.
@objc(SSwitcherInputController)
final class SSwitcherInputController: IMKInputController {
    private typealias Client = NativeInputClient
    private static let lifecycleLogger = Logger(subsystem: InputMethodIdentity.bundleID, category: "Lifecycle")
    private enum LifecycleStage: String {
        case activation, modeReceived, deactivation, keyboardPreparation, requestReceived, requestAdmitted, requestRefused, result
    }
    private enum ModeCategory: String {
        case ownEnglish, ownRussian, password, genericRoman, unsupportedString, nonString

        init(_ value: String?) {
            guard let value else { self = .nonString; return }
            if value == InputMethodIdentity.Mode.english.rawValue { self = .ownEnglish }
            else if value == InputMethodIdentity.Mode.russian.rawValue { self = .ownRussian }
            else if value == kTextServiceInputModePassword as String { self = .password }
            else if value == kTextServiceInputModeRoman as String { self = .genericRoman }
            else { self = .unsupportedString }
        }
    }
    // Diagnostic-only category of the last explicit mode setter; never a grant.
    private var receivedModeCategory: ModeCategory = .nonString
    private var active = false
    private var mode: InputMethodIdentity.Mode?
    private var sessionClient: Client?
    private enum ReadGrant {
        case denied(InputMethodIdentity.Reason)
        case own(InputMethodIdentity.Mode)
    }
    private var readGrant: ReadGrant = .denied(.modeUnconfirmed)
    private var grantClient: Client?
    private var keyboardID: String?
    private var epoch: UInt64 = 0
    private var epochStarted = ProcessInfo.processInfo.systemUptime
    private var seenRequests: [UUID: Double] = [:]
    private var observers: [NSObjectProtocol] = []
    private var transaction: NativeConversionTransaction?
    private var mutationGate = NativeMutationGate()
    private var lastReason: InputMethodIdentity.Reason = .waiting

    private var readDenial: InputMethodIdentity.Reason {
        if case .denied(let reason) = readGrant { return reason }
        return .modeUnconfirmed
    }

    private func logLifecycle(_ stage: LifecycleStage, reason: String = "none", clientMatches: Bool? = nil) {
        let grantRecorded: Bool
        if case .own = readGrant { grantRecorded = true } else { grantRecorded = false }
        let cachedModeCategory = ModeCategory(mode?.rawValue)
        let receivedCategory = receivedModeCategory
        let isActive = active
        // All strings are fixed enums/literals. No extra client/source queries.
        Self.lifecycleLogger.notice("stage=\(stage.rawValue, privacy: .public) cachedMode=\(cachedModeCategory.rawValue, privacy: .public) receivedMode=\(receivedCategory.rawValue, privacy: .public) active=\(isActive) clientMatchKnown=\(clientMatches != nil) clientMatches=\(clientMatches ?? false) grantRecorded=\(grantRecorded) reason=\(reason, privacy: .public)")
    }

    private func grantAllows(_ mode: InputMethodIdentity.Mode, client: Client) -> Bool {
        guard case .own(let grantedMode) = readGrant else { return false }
        return grantedMode == mode && grantClient === client
    }

    private func revokeReadGrant(_ reason: InputMethodIdentity.Reason) {
        readGrant = .denied(reason)
        grantClient = nil
        keyboardID = nil
    }

    private func resetMenuStatus() {
        if case .denied(let reason) = readGrant { lastReason = reason }
        else { lastReason = .waiting }
    }

    private func resetEpoch() {
        epoch &+= 1
        epochStarted = ProcessInfo.processInfo.systemUptime
        seenRequests.removeAll()
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: InputMethodIdentity.requestName, object: InputMethodIdentity.utilityBundleID, queue: .main) { [weak self] note in self?.convertRequest(note) })
        for name in [InputMethodIdentity.resetName, InputMethodIdentity.preferenceName] {
            observers.append(center.addObserver(forName: name, object: InputMethodIdentity.utilityBundleID, queue: .main) { [weak self] note in
                guard let self else { return }
                if name == InputMethodIdentity.resetName, note.userInfo?["intervention"] as? Bool == true { self.mutationGate.realIntervention() }
                self.resetEpoch()
            })
        }
        observers.append(center.addObserver(forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.resetEpoch()
            self.mode = InputMethodIdentity.currentMode
            self.keyboardID = nil
            // TIS source identity cannot grant reading or clear a restriction.
            self.resetMenuStatus()
            self.configureKeyboard()
        })
    }

    override func activateServer(_ sender: Any!) {
        guard Thread.isMainThread else { return }
        active = false; sessionClient = nil; keyboardID = nil
        resetEpoch()
        installObservers()
        guard let sender = sender as? Client, let current = client(), sender === current else {
            revokeReadGrant(readDenial)
            resetMenuStatus()
            logLifecycle(.activation, reason: "clientNotMatched")
            return
        }
        // IMK can set the mode before activation. Preserve that grant only
        // for precisely the same proxy; activation itself never grants it.
        if grantClient !== sender { revokeReadGrant(readDenial) }
        sessionClient = sender
        mode = InputMethodIdentity.currentMode
        active = true
        logLifecycle(.activation, clientMatches: true)
        configureKeyboard()
        resetMenuStatus()
    }

    override func deactivateServer(_ sender: Any!) {
        active = false; sessionClient = nil; keyboardID = nil
        mutationGate.realIntervention()
        revokeReadGrant(readDenial)
        resetEpoch()
        logLifecycle(.deactivation)
    }

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        guard tag == Int(kTextServiceInputModePropertyTag) else { return }
        let rawMode = value as? String
        receivedModeCategory = ModeCategory(rawMode)
        let requestedMode = rawMode.flatMap(InputMethodIdentity.Mode.init(rawValue:))
        let denial: InputMethodIdentity.Reason = rawMode == kTextServiceInputModePassword as String
            ? .passwordMode : (requestedMode == nil ? .restrictedMode : .modeUnconfirmed)
        resetEpoch()
        // Revoke before asking even for the stored client proxy. Unsupported
        // and non-string modes must never retain an earlier own-mode grant.
        revokeReadGrant(denial)
        resetMenuStatus()
        guard let sender = sender as? Client, let current = client(), sender === current else {
            logLifecycle(.modeReceived, reason: "clientNotMatched")
            return
        }
        if active {
            guard let sessionClient, sender === sessionClient else {
                logLifecycle(.modeReceived, reason: "sessionNotMatched", clientMatches: true)
                return
            }
        }
        guard let requestedMode else {
            logLifecycle(.modeReceived, reason: denial.rawValue, clientMatches: true)
            return
        }
        grantClient = sender
        readGrant = .own(requestedMode)
        mode = requestedMode
        logLifecycle(.modeReceived, clientMatches: true)
        configureKeyboard()
        resetMenuStatus()
    }

    override func value(forTag tag: Int, client sender: Any!) -> Any! {
        guard tag == Int(kTextServiceInputModePropertyTag), case .own(let grantedMode) = readGrant,
              let sender = sender as? Client, let current = client(), sender === current,
              grantClient === sender else { return nil }
        return grantedMode.rawValue
    }

    override func modes(_ sender: Any!) -> [AnyHashable: Any]! {
        Bundle.main.object(forInfoDictionaryKey: "ComponentInputModeDict") as? [AnyHashable: Any]
    }

    private func configureKeyboard(deadline: Double? = nil) {
        var outcome = "configurationUnavailable"
        var clientMatches: Bool?
        defer { logLifecycle(.keyboardPreparation, reason: outcome, clientMatches: clientMatches) }
        func withinDeadline() -> Bool {
            deadline.map { ProcessInfo.processInfo.systemUptime <= $0 } ?? true
        }
        guard withinDeadline() else { outcome = "timedOut"; return }
        guard active else { outcome = "inactive"; return }
        guard let mode else { outcome = "modeAbsent"; return }
        guard let sessionClient else { outcome = "sessionAbsent"; return }
        guard grantAllows(mode, client: sessionClient) else { outcome = readDenial.rawValue; return }
        guard InputMethodIdentity.currentMode == mode else { outcome = "sourceMismatch"; return }
        guard client() === sessionClient else { outcome = "clientNotMatched"; clientMatches = false; return }
        clientMatches = true
        guard !IsSecureEventInputEnabled() else { outcome = "secureInput"; return }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let frontmostBundle = frontmost.bundleIdentifier else { outcome = "foregroundUnavailable"; return }
        let generation = epoch
        guard withinDeadline() else { outcome = "timedOut"; return }
        guard let clientBundle = sessionClient.bundleIdentifier(), !clientBundle.isEmpty else { outcome = "clientBundleUnavailable"; return }
        guard clientBundle == frontmostBundle else { outcome = "foregroundMismatch"; return }
        guard withinDeadline() else { outcome = "timedOut"; return }
        guard let id = InputMethodIdentity.systemKeyboardID(for: mode) else { outcome = "systemKeyboardUnavailable"; return }
        func unchanged() -> Bool {
            active && epoch == generation && self.mode == mode && grantAllows(mode, client: sessionClient) &&
                self.sessionClient === sessionClient && InputMethodIdentity.currentMode == mode && client() === sessionClient &&
                !IsSecureEventInputEnabled() && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost.processIdentifier
        }
        func readyForOverride() -> Bool {
            guard withinDeadline() else { outcome = "timedOut"; return false }
            guard unchanged() else { outcome = "sessionChanged"; return false }
            guard withinDeadline() else { outcome = "timedOut"; return false }
            return true
        }
        guard readyForOverride() else { return }
        let currentOverride = TISCopyInputMethodKeyboardLayoutOverride()?.takeRetainedValue()
        guard readyForOverride() else { return }
        if currentOverride.flatMap({ InputMethodIdentity.string(kTISPropertyInputSourceID, of: $0) }) != id {
            sessionClient.overrideKeyboard(withKeyboardNamed: id)
        }
        guard readyForOverride() else { return }
        keyboardID = id
        outcome = "configured"
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.union(.keyUp).union(.flagsChanged)
            .union(.leftMouseDown).union(.rightMouseDown).union(.otherMouseDown).union(.scrollWheel).rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        let unrelatedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .function]
        let bareShift = event.type == .flagsChanged && (event.keyCode == 56 || event.keyCode == 60) && event.modifierFlags.intersection(unrelatedModifiers).isEmpty
        if !bareShift { mutationGate.realIntervention(); resetEpoch() }
        return false
    }

    override func commitComposition(_ sender: Any!) { resetEpoch() }

    override func inputControllerWillClose() {
        active = false; sessionClient = nil; keyboardID = nil
        mutationGate.realIntervention()
        revokeReadGrant(readDenial)
        resetEpoch()
        logLifecycle(.deactivation, reason: "closed")
        removeObservers()
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu()
        let item = NSMenuItem(title: lastReason.message, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        let scope = NSMenuItem(title: "Двойной Shift: выделение или слово при курсоре в его конце", action: nil, keyEquivalent: "")
        scope.isEnabled = false
        menu.addItem(scope)
        return menu
    }

    private func convertRequest(_ note: Notification) {
        guard Thread.isMainThread else {
            Self.lifecycleLogger.notice("stage=requestReceived reason=offMain")
            Self.lifecycleLogger.notice("stage=requestRefused reason=offMain")
            return
        }
        logLifecycle(.requestReceived)
        guard transaction == nil else { logLifecycle(.requestRefused, reason: "busy"); return }
        guard active else { logLifecycle(.requestRefused, reason: "inactive"); return }
        guard let mode else { logLifecycle(.requestRefused, reason: "modeAbsent"); return }
        guard InputMethodIdentity.currentMode == mode else { logLifecycle(.requestRefused, reason: "sourceMismatch"); return }
        guard note.userInfo?["mode"] as? String == mode.rawValue else { logLifecycle(.requestRefused, reason: "requestModeMismatch"); return }
        guard let rawID = note.userInfo?["requestID"] as? String, let id = UUID(uuidString: rawID) else {
            logLifecycle(.requestRefused, reason: "invalidRequestID"); return
        }
        guard let uptime = note.userInfo?["uptime"] as? Double, uptime.isFinite else {
            logLifecycle(.requestRefused, reason: "invalidRequestTime"); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard uptime >= epochStarted else { logLifecycle(.requestRefused, reason: "beforeEpoch"); return }
        guard uptime <= now else { logLifecycle(.requestRefused, reason: "futureRequest"); return }
        guard now - uptime <= InputMethodIdentity.requestLifetime else { logLifecycle(.requestRefused, reason: "expiredRequest"); return }
        seenRequests = seenRequests.filter { now - $0.value <= InputMethodIdentity.requestLifetime }
        guard seenRequests[id] == nil else { logLifecycle(.requestRefused, reason: "duplicateRequest"); return }
        if seenRequests.count >= 16, let oldest = seenRequests.min(by: { $0.value < $1.value })?.key { seenRequests.removeValue(forKey: oldest) }
        seenRequests[id] = uptime
        func refuse(_ reason: InputMethodIdentity.Reason) {
            logLifecycle(.requestRefused, reason: reason.rawValue)
            record(reason, mode: mode, targetMode: nil, clientBundleID: nil, requestID: rawID, capabilities: [:])
        }
        // A denied request still answers its matching UUID/original mode, with no
        // client metadata, capability, range, string or keyboard calls.
        guard let input = sessionClient, grantAllows(mode, client: input) else { refuse(readDenial); return }
        guard mutationGate.state != .blocked else { refuse(.unverified); return }
        guard !IsSecureEventInputEnabled() else { refuse(.secureInput); return }
        guard !InputMethodIdentity.isPaused else { refuse(.paused); return }
        guard let current = client(), input === current,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              let foregroundBundle = frontmost.bundleIdentifier, !foregroundBundle.isEmpty else { refuse(.inactiveSession); return }
        // Activation can precede the client's foreground transition. Prepare
        // a missing keyboard only after this request has passed the same live
        // grant/security/client checks, using the transaction's fixed budget.
        let generation = epoch
        let preparationDeadline = min(now + InputMethodIdentity.readBudget, uptime + InputMethodIdentity.requestLifetime)
        guard ProcessInfo.processInfo.systemUptime <= preparationDeadline else { refuse(.timedOut); return }
        if keyboardID == nil { configureKeyboard(deadline: preparationDeadline) }
        guard ProcessInfo.processInfo.systemUptime <= preparationDeadline else { refuse(.timedOut); return }
        guard active, epoch == generation, self.mode == mode, grantAllows(mode, client: input),
              InputMethodIdentity.currentMode == mode, sessionClient === input, client() === input,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost.processIdentifier,
              !IsSecureEventInputEnabled(), !InputMethodIdentity.isPaused else { refuse(.sessionChanged); return }
        guard ProcessInfo.processInfo.systemUptime <= preparationDeadline else { refuse(.timedOut); return }
        guard let keyboardID else { refuse(.keyboardUnavailable); return }
        guard mutationGate.begin() else { refuse(.unverified); return }
        logLifecycle(.requestAdmitted, clientMatches: true)
        let authority: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.active && self.epoch == generation && self.mode == mode && self.grantAllows(mode, client: input) &&
                InputMethodIdentity.currentMode == mode && self.sessionClient === input && self.client() === input && self.keyboardID == keyboardID &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost.processIdentifier &&
                !IsSecureEventInputEnabled() && !InputMethodIdentity.isPaused
        }
        let job = NativeConversionTransaction(input: input, mode: mode, keyboardID: keyboardID,
            foregroundBundleID: foregroundBundle, gestureTime: uptime, startedAt: now, authority: authority,
            willWrite: { [weak self] in self?.mutationGate.willWrite() },
            completion: { [weak self] reason, target, bundleID, capabilities in
                guard let self else { return }
                self.mutationGate.finish(confirmed: reason == .converted)
                self.transaction = nil
                // Persist/notify the original-mode result before any own-mode
                // transition; utility can consume only this completed UUID.
                self.record(reason, mode: mode, targetMode: target, clientBundleID: bundleID, requestID: rawID, capabilities: capabilities)
                guard reason == .converted, let target, target != mode, authority(),
                      ProcessInfo.processInfo.systemUptime <= uptime + InputMethodIdentity.requestLifetime + InputMethodIdentity.acknowledgementBudget else { return }
                let currentOverride = TISCopyInputMethodKeyboardLayoutOverride()?.takeRetainedValue()
                guard authority(), let currentOverride, InputMethodIdentity.string(kTISPropertyInputSourceID, of: currentOverride) == keyboardID,
                      ProcessInfo.processInfo.systemUptime <= uptime + InputMethodIdentity.requestLifetime + InputMethodIdentity.acknowledgementBudget else { return }
                input.selectMode(target.rawValue)
            })
        transaction = job
        job.start()
    }

    private func record(_ reason: InputMethodIdentity.Reason, mode: InputMethodIdentity.Mode?, targetMode: InputMethodIdentity.Mode?, clientBundleID: String?, requestID: String?, capabilities: [String: Any]) {
        lastReason = reason
        logLifecycle(.result, reason: reason.rawValue)
        var report = capabilities
        report["result"] = reason == .converted ? "converted" : (reason == .unverified ? "unverified" : "unsupported")
        report["reason"] = reason.rawValue
        report["timestamp"] = Date().timeIntervalSince1970
        report["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        report["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if let mode { report["mode"] = mode.rawValue }
        if let targetMode { report["targetMode"] = targetMode.rawValue }
        if let clientBundleID { report["clientBundleID"] = clientBundleID }
        if let requestID { report["requestID"] = requestID }
        UserDefaults.standard.set(report, forKey: InputMethodIdentity.reportKey)
        CFPreferencesAppSynchronize(InputMethodIdentity.bundleID as CFString)
        if let requestID {
            DistributedNotificationCenter.default().postNotificationName(InputMethodIdentity.resultName,
                object: InputMethodIdentity.bundleID, userInfo: ["requestID": requestID], deliverImmediately: true)
        }
    }

    private func removeObservers() {
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers.removeAll()
    }

    deinit { removeObservers() }
}
