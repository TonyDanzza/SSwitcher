import ApplicationServices
import Foundation
import os
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

struct AXEditorContext {
    let application: EditorApplication
    let policy: EditorCompatibilityPolicy
    let focused: AXUIElement?
    let element: AXUIElement?
    let snapshot: AXEditorSnapshot?
    let valueEditable: Bool
    let selectionSettable: Bool
    var usesCanvasSelection: Bool { policy.isCanvasTextEditor(snapshot) }
}

/// External messages use a serial worker; own-process AX invokes AppKit and
/// uses a separate main-bound client. Each instance confines its own caches.
final class AXClient {
    private let execution: AccessibilityExecution
    private let signposter = OSSignposter(subsystem: "com.tonydanzza.SSwitcher", category: "Conversion")
    private struct ElementKey: Hashable {
        let session: String
        let element: AXUIElement
        static func == (a: Self, b: Self) -> Bool { a.session == b.session && CFEqual(a.element, b.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(session); hasher.combine(CFHash(element)) }
    }
    private struct Capabilities {
        var batch = true
        var valueEditable: Bool?
        var selectionSettable: Bool?
        var geometrySupported: Bool?
    }
    private var capabilities = ExpiringCache<ElementKey, Capabilities>()
    private struct DocumentExtent { let rawValue: String; let length: Int }
    private var documentExtents = ExpiringCache<ElementKey, DocumentExtent>()
    private var manualAccessibility = ExpiringCache<String, Bool>(capacity: 16)
    private struct GeometryKey: Hashable { let element: ElementKey; let range: NSRange }
    private var missingGeometry = ExpiringCache<GeometryKey, Bool>()

    init(policy: AccessibilityExecution.Policy) { execution = AccessibilityExecution(policy: policy) }

    func perform<T>(cancellation: AttemptCancellation, operation: @escaping (AXClient) -> T?, completion: @escaping (T?, Double) -> Void) {
        execution.submit {
            self.execution.assertIsolated()
            let started = ProcessInfo.processInfo.systemUptime
            let state = self.signposter.beginInterval("AXRead", id: self.signposter.makeSignpostID())
            let result = cancellation.isCancelled ? nil : operation(self)
            self.signposter.endInterval("AXRead", state)
            let duration = ProcessInfo.processInfo.systemUptime - started
            DispatchQueue.main.async { completion(result, duration) }
        }
    }

    func prepareAccessibility(for application: EditorApplication) {
        execution.submit { self.prepare(application) }
    }

    func invalidate() { execution.submit { self.capabilities.removeAll(); self.manualAccessibility.removeAll(); self.documentExtents.removeAll() } }
    func invalidateGeometry() { execution.submit { self.missingGeometry.removeAll(); self.documentExtents.removeAll() } }

    private func configured(_ element: AXUIElement) -> AXUIElement {
        // The timeout belongs to this AX object, not separately acquired equal
        // objects; configure every element when it crosses this boundary.
        AXUIElementSetMessagingTimeout(element, ConversionTiming.axMessageTimeout)
        return element
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return AccessibilityValue.usable(value)
    }

    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value = AccessibilityValue.usable(value), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return configured(value as! AXUIElement)
    }

    func target(fallbackPID: pid_t) -> (pid: pid_t, focused: AXUIElement?)? {
        let system = configured(AXUIElementCreateSystemWide())
        if let focus = element(attribute(system, kAXFocusedUIElementAttribute)) {
            var pid: pid_t = 0
            if AXUIElementGetPid(focus, &pid) == .success { return (pid, focus) }
        }
        // Systemwide discovery is safe on the worker, but a fallback query to
        // our app's focused view would execute AppKit in-process on that worker.
        if fallbackPID == ProcessInfo.processInfo.processIdentifier, execution.policy == .remoteApplication { return (fallbackPID, nil) }
        let application = configured(AXUIElementCreateApplication(fallbackPID))
        return (fallbackPID, element(attribute(application, kAXFocusedUIElementAttribute)))
    }

    private func prepare(_ application: EditorApplication) {
        guard application.isElectron, AXIsProcessTrusted() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard manualAccessibility.value(for: application.session, at: now) == nil else { return }
        let app = configured(AXUIElementCreateApplication(application.pid))
        let success = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        manualAccessibility.insert(success, for: application.session, at: now, lifetime: success ? 60 : 3)
    }

    func context(application: EditorApplication, focus: AXUIElement?, cancellation: AttemptCancellation) -> AXEditorContext? {
        prepare(application)
        let policy = EditorCompatibilityPolicy(application: application)
        // Enabling an Electron accessibility tree can replace the focused AX
        // object. Discover it again after prepare instead of using that mirror.
        let app = configured(AXUIElementCreateApplication(application.pid))
        let focused = element(attribute(app, kAXFocusedUIElementAttribute)) ?? focus
        var candidate = focused
        var snapshot: AXEditorSnapshot?
        for depth in 0..<6 {
            guard !cancellation.isCancelled, let current = candidate else { break }
            snapshot = read(current, application: application)
            if snapshot?.isSecure == true || snapshot?.range != nil { break }
            guard depth < 5, let parent = snapshot?.parent else { break }
            candidate = parent
        }
        guard !cancellation.isCancelled else { return nil }
        var valueEditable = false
        var selectionSettable = false
        if let candidate, snapshot?.range != nil, snapshot?.isSecure != true {
            let key = ElementKey(session: application.session, element: candidate)
            let now = ProcessInfo.processInfo.systemUptime
            var cached = capabilities.value(for: key, at: now) ?? Capabilities()
            if cached.valueEditable == nil {
                var value = DarwinBoolean(false)
                cached.valueEditable = AXUIElementIsAttributeSettable(candidate, kAXValueAttribute as CFString, &value) == .success && value.boolValue
            }
            if cached.selectionSettable == nil, policy.canSetSelectionThroughAX(snapshot) {
                var value = DarwinBoolean(false)
                cached.selectionSettable = AXUIElementIsAttributeSettable(candidate, kAXSelectedTextRangeAttribute as CFString, &value) == .success && value.boolValue
            }
            valueEditable = cached.valueEditable == true
            selectionSettable = cached.selectionSettable == true
            let fullySupported = cached.batch && cached.geometrySupported != false && (valueEditable || selectionSettable)
            capabilities.insert(cached, for: key, at: now, lifetime: fullySupported ? 30 : 3)
        }
        return AXEditorContext(application: application, policy: policy, focused: focused, element: candidate,
                               snapshot: snapshot, valueEditable: valueEditable, selectionSettable: selectionSettable)
    }

    func read(_ editor: AXUIElement, application: EditorApplication, includeContext: Bool = true) -> AXEditorSnapshot? {
        if case .snapshot(let snapshot) = readResult(editor, application: application, includeContext: includeContext) { return snapshot }
        return nil
    }

    private func readRaw(_ editor: AXUIElement, application: EditorApplication, includeContext: Bool) -> AXSnapshotRead {
        let names = [kAXSelectedTextRangeAttribute, kAXValueAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangesAttribute] +
            (includeContext ? [kAXSubroleAttribute, kAXParentAttribute, kAXRoleAttribute, kAXDescriptionAttribute] : [])
        let key = ElementKey(session: application.session, element: editor)
        let now = ProcessInfo.processInfo.systemUptime
        var cached = capabilities.value(for: key, at: now) ?? Capabilities()
        var slots: [CFTypeRef?]
        func individually() -> [CFTypeRef?]? {
            var result: [CFTypeRef?] = []
            for name in names {
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(editor, name as CFString, &value)
                if error == .cannotComplete { return nil }
                if error == .success { result.append(value) }
                else if AccessibilityValue.isAbsentAttributeError(error, attribute: name) { result.append(nil) }
                else { return [] }
            }
            return result
        }
        if cached.batch {
            var values: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(editor, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
            if result == .success, let values, CFArrayGetCount(values) == names.count {
                slots = (values as [AnyObject]).map { $0 }
            } else if result == .cannotComplete { return .busy }
            else if result == .notImplemented || result == .attributeUnsupported {
                cached.batch = false
                capabilities.insert(cached, for: key, at: now, lifetime: 3)
                guard let values = individually() else { return .busy }
                slots = values
            } else { return .invalid }
        } else {
            guard let values = individually() else { return .busy }
            slots = values
        }
        guard slots.count == names.count else { return .invalid }
        if slots.contains(where: { AccessibilityValue.error($0) == .cannotComplete }) { return .busy }
        for (index, slot) in slots.enumerated() {
            if let error = AccessibilityValue.error(slot),
               !AccessibilityValue.isAbsentAttributeError(error, attribute: names[index]) { return .invalid }
        }
        slots = slots.map(AccessibilityValue.usable)
        let range = AccessibilityValue.range(slots[0]).map { NSRange(location: $0.location, length: $0.length) }
        let ranges = AccessibilityValue.ranges(slots[3]).map { $0.map { NSRange(location: $0.location, length: $0.length) } }
        if slots[0] != nil, range == nil { return .invalid }
        if slots[1] != nil, !(slots[1] is String) { return .invalid }
        if slots[2] != nil, !(slots[2] is String) { return .invalid }
        if slots[3] != nil, ranges == nil { return .invalid }
        if includeContext {
            for index in [4, 6, 7] where slots[index] != nil {
                if !(slots[index] is String) { return .invalid }
            }
        }
        return .snapshot(AXEditorSnapshot(range: range, value: slots[1] as? String, selectedText: slots[2] as? String,
                                          selectedRanges: ranges, subrole: includeContext ? slots[4] as? String : nil,
                                          parent: includeContext ? element(slots[5]) : nil, role: includeContext ? slots[6] as? String : nil,
                                          description: includeContext ? slots[7] as? String : nil))
    }

    private func readResult(_ editor: AXUIElement, application: EditorApplication, includeContext: Bool) -> AXSnapshotRead {
        let includeContext = includeContext || application.bundleID == "com.figma.Desktop"
        let initial = readRaw(editor, application: application, includeContext: includeContext)
        guard case .snapshot(var snapshot) = initial else { return initial }
        let policy = EditorCompatibilityPolicy(application: application)
        guard policy.isCanvasTextEditor(snapshot), let rawValue = snapshot.value,
              rawValue.contains("\n") || rawValue.contains("\u{2028}") else { return initial }
        guard !snapshot.isSecure, !AccessibilitySelectionPlan.hasTextAttachment(rawValue),
              snapshot.selectedText.map({ !AccessibilitySelectionPlan.hasTextAttachment($0) }) != false,
              let range = snapshot.range, range.location <= rawValue.utf16.count,
              range.length <= rawValue.utf16.count - range.location,
              AccessibilitySelectionPlan.hasSingleRange(range, selectedRanges: snapshot.selectedRanges) else { return .invalid }
        let expires = ProcessInfo.processInfo.systemUptime + ConversionTiming.canonicalDocumentBudget
        let key = ElementKey(session: application.session, element: editor)
        let cached = documentExtents.value(for: key, at: ProcessInfo.processInfo.systemUptime).flatMap {
            AccessibilitySelectionPlan.exactlyEqual($0.rawValue, rawValue) ? $0.length : nil
        }
        var busy = false
        let document = TextRangeDocumentPlan(upperBound: rawValue.utf16.count, lowerCandidate: range.location + range.length,
                                              cachedLength: cached) { request in
            guard ProcessInfo.processInfo.systemUptime < expires else { return .unavailable }
            var request = CFRange(location: request.location, length: request.length)
            guard let parameter = AXValueCreate(.cfRange, &request) else { return .unavailable }
            var result: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(editor, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result)
            if error == .cannotComplete { busy = true; return .unavailable }
            guard ProcessInfo.processInfo.systemUptime < expires else { return .unavailable }
            if error == .success, let value = result as? String { return .text(value) }
            // Only this proven Figma text editor's explicit NoValue response
            // means out of range. No generic nil/IPC error is a boundary.
            if error == .noValue { return .outOfBounds }
            return .unavailable
        }
        guard let document else { return busy ? .busy : .invalid }
        let fresh = readRaw(editor, application: application, includeContext: true)
        guard case .snapshot(let repeated) = fresh else { return fresh }
        guard ProcessInfo.processInfo.systemUptime < expires, snapshot.sameRawEvidence(as: repeated) else { return .invalid }
        if range.length > 0 {
            guard AccessibilitySelectionPlan(document: document.document, range: range, selectedText: snapshot.selectedText,
                                            selectedRanges: snapshot.selectedRanges) != nil else { return .invalid }
        } else {
            guard AccessibilitySelectionPlan.confirmsCaret(document: document.document, range: range, selectedText: snapshot.selectedText,
                                                           selectedRanges: snapshot.selectedRanges, expectedDocument: document.document,
                                                           expectedCaret: range) else { return .invalid }
        }
        documentExtents.insert(DocumentExtent(rawValue: rawValue, length: document.length), for: key,
                               at: ProcessInfo.processInfo.systemUptime, lifetime: 30)
        snapshot = repeated
        snapshot = AXEditorSnapshot(range: snapshot.range, value: document.document, selectedText: snapshot.selectedText,
                                    selectedRanges: snapshot.selectedRanges, subrole: snapshot.subrole, parent: snapshot.parent,
                                    role: snapshot.role, description: snapshot.description, usesCanonicalText: true)
        return .snapshot(snapshot)
    }

    /// Only an explicit busy snapshot response is retryable. Focus, secure
    /// fields, policy changes and malformed data are immediate invalidations.
    func acknowledgement(_ context: AXEditorContext) -> AXSnapshotRead {
        guard focusMatches(context), let editor = context.element else { return .invalid }
        let result = readResult(editor, application: context.application, includeContext: true)
        guard case .snapshot(let snapshot) = result else { return result }
        guard !snapshot.isSecure, context.policy.permitsEditing(snapshot),
              context.policy.isCanvasTextEditor(snapshot) == context.usesCanvasSelection else { return .invalid }
        return result
    }

    func focusMatches(_ context: AXEditorContext) -> Bool {
        guard let current = target(fallbackPID: context.application.pid), current.pid == context.application.pid else { return false }
        if let original = context.focused { return current.focused.map { CFEqual($0, original) } ?? false }
        return false
    }

    func validate(_ context: AXEditorContext, document: String? = nil, range: NSRange? = nil, includeContext: Bool = false) -> AXEditorSnapshot? {
        guard focusMatches(context) else { return nil }
        guard let editor = context.element else { return document == nil && range == nil ? context.snapshot : nil }
        guard let snapshot = read(editor, application: context.application, includeContext: includeContext), !snapshot.isSecure else { return nil }
        if let document, snapshot.value.map({ AccessibilitySelectionPlan.exactlyEqual($0, document) }) != true { return nil }
        if let range, snapshot.range != range { return nil }
        return snapshot
    }

    func isEditable(_ context: AXEditorContext, snapshot: AXEditorSnapshot) -> Bool {
        guard !snapshot.isSecure, context.policy.permitsEditing(snapshot),
              let editor = context.element else { return false }
        var editable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(editor, kAXValueAttribute as CFString, &editable) == .success && editable.boolValue
    }

    func replacementBackend(_ context: AXEditorContext, snapshot: AXEditorSnapshot, selected: Bool) -> TextReplacementBackend {
        guard context.policy.replacementBackend(for: context.application, snapshot: snapshot, selected: selected,
                                                selectedTextSettable: true) == .accessibilitySelectedText,
              let editor = context.element else { return .unicodeEvents }
        var settable = DarwinBoolean(false)
        let supported = AXUIElementIsAttributeSettable(editor, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
        return context.policy.replacementBackend(for: context.application, snapshot: snapshot, selected: selected,
                                                 selectedTextSettable: supported)
    }

    /// One selected-fragment setter only. Never write AXValue/full-document
    /// text, and never interpret its success reply as editor acknowledgement.
    func replaceSelectedText(_ context: AXEditorContext, selection: AccessibilitySelectionPlan, replacement: String,
                             cancellation: AttemptCancellation) -> Bool? {
        guard !cancellation.isCancelled, TextReplacementBackend.acceptsNativeText(replacement),
              let editor = context.element,
              let snapshot = validate(context, document: selection.document, range: selection.range, includeContext: true),
              isEditable(context, snapshot: snapshot),
              selection.matches(document: snapshot.value, range: snapshot.range, selectedText: snapshot.selectedText,
                                selectedRanges: snapshot.selectedRanges),
              replacementBackend(context, snapshot: snapshot, selected: true) == .accessibilitySelectedText,
              !cancellation.isCancelled else { return false }
        let result = AXUIElementSetAttributeValue(editor, kAXSelectedTextAttribute as CFString, replacement as CFString)
        return !cancellation.isCancelled && result == .success
    }

    func restoreSelection(_ context: AXEditorContext, document: String, caret: NSRange, range: NSRange,
                          cancellation: AttemptCancellation) -> Bool? {
        guard context.policy.canSetSelectionThroughAX(context.snapshot), context.selectionSettable,
              !cancellation.isCancelled, let editor = context.element,
              let snapshot = validate(context, document: document, range: caret, includeContext: true),
              isEditable(context, snapshot: snapshot),
              context.policy.isCanvasTextEditor(snapshot) == context.usesCanvasSelection,
              AccessibilitySelectionPlan.confirmsCaret(document: snapshot.value, range: snapshot.range, selectedText: snapshot.selectedText,
                                                       selectedRanges: snapshot.selectedRanges, expectedDocument: document, expectedCaret: caret),
              !cancellation.isCancelled else { return false }
        var value = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &value), !cancellation.isCancelled,
              AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, parameter) == .success else { return false }
        guard !cancellation.isCancelled else { return false }
        // A target may apply the range after replying. The coordinator polls
        // exact document/range/selected text within its separate fixed budget.
        return true
    }

    func bounds(_ context: AXEditorContext, range: NSRange) -> CGRect? {
        guard let editor = context.element, range.length > 0 else { return nil }
        let key = ElementKey(session: context.application.session, element: editor)
        let now = ProcessInfo.processInfo.systemUptime
        let geometryKey = GeometryKey(element: key, range: range)
        guard missingGeometry.value(for: geometryKey, at: now) == nil else { return nil }
        var cached = capabilities.value(for: key, at: now) ?? Capabilities()
        guard cached.geometrySupported != false else { return nil }
        func rectangle(_ range: NSRange) -> CGRect? {
            var range = CFRange(location: range.location, length: range.length)
            guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
            var value: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(editor, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value)
            if error == .parameterizedAttributeUnsupported || error == .attributeUnsupported {
                cached.geometrySupported = false
                capabilities.insert(cached, for: key, at: now, lifetime: 3)
            }
            guard error == .success, let value = AccessibilityValue.usable(value),
                  CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .cgRect else { return nil }
            var rect = CGRect.zero
            return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
        }
        guard let full = rectangle(range), full.minX.isFinite, full.minY.isFinite,
              full.width.isFinite, full.height.isFinite, full.width > 1, full.width <= 900,
              full.height >= 5, full.height <= 180 else {
            missingGeometry.insert(true, for: geometryKey, at: now, lifetime: 2)
            return nil
        }
        guard
              let first = rectangle(NSRange(location: range.location, length: 1)),
              let last = rectangle(NSRange(location: NSMaxRange(range) - 1, length: 1)),
              first.width > 0, last.width > 0, abs(first.midY - last.midY) < 3,
              full.insetBy(dx: -2, dy: -2).contains(first), full.insetBy(dx: -2, dy: -2).contains(last),
              range.length == 1 || last.minX > first.minX else { return nil }
        // A zero canvas range is a property of this request, not a blacklist.
        return full
    }

}
