import AppKit
import SwitcherCore

enum SingleInstance {
    static func claim() -> ApplicationInstanceLock? {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tonydanzza.SSwitcher"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(bundleID).instance.lock")
        guard let claim = ApplicationInstanceLock.acquire(at: path) else { return nil }

        // Existing versions did not hold a lease. Refuse a finished incumbent
        // before creating UI or a tap. A launch contender has not finished yet;
        // new contenders are serialized by the lease above. Prohibited fixture
        // helpers share the signed identity but do not own the production tap.
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let incumbent = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains {
            $0.processIdentifier != currentPID && !$0.isTerminated && $0.isFinishedLaunching && $0.activationPolicy != .prohibited
        }
        return incumbent ? nil : claim
    }
}
