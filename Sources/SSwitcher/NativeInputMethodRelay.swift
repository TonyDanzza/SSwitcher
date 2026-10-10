import AppKit
import InputMethodSupport

/// Relays a gesture, not text, into the selected IMK session. The receiver must
/// independently prove its active client; this notification is not focus proof.
final class NativeInputMethodRelay {
    var onResult: ((InputMethodIdentity.Reason) -> Void)?
    private var observer: NSObjectProtocol?
    private var pending: (id: String, mode: InputMethodIdentity.Mode, deadline: Double)?
    private var timeout: DispatchWorkItem?
    var hasPending: Bool { pending != nil }

    init() {
        observer = DistributedNotificationCenter.default().addObserver(forName: InputMethodIdentity.resultName, object: InputMethodIdentity.bundleID, queue: .main) { [weak self] note in
            guard let self, let pending = self.pending,
                  note.userInfo?["requestID"] as? String == pending.id,
                  InputMethodIdentity.currentMode == pending.mode else { return }
            self.consumeResult(transition: nil)
        }
    }

    /// Must run before monitor.focusChanged(), whose callback cancels pending.
    @discardableResult
    func consumeConfirmedTransition(from previous: InputMethodIdentity.Mode?, to next: InputMethodIdentity.Mode?) -> Bool {
        guard let previous, let next, previous != next else { return false }
        return consumeResult(transition: (previous, next))
    }

    @discardableResult
    private func consumeResult(transition: (InputMethodIdentity.Mode, InputMethodIdentity.Mode)?) -> Bool {
        guard let pending, ProcessInfo.processInfo.systemUptime <= pending.deadline,
              let report = InputMethodIdentity.preference(InputMethodIdentity.reportKey, domain: InputMethodIdentity.bundleID) as? [String: Any],
              report["requestID"] as? String == pending.id, report["mode"] as? String == pending.mode.rawValue,
              let rawReason = report["reason"] as? String, let reason = InputMethodIdentity.Reason(rawValue: rawReason) else { return false }
        if let (previous, next) = transition {
            guard previous == pending.mode, InputMethodIdentity.currentMode == next, reason == .converted,
                  report["result"] as? String == "converted", report["targetMode"] as? String == next.rawValue else { return false }
        } else {
            guard InputMethodIdentity.currentMode == pending.mode else { return false }
        }
        guard ProcessInfo.processInfo.systemUptime <= pending.deadline else { return false }
        timeout?.cancel(); timeout = nil; self.pending = nil
        UserDefaults.standard.set(pending.id, forKey: InputMethodIdentity.responseIDKey)
        CFPreferencesAppSynchronize(InputMethodIdentity.utilityBundleID as CFString)
        onResult?(reason)
        return true
    }

    @discardableResult
    func request(mode: InputMethodIdentity.Mode, releaseTime: Double) -> Bool {
        guard pending == nil, InputMethodIdentity.currentMode == mode, !InputMethodIdentity.isPaused else { return false }
        timeout?.cancel()
        let id = UUID().uuidString
        // Delivery time never extends native admission/pre-write deadlines.
        let deadline = releaseTime + InputMethodIdentity.resultLifetime
        pending = (id, mode, deadline)
        UserDefaults.standard.set(id, forKey: InputMethodIdentity.requestIDKey)
        UserDefaults.standard.removeObject(forKey: InputMethodIdentity.responseIDKey)
        CFPreferencesAppSynchronize(InputMethodIdentity.utilityBundleID as CFString)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pending?.id == id else { return }
            self.pending = nil; self.timeout = nil
            // A missing response cannot prove that insertText was not issued.
            self.onResult?(.unverified)
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
        DistributedNotificationCenter.default().postNotificationName(InputMethodIdentity.requestName,
            object: InputMethodIdentity.utilityBundleID,
            userInfo: ["requestID": id, "uptime": releaseTime, "mode": mode.rawValue], deliverImmediately: true)
        return true
    }

    func reset(intervention: Bool = false) {
        invalidatePending()
        DistributedNotificationCenter.default().postNotificationName(InputMethodIdentity.resetName,
            object: InputMethodIdentity.utilityBundleID, userInfo: ["intervention": intervention], deliverImmediately: true)
    }

    /// Local bookkeeping is safe in the existing listen-only callback.
    func invalidatePending() {
        timeout?.cancel(); timeout = nil; pending = nil
    }

    func preferenceChanged() {
        CFPreferencesAppSynchronize(InputMethodIdentity.utilityBundleID as CFString)
        DistributedNotificationCenter.default().postNotificationName(InputMethodIdentity.preferenceName,
            object: InputMethodIdentity.utilityBundleID, userInfo: nil, deliverImmediately: true)
    }

    deinit {
        timeout?.cancel()
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}
