import AppKit

struct EditorApplication {
    let pid: pid_t
    let name: String
    let bundleID: String
    let session: String
    let isElectron: Bool

    init(_ application: NSRunningApplication) {
        pid = application.processIdentifier
        name = application.localizedName ?? "Редактор"
        bundleID = application.bundleIdentifier ?? ""
        let bundle = application.bundleURL.flatMap(Bundle.init(url:))
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        session = "\(pid):\(application.launchDate?.timeIntervalSince1970 ?? 0):\(bundleID):\(version)"
        isElectron = application.bundleURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
    }
}

/// Figma's AX selection can describe a stale canvas mirror. Centralize the
/// exception: never use AX to set that canvas selection or confirm success.
struct EditorCompatibilityPolicy {
    let usesCanvasSelection: Bool
    init(application: EditorApplication) { usesCanvasSelection = application.bundleID == "com.figma.Desktop" }
    var allowsTransientFocus: Bool { usesCanvasSelection }
    var requiresMatchingInitialCopy: Bool { usesCanvasSelection }
    var canSetSelectionThroughAX: Bool { !usesCanvasSelection }
}
