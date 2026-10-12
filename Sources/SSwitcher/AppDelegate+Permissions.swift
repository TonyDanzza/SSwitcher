import AppKit

// MARK: Permissions

extension AppDelegate {
    /// Only retry while permissions/startup are missing, for at most 30 seconds.
    /// Menu/app activation/open are recovery points after that bounded window.
    func refreshPermissions(startRetry: Bool = true) {
        guard enabled || windowMovementEnabled else {
            if monitor.isRunning { monitor.stop() }
            refreshWindowShortcuts()
            permissionTimer?.invalidate(); permissionTimer = nil
            return
        }
        if CGPreflightListenEventAccess() { if !monitor.isRunning { monitor.start() } }
        else if monitor.isRunning { monitor.stop() }
        refreshWindowShortcuts()
        if monitor.isRunning && AXIsProcessTrusted() {
            permissionTimer?.invalidate(); permissionTimer = nil; permissionRetries = 0
        } else if startRetry && permissionTimer == nil {
            permissionRetries = 0
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.permissionRetries += 1
                self.refreshPermissions(startRetry: false)
                if self.permissionRetries >= 15 { timer.invalidate(); self.permissionTimer = nil }
            }
            permissionTimer?.tolerance = 0.5
        }
    }

    @objc func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshPermissions()
        rebuildMenu()
    }

    @objc func requestPermission() {
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        if !monitor.start(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        refreshPermissions()
        rebuildMenu()
    }

    func requestScreenCapture() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !CGPreflightScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        rebuildMenu()
    }
}
