import AppKit
import SwitcherCore

struct EditorApplication {
    let pid: pid_t
    let name: String
    let bundleID: String
    let session: String
    let isElectron: Bool
    /// Chromium browser; shares only Electron's accessibility wake-up.
    let isChromium: Bool
    let isQtQuick: Bool

    private static var described: [String: EditorApplication] = [:]

    /// Package checks read the bundle from disk; remember them for each
    /// running instance (process and launch time). Main thread only.
    static func describing(_ application: NSRunningApplication) -> EditorApplication {
        dispatchPrecondition(condition: .onQueue(.main))
        let instance = "\(application.processIdentifier):\(application.launchDate?.timeIntervalSince1970 ?? 0)"
        if let known = described[instance] { return known }
        let value = EditorApplication(application)
        if described.count >= 32 { described.removeAll() }
        described[instance] = value
        return value
    }

    private init(_ application: NSRunningApplication) {
        pid = application.processIdentifier
        name = application.localizedName ?? "Редактор"
        bundleID = application.bundleIdentifier ?? ""
        let bundle = application.bundleURL.flatMap(Bundle.init(url:))
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        session = "\(pid):\(application.launchDate?.timeIntervalSince1970 ?? 0):\(bundleID):\(version)"
        isElectron = ElectronApplicationBundle.recognizes(application.bundleURL)
        isChromium = !isElectron && ChromiumApplicationBundle.recognizes(application.bundleURL)
        isQtQuick = QtQuickApplicationBundle.recognizes(application.bundleURL)
    }
}

/// Figma's canvas setters can report success without changing visible text.
/// Read fresh coherent evidence, but never write its text/value/selection mirror.
struct EditorCompatibilityPolicy {
    let isFigma: Bool
    init(application: EditorApplication) { isFigma = application.bundleID == "com.figma.Desktop" }
    func isCanvasTextEditor(_ snapshot: AXEditorSnapshot?) -> Bool {
        AccessibilityEditorPolicy.isFigmaCanvas(isFigma: isFigma, role: snapshot?.role, description: snapshot?.description)
    }
    func canSetSelectionThroughAX(_ snapshot: AXEditorSnapshot?) -> Bool { !isCanvasTextEditor(snapshot) }
    func permitsEditing(_ snapshot: AXEditorSnapshot) -> Bool {
        AccessibilityEditorPolicy.permitsEditing(isFigma: isFigma, role: snapshot.role, description: snapshot.description)
    }
    func replacementBackend(for application: EditorApplication, snapshot: AXEditorSnapshot, selected: Bool,
                            selectedTextSettable: Bool, verifiedSpotlightSearch: Bool = false,
                            queryValueSettable: Bool = false, queryRangeSettable: Bool = false,
                            replacementText: String? = nil) -> TextReplacementBackend {
        let needsNativePayload = replacementText.map {
            UnicodeTextInput(text: $0, controlPolicy: textControlPolicy(for: application, snapshot: snapshot)) == nil &&
                TextReplacementBackend.acceptsNativeText($0)
        } == true
        return .select(isSelected: selected, bundleID: application.bundleID,
                isCurrentProcess: application.pid == ProcessInfo.processInfo.processIdentifier,
                isElectron: application.isElectron, role: snapshot.role, selectedTextSettable: selectedTextSettable,
                verifiedSpotlightSearch: verifiedSpotlightSearch, queryValueSettable: queryValueSettable,
                queryRangeSettable: queryRangeSettable, requiresNativePayload: needsNativePayload, isFigma: isFigma)
    }
    func textControlPolicy(for application: EditorApplication, snapshot: AXEditorSnapshot?) -> UnicodeTextInput.ControlPolicy {
        // Only public range-string/end-point proof enables Figma Return/ShiftReturn
        // semantics. AXValue paragraph normalization is never guessed.
        .forEditor(isCurrentProcess: application.pid == ProcessInfo.processInfo.processIdentifier,
                   isFigma: isCanvasTextEditor(snapshot) && snapshot?.usesCanonicalText == true, role: snapshot?.role, description: snapshot?.description)
    }
}
