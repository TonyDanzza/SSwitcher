import Foundation

/// Text-free diagnostic reports, read with `defaults read com.tonydanzza.SSwitcher`.
/// Reports are kept in memory and written to UserDefaults together, at most
/// once per second, so no write happens inside a Services callback or the
/// keyboard tap. Nothing is scheduled while there is nothing to write.
final class DiagnosticReports {
    static let shared = DiagnosticReports()
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    static let flushDelay = 1.0

    /// Reports written by earlier builds that no current code updates.
    private static let obsoleteKeys = [
        "MaxFocusDiagnosticReport", "NativeDiagnosticOwnedShiftCleanup", "NativeDiagnosticPointerFocus",
        "NativeEditableDispatchReport", "NativeEditableMenuReport", "NativeEditableServiceReport",
        "NativeExternalKeyReport", "NativeKeyboardBarrierReport", "NativeKeyboardEventProbeReport",
        "NativeKeyboardFocusReport", "NativeMAXNavigationReport", "NativeOwnedNavigationReport",
        "NativeServiceDiagnosticReport", "NativeServiceMenuReport", "NativeSyntheticKeyReport",
        "NativeWordActivationReport", "NativeWordDiagnosticArmReport", "NativeWordDiagnosticReport",
        "NativeWordMaskReport", "NativeWordNavigationReport", "NativeWordPacketContextReport",
        "NativeWordReadCapabilityReport", "NativeWordReadReport"
    ]

    private var pending: [String: [String: Any]?] = [:]
    private var flush: DispatchWorkItem?

    /// Stamps the build (and optionally the version) and replaces the report.
    func record(_ key: String, _ report: [String: Any], includeVersion: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        var value = report
        value["build"] = Self.build
        if includeVersion { value["version"] = Self.version }
        pending[key] = .some(value)
        scheduleFlush()
    }

    func remove(_ key: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        pending[key] = .some(nil)
        scheduleFlush()
    }

    func flushNow() {
        dispatchPrecondition(condition: .onQueue(.main))
        flush?.cancel(); flush = nil
        let changes = pending
        pending.removeAll()
        for (key, value) in changes {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    func removeObsoleteReports() {
        for key in Self.obsoleteKeys where UserDefaults.standard.object(forKey: key) != nil {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func scheduleFlush() {
        guard flush == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.flush = nil
            self?.flushNow()
        }
        flush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushDelay, execute: work)
    }
}
