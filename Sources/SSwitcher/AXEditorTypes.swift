import ApplicationServices
import AppKit
import Foundation
import SwitcherCore

/// The only state shared between main and AX queue. Cancelling never waits for
/// a remote AX call; the next operation/check observes it under this small lock.
final class AttemptCancellation {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

enum AXSnapshotRead { case snapshot(AXEditorSnapshot), busy, invalid }

enum AXTextScopeRead {
    case notRequired, verified, mismatch, unavailable(AXError), busy, cancelled, timedOut
    var permitsUse: Bool {
        switch self { case .notRequired, .verified: return true; default: return false }
    }
    var diagnosticCode: String {
        switch self {
        case .notRequired: return "notRequired"
        case .verified: return "verified"
        case .mismatch: return "mismatch"
        case .unavailable: return "unavailable"
        case .busy: return "busy"
        case .cancelled: return "cancelled"
        case .timedOut: return "timedOut"
        }
    }
}

struct AXEditorSnapshot {
    let range: NSRange?
    let value: String?
    let selectedText: String?
    let selectedRanges: [NSRange]?
    let subrole: String?
    let parent: AXUIElement?
    let role: String?
    let description: String?
    var usesCanonicalText = false
    var isSecure: Bool { subrole == kAXSecureTextFieldSubrole }
    var selectionPlan: AccessibilitySelectionPlan? {
        AccessibilitySelectionPlan(document: value, range: range, selectedText: selectedText, selectedRanges: selectedRanges)
    }
    func sameRawEvidence(as other: Self) -> Bool {
        func equal(_ a: String?, _ b: String?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case (let a?, let b?): return AccessibilitySelectionPlan.exactlyEqual(a, b)
            default: return false
            }
        }
        return range == other.range && selectedRanges == other.selectedRanges && equal(value, other.value) &&
            equal(selectedText, other.selectedText) && subrole == other.subrole && role == other.role && description == other.description
    }

}

struct AXSpotlightFocus {
    let field: AXUIElement
    let window: AXUIElement
}

/// Keep the existing capability reply; false does not prove a read-only UI.
enum AXValueWriteCapability {
    case settable, notSettable, unavailable(AXError)
    var allowsWrite: Bool {
        if case .settable = self { return true }
        return false
    }
}

struct AXQtFocusedWindow {
    let window: AXUIElement
    let cancellation: AttemptCancellation
}

struct AXFocusPreparationDiagnostic {
    var stage = "notAttempted"
    var error: AXError?
}

struct AXFocusReadDiagnostic {
    let status: AccessibilityElementReply.Status
    let error: AXError?
    init(_ reply: AccessibilityElementReply) { status = reply.status; error = reply.error }
}

struct AXFocusDiscoveryDiagnostic {
    var system: AXFocusReadDiagnostic?
    var fallbackApplication: AXFocusReadDiagnostic?
    var application: AXFocusReadDiagnostic?
    var systemOwnerError: AXError?
}

struct AXElectronPreparationDiagnostic {
    let stage: String
    let error: AXError?
    var rolePreparation = AXFocusPreparationDiagnostic()
}

struct AXEditorTarget {
    let pid: pid_t
    let focused: AXUIElement?
    let spotlight: AXSpotlightFocus?
    let focusDiscovery: AXFocusDiscoveryDiagnostic
}

struct AXEditorContext {
    let application: EditorApplication
    let policy: EditorCompatibilityPolicy
    let focused: AXUIElement?
    let element: AXUIElement?
    let snapshot: AXEditorSnapshot?
    let valueWriteCapability: AXValueWriteCapability?
    let selectionSettable: Bool
    let spotlightFocus: AXSpotlightFocus?
    let qtFocusedWindow: AXQtFocusedWindow?
    let initialFocusRoles: [String?]
    let editorDiscoveryRoles: [String?]
    let focusPreparation: AXFocusPreparationDiagnostic
    let focusDiscovery: AXFocusDiscoveryDiagnostic
    let electronPreparation: AXElectronPreparationDiagnostic
    var valueEditable: Bool { valueWriteCapability?.allowsWrite == true }
    var isCanvasTextEditor: Bool { policy.isCanvasTextEditor(snapshot) }

    /// Role identifiers are metadata, not arbitrary labels or field content.
    private static func diagnosticRole(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let bytes = Array(raw.utf8.prefix(65))
        guard bytes.count > 2, bytes.count <= 64, bytes[0] == 65, bytes[1] == 88,
              bytes.allSatisfy({ $0 == 95 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return raw
    }

    /// The existing reply only; no text, ranges, labels, descriptions or PID.
    func conversionDiagnostic() -> [String: Any] {
        let role = snapshot?.role
        var report: [String: Any] = [
            "appBundleID": application.bundleID,
            "role": Self.diagnosticRole(role) ?? (role == nil ? "absent" : "other"),
            "initialFocusRoles": initialFocusRoles.map { Self.diagnosticRole($0) ?? ($0 == nil ? "absent" : "other") },
            "editorDiscoveryRoles": editorDiscoveryRoles.map { Self.diagnosticRole($0) ?? ($0 == nil ? "absent" : "other") },
            "focusPreparation": focusPreparation.stage
        ]
        for (key, read) in [("systemFocusRead", focusDiscovery.system),
                            ("fallbackApplicationFocusRead", focusDiscovery.fallbackApplication),
                            ("applicationFocusRead", focusDiscovery.application)] {
            report[key] = read?.status.rawValue ?? "notAttempted"
            if let error = read?.error { report[key + "AXError"] = Int(error.rawValue) }
        }
        if let error = focusDiscovery.systemOwnerError { report["systemFocusOwnerAXError"] = Int(error.rawValue) }
        report["electronPackageRecognized"] = application.isElectron
        report["electronPreparation"] = electronPreparation.stage
        if let error = electronPreparation.error { report["electronPreparationAXError"] = Int(error.rawValue) }
        report["electronRolePreparation"] = electronPreparation.rolePreparation.stage
        if let error = electronPreparation.rolePreparation.error { report["electronRolePreparationAXError"] = Int(error.rawValue) }
        if let error = focusPreparation.error { report["focusPreparationAXError"] = Int(error.rawValue) }
        switch valueWriteCapability {
        case .settable: report["valueCapability"] = "settable"
        case .notSettable: report["valueCapability"] = "notSettable"
        case .unavailable(let error):
            report["valueCapability"] = "unavailable"
            report["AXError"] = Int(error.rawValue)
        case nil: report["valueCapability"] = "notQueried"
        }
        return report
    }

    func editingRefusal(for snapshot: AXEditorSnapshot) -> String {
        guard snapshot.role != nil else { return "AXRole: редактор не предоставил тип поля" }
        let role: String
        switch snapshot.role {
        case kAXTextAreaRole: role = "AXTextArea"
        case kAXTextFieldRole: role = "AXTextField"
        case kAXComboBoxRole: role = "AXComboBox"
        case kAXGroupRole: return "AXGroup: поле не подтверждено как редактор"
        case kAXStaticTextRole: return "AXStaticText: поле не подтверждено как редактор"
        case kAXWindowRole: return "AXWindow: поле не подтверждено как редактор"
        case kAXUnknownRole: return "AXUnknown: поле не подтверждено как редактор"
        default:
            if let identifier = Self.diagnosticRole(snapshot.role) { return "\(identifier): неподдерживаемый тип поля" }
            return "Неподдерживаемая роль поля"
        }
        guard policy.permitsEditing(snapshot) else { return "\(role): режим редактирования не подтверждён" }
        switch valueWriteCapability {
        case .settable: return "\(role): поле не подтвердило редактирование"
        case .notSettable: return "\(role): редактор не разрешает запись AXValue"
        case .unavailable(let error): return "\(role): ошибка проверки AXValue (\(error.rawValue))"
        case nil: return "\(role): диапазон для проверки AXValue недоступен"
        }
    }
}
