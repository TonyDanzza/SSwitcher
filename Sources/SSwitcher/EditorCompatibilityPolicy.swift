import AppKit
import SwitcherCore

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
                            selectedTextSettable: Bool) -> TextReplacementBackend {
        .select(isSelected: selected, bundleID: application.bundleID,
                isCurrentProcess: application.pid == ProcessInfo.processInfo.processIdentifier,
                isElectron: application.isElectron, role: snapshot.role, selectedTextSettable: selectedTextSettable)
    }
    func textControlPolicy(for application: EditorApplication, snapshot: AXEditorSnapshot?) -> UnicodeTextInput.ControlPolicy {
        // Only public range-string/end-point proof enables Figma Return/ShiftReturn
        // semantics. AXValue paragraph normalization is never guessed.
        .forEditor(isCurrentProcess: application.pid == ProcessInfo.processInfo.processIdentifier,
                   isFigma: isCanvasTextEditor(snapshot) && snapshot?.usesCanonicalText == true, role: snapshot?.role, description: snapshot?.description)
    }
}
