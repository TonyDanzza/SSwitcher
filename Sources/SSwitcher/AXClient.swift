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

struct AXEditorSnapshot {
    let range: NSRange?
    let value: String?
    let selectedText: String?
    let subrole: String?
    let parent: AXUIElement?
    var isSecure: Bool { subrole == kAXSecureTextFieldSubrole }
}

struct AXEditorContext {
    let application: EditorApplication
    let policy: EditorCompatibilityPolicy
    let focused: AXUIElement?
    let element: AXUIElement?
    let snapshot: AXEditorSnapshot?
    let valueEditable: Bool
    let selectionSettable: Bool
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

    func invalidate() { execution.submit { self.capabilities.removeAll(); self.manualAccessibility.removeAll() } }
    func invalidateGeometry() { execution.submit { self.missingGeometry.removeAll() } }

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
        var focused = focus
        if focused == nil {
            let app = configured(AXUIElementCreateApplication(application.pid))
            focused = element(attribute(app, kAXFocusedUIElementAttribute))
        }
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
            if cached.selectionSettable == nil, policy.canSetSelectionThroughAX {
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
        let names = [kAXSelectedTextRangeAttribute, kAXValueAttribute] + (includeContext ? [kAXSelectedTextAttribute, kAXSubroleAttribute, kAXParentAttribute] : [])
        let key = ElementKey(session: application.session, element: editor)
        let now = ProcessInfo.processInfo.systemUptime
        var cached = capabilities.value(for: key, at: now) ?? Capabilities()
        var slots: [CFTypeRef?]
        if cached.batch {
            var values: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(editor, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
            if result == .success, let values, CFArrayGetCount(values) == names.count {
                slots = (values as [AnyObject]).map { AccessibilityValue.usable($0) }
            } else if result == .notImplemented || result == .attributeUnsupported {
                cached.batch = false
                capabilities.insert(cached, for: key, at: now, lifetime: 3)
                slots = names.map { attribute(editor, $0) }
            } else { return nil }
        } else { slots = names.map { attribute(editor, $0) } }
        let range = AccessibilityValue.range(slots[0]).map { NSRange(location: $0.location, length: $0.length) }
        return AXEditorSnapshot(range: range, value: slots[1] as? String,
                                selectedText: includeContext ? slots[2] as? String : nil,
                                subrole: includeContext ? slots[3] as? String : nil,
                                parent: includeContext ? element(slots[4]) : nil)
    }

    func focusMatches(_ context: AXEditorContext) -> Bool {
        if context.policy.allowsTransientFocus { return true }
        guard let current = target(fallbackPID: context.application.pid), current.pid == context.application.pid else { return false }
        if let original = context.focused { return current.focused.map { CFEqual($0, original) } ?? false }
        return true
    }

    func validate(_ context: AXEditorContext, document: String? = nil, range: NSRange? = nil, includeContext: Bool = false) -> AXEditorSnapshot? {
        guard focusMatches(context) else { return nil }
        guard let editor = context.element else { return document == nil && range == nil ? context.snapshot : nil }
        guard let snapshot = read(editor, application: context.application, includeContext: includeContext), !snapshot.isSecure else { return nil }
        if let document, snapshot.value != document { return nil }
        if let range, snapshot.range != range { return nil }
        return snapshot
    }

    func restoreSelection(_ context: AXEditorContext, document: String, range: NSRange,
                          cancellation: AttemptCancellation) -> Bool? {
        guard context.policy.canSetSelectionThroughAX, context.selectionSettable,
              !cancellation.isCancelled, let editor = context.element,
              validate(context, document: document) != nil, !cancellation.isCancelled else { return false }
        var value = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &value), !cancellation.isCancelled,
              AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, parameter) == .success else { return false }
        guard !cancellation.isCancelled else { return false }
        return validate(context, document: document, range: range) != nil
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
