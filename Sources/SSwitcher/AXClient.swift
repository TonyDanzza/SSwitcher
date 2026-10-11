import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import os
import SwitcherCore

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
        var valueWriteCapability: AXValueWriteCapability?
        var selectionSettable: Bool?
        var geometrySupported: Bool?
    }
    private var capabilities = ExpiringCache<ElementKey, Capabilities>()
    private struct DocumentExtent { let rawValue: String; let length: Int }
    private var documentExtents = ExpiringCache<ElementKey, DocumentExtent>()
    private struct ElectronPreparationResult {
        let setterError: AXError
        let queriedAt: Double
        var rolePreparation = AXFocusPreparationDiagnostic()
    }
    private var manualAccessibility = ExpiringCache<String, ElectronPreparationResult>(capacity: 16)
    private struct GeometryKey: Hashable { let element: ElementKey; let range: NSRange }
    private var missingGeometry = ExpiringCache<GeometryKey, Bool>()
    private struct QtDisplaySnapshot: Equatable {
        let mainID: CGDirectDisplayID
        let bounds: [CGDirectDisplayID: CGRect]
    }

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
        execution.submit { _ = self.prepare(application) }
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

    /// Retain the result of this existing query without a second AX request.
    private func focusedElement(_ node: AXUIElement) -> (element: AXUIElement?, diagnostic: AXFocusReadDiagnostic) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(node, kAXFocusedUIElementAttribute as CFString, &value)
        let reply = AccessibilityElementReply(error: error, value: value)
        return (reply.element.map(configured), AXFocusReadDiagnostic(reply))
    }

    func target(fallbackPID: pid_t) -> AXEditorTarget? {
        let system = configured(AXUIElementCreateSystemWide())
        let systemRead = focusedElement(system)
        var diagnostic = AXFocusDiscoveryDiagnostic(system: systemRead.diagnostic)
        if let focus = systemRead.element {
            var pid: pid_t = 0
            let error = AXUIElementGetPid(focus, &pid)
            if error == .success {
                return AXEditorTarget(pid: pid, focused: focus, spotlight: spotlightFocus(focus, pid: pid), focusDiscovery: diagnostic)
            }
            diagnostic.systemOwnerError = error
        }
        // Systemwide discovery is safe on the worker, but a fallback query to
        // our app's focused view would execute AppKit in-process on that worker.
        if fallbackPID == ProcessInfo.processInfo.processIdentifier, execution.policy == .remoteApplication {
            return AXEditorTarget(pid: fallbackPID, focused: nil, spotlight: nil, focusDiscovery: diagnostic)
        }
        let application = configured(AXUIElementCreateApplication(fallbackPID))
        let fallback = focusedElement(application)
        diagnostic.fallbackApplication = fallback.diagnostic
        return AXEditorTarget(pid: fallbackPID, focused: fallback.element, spotlight: nil, focusDiscovery: diagnostic)
    }

    /// Narrow public UI evidence, not an app-name exception. Other Campo/Siri
    /// fields and every unavailable/malformed query fail this overlay proof.
    private func spotlightFocus(_ field: AXUIElement, pid: pid_t, deadline: Double? = nil) -> AXSpotlightFocus? {
        guard let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              bundleID == "com.apple.campo" else { return nil }
        let deadline = deadline ?? ProcessInfo.processInfo.systemUptime + ConversionTiming.overlayFocusBudget
        func read(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let value = attribute(configured(node), name)
            return ProcessInfo.processInfo.systemUptime < deadline ? value : nil
        }
        let role = read(field, kAXRoleAttribute) as? String
        let subrole = read(field, kAXSubroleAttribute) as? String
        let identifier = read(field, kAXIdentifierAttribute) as? String
        guard role == kAXTextFieldRole, subrole == kAXSearchFieldSubrole, identifier == "SpotlightSearchField" else { return nil }
        var ancestor = element(read(field, kAXParentAttribute))
        for _ in 0..<8 {
            guard let current = ancestor else { return nil }
            if SpotlightSearchScope.isVerified(bundleID: bundleID, role: role, subrole: subrole, identifier: identifier,
                                               windowRole: read(current, kAXRoleAttribute) as? String,
                                               windowSubrole: read(current, kAXSubroleAttribute) as? String) {
                return AXSpotlightFocus(field: field, window: current)
            }
            ancestor = element(read(current, kAXParentAttribute))
        }
        return nil
    }

    private func systemSpotlightMatches(_ original: AXSpotlightFocus, pid: pid_t) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + ConversionTiming.overlayFocusBudget
        let system = configured(AXUIElementCreateSystemWide())
        guard let focusedApp = element(attribute(system, kAXFocusedApplicationAttribute)),
              ProcessInfo.processInfo.systemUptime < deadline else { return false }
        var appPID: pid_t = 0
        guard AXUIElementGetPid(focusedApp, &appPID) == .success, appPID == pid,
              let focused = element(attribute(system, kAXFocusedUIElementAttribute)),
              ProcessInfo.processInfo.systemUptime < deadline else { return false }
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focused, &focusedPID) == .success,
              let proof = spotlightFocus(focused, pid: focusedPID, deadline: deadline) else { return false }
        return SpotlightSearchScope.matchesFocus(expectedPID: pid, actualPID: focusedPID,
                                                 sameField: CFEqual(original.field, proof.field),
                                                 sameWindow: CFEqual(original.window, proof.window), verifiedIdentity: true)
    }

    private func prepare(_ application: EditorApplication, cancellation: AttemptCancellation? = nil) -> AXElectronPreparationDiagnostic {
        guard application.isElectron else { return AXElectronPreparationDiagnostic(stage: "notElectron", error: nil) }
        guard AXIsProcessTrusted() else { return AXElectronPreparationDiagnostic(stage: "notTrusted", error: nil) }
        let now = ProcessInfo.processInfo.systemUptime
        let expires = now + ConversionTiming.electronPreparationBudget
        func ready() -> Bool { cancellation?.isCancelled != true && ProcessInfo.processInfo.systemUptime < expires }
        func interruption() -> AXFocusPreparationDiagnostic {
            AXFocusPreparationDiagnostic(stage: cancellation?.isCancelled == true ? "cancelled" : "timedOut")
        }
        var app: AXUIElement?
        let cached = manualAccessibility.value(for: application.session, at: now)
        var result: ElectronPreparationResult
        if let cached { result = cached }
        else {
            guard ready() else { return AXElectronPreparationDiagnostic(stage: interruption().stage, error: nil) }
            let node = configured(AXUIElementCreateApplication(application.pid))
            app = node
            guard ready() else { return AXElectronPreparationDiagnostic(stage: interruption().stage, error: nil) }
            let error = AXUIElementSetAttributeValue(node, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            result = ElectronPreparationResult(setterError: error, queriedAt: now)
            // Retain an unsupported setter even if cancellation prevents the
            // role entry; it must not be sent again for every failed gesture.
            if ready() || error == .attributeUnsupported {
                manualAccessibility.insert(result, for: application.session, at: now, lifetime: error == .success ? 60 : 3)
            }
        }
        var diagnostic = AXElectronPreparationDiagnostic(
            stage: cached != nil ? (result.setterError == .success ? "cachedSetterSuccess" : "cachedSetterFailure")
                                 : (result.setterError == .success ? "setterSuccess" : "setterFailure"),
            error: result.setterError == .success ? nil : result.setterError,
            rolePreparation: result.rolePreparation)
        guard ready() else { diagnostic.rolePreparation = interruption(); return diagnostic }
        guard result.setterError == .attributeUnsupported, result.rolePreparation.stage == "notAttempted" else { return diagnostic }

        // Chromium/Electron's public application role getter can enable native
        // accessibility. Its response is discarded as editor authority: only
        // the ordinary fresh focused-element discovery may supply that field.
        let node = app ?? configured(AXUIElementCreateApplication(application.pid))
        guard ready() else { diagnostic.rolePreparation = interruption(); return diagnostic }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &value)
        guard ready() else { diagnostic.rolePreparation = interruption(); return diagnostic }
        let role: AXFocusPreparationDiagnostic
        if AccessibilityValue.isApplicationRole(value, error: error) {
            role = AXFocusPreparationDiagnostic(stage: "applicationRoleRead")
        } else if error != .success {
            role = AXFocusPreparationDiagnostic(stage: "failed", error: error)
        } else if let embedded = AccessibilityValue.error(value) {
            role = AXFocusPreparationDiagnostic(stage: "failed", error: embedded)
        } else if let usable = AccessibilityValue.usable(value) {
            role = AXFocusPreparationDiagnostic(stage: usable is String ? "unexpectedRole" : "malformed")
        } else { role = AXFocusPreparationDiagnostic(stage: "absent") }
        guard ready() else { diagnostic.rolePreparation = interruption(); return diagnostic }
        result.rolePreparation = role
        // Updating the role result cannot extend the original setter cache.
        manualAccessibility.insert(result, for: application.session, at: result.queriedAt, lifetime: 3)
        diagnostic.rolePreparation = role
        return diagnostic
    }

    /// Pages builds the text elements of its document canvas only for an
    /// assistive client and until then reports the canvas scroll area as
    /// focused. A request to enable AXEnhancedUserInterface wakes it (Pages
    /// answers "not implemented" but builds the elements and moves its focus to
    /// the text). Ask once, wait briefly for the application's own focus to
    /// become a focused text element, and turn the flag off again if the
    /// application actually kept it. The flag is never touched when it was on.
    private func prepareCanvasFocus(_ application: EditorApplication, app: AXUIElement,
                                    cancellation: AttemptCancellation,
                                    diagnostic: inout AXFocusPreparationDiagnostic) -> AXUIElement? {
        guard execution.policy == .remoteApplication else { return nil }
        let expires = ProcessInfo.processInfo.systemUptime + ConversionTiming.canvasFocusPreparationBudget
        func ready() -> Bool {
            if cancellation.isCancelled { diagnostic.stage = "cancelled"; return false }
            if ProcessInfo.processInfo.systemUptime >= expires { diagnostic.stage = "timedOut"; return false }
            return true
        }
        let flag = "AXEnhancedUserInterface" as CFString
        func enhanced() -> Bool {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(app, flag, &value) == .success && (value as? Bool) == true
        }
        let wasEnhanced = enhanced()
        if !wasEnhanced {
            diagnostic.stage = "canvasWakeRequested"
            let reply = AXUIElementSetAttributeValue(app, flag, kCFBooleanTrue)
            if reply != .success { diagnostic.error = reply }
        }
        defer { if !wasEnhanced, enhanced() { _ = AXUIElementSetAttributeValue(app, flag, kCFBooleanFalse) } }
        while ready() {
            if let focus = focusedElement(app).element {
                var pid: pid_t = 0
                let role = attribute(focus, kAXRoleAttribute) as? String
                if AXUIElementGetPid(focus, &pid) == .success, pid == application.pid,
                   AccessibilityEditorPolicy.isFocusedTextCandidate(role: role, focused: attribute(focus, kAXFocusedAttribute) as? Bool == true,
                                                                    hasRange: attribute(focus, kAXSelectedTextRangeAttribute) != nil) {
                    diagnostic.stage = "canvasPrepared"
                    return focus
                }
            }
            Thread.sleep(forTimeInterval: ConversionTiming.pollInterval)
        }
        return nil
    }

    /// Qt activates its accessibility machinery at QNSView entry points.
    /// Enter the app's public hit-test path within its focused window, discard
    /// the reply, then accept only fresh app/global focus in that same window.
    private func prepareQtFocus(_ application: EditorApplication, app: AXUIElement,
                                cancellation: AttemptCancellation, diagnostic: inout AXFocusPreparationDiagnostic)
        -> (focused: AXUIElement, window: AXQtFocusedWindow)? {
        let expires = ProcessInfo.processInfo.systemUptime + ConversionTiming.qtFocusPreparationBudget
        func ready() -> Bool {
            if cancellation.isCancelled { diagnostic.stage = "cancelled"; return false }
            if ProcessInfo.processInfo.systemUptime >= expires { diagnostic.stage = "timedOut"; return false }
            return true
        }
        func read(_ node: AXUIElement, _ name: String, stage: String) -> CFTypeRef? {
            guard ready() else { return nil }
            diagnostic.stage = stage
            let node = configured(node)
            guard ready() else { return nil }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(node, name as CFString, &value)
            guard ready() else { return nil }
            guard error == .success else { diagnostic.error = error; return nil }
            return AccessibilityValue.usable(value)
        }
        func owned(_ node: AXUIElement) -> Bool {
            guard ready() else { return false }
            var pid: pid_t = 0
            let error = AXUIElementGetPid(node, &pid)
            guard ready() else { return false }
            if error != .success { diagnostic.error = error; return false }
            if pid != application.pid { diagnostic.stage = "ownerMismatch"; return false }
            return true
        }
        func validRect(_ rect: CGRect) -> Bool {
            rect.size.width > 0 && rect.size.height > 0 && WindowTransferPlan.valid(rect)
        }
        func frame(_ window: AXUIElement) -> CGRect? {
            guard let rawPoint = read(window, kAXPositionAttribute, stage: "windowPositionUnavailable"),
                  CFGetTypeID(rawPoint) == AXValueGetTypeID(), AXValueGetType(rawPoint as! AXValue) == .cgPoint else { return nil }
            var point = CGPoint.zero
            guard AXValueGetValue(rawPoint as! AXValue, .cgPoint, &point) else { return nil }
            guard let rawSize = read(window, kAXSizeAttribute, stage: "windowSizeUnavailable"),
                  CFGetTypeID(rawSize) == AXValueGetTypeID(), AXValueGetType(rawSize as! AXValue) == .cgSize else { return nil }
            var size = CGSize.zero
            guard AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
            let result = CGRect(origin: point, size: size)
            guard validRect(result) else { diagnostic.stage = "windowGeometryInvalid"; return nil }
            return result
        }
        func displays() -> QtDisplaySnapshot? {
            guard ready() else { return nil }
            diagnostic.stage = "displaysUnavailable"
            var count: UInt32 = 0
            let countError = CGGetActiveDisplayList(0, nil, &count)
            guard ready(), countError == .success, count > 0, count <= 64 else { return nil }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            var actual: UInt32 = 0
            let listError = CGGetActiveDisplayList(count, &ids, &actual)
            guard ready(), listError == .success, actual == count, Set(ids).count == ids.count else { return nil }
            let mainID = CGMainDisplayID()
            guard ready(), ids.contains(mainID) else { return nil }
            var bounds: [CGDirectDisplayID: CGRect] = [:]
            for id in ids {
                guard ready() else { return nil }
                let rect = CGDisplayBounds(id)
                guard ready() else { return nil }
                guard id != kCGNullDirectDisplay, validRect(rect) else {
                    diagnostic.stage = "displayGeometryInvalid"; return nil
                }
                bounds[id] = rect
            }
            return QtDisplaySnapshot(mainID: mainID, bounds: bounds)
        }
        func preparationPoint(frame: CGRect, displays: QtDisplaySnapshot) -> CGPoint? {
            guard ready() else { return nil }
            diagnostic.stage = "pointUnavailable"
            // Insets avoid frame/display edges; they do not identify a control
            // or prove that another window does not cover this point.
            let interior = frame.insetBy(dx: 32, dy: 32)
            guard validRect(interior) else { return nil }
            var region: CGRect?
            var largestArea: CGFloat = 0
            for id in displays.bounds.keys.sorted() {
                guard let bounds = displays.bounds[id] else { return nil }
                let viewport = bounds.insetBy(dx: 8, dy: 8)
                guard validRect(viewport) else { continue }
                let visible = interior.intersection(viewport)
                guard validRect(visible) else { continue }
                let area = visible.width * visible.height
                if area.isFinite, area > largestArea { region = visible; largestArea = area }
            }
            guard let region else { return nil }
            let x = Float(region.midX), y = Float(region.midY)
            guard x.isFinite, y.isFinite else { return nil }
            let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
            guard point.x > region.minX, point.x < region.maxX,
                  point.y > region.minY, point.y < region.maxY, ready() else { return nil }
            return point
        }
        guard let window = element(read(app, kAXFocusedWindowAttribute, stage: "focusedWindowUnavailable")), owned(window),
              read(window, kAXRoleAttribute, stage: "windowRoleUnavailable") as? String == kAXWindowRole,
              ready() else { return nil }
        guard let originalFrame = frame(window), let originalDisplays = displays(),
              let point = preparationPoint(frame: originalFrame, displays: originalDisplays) else { return nil }
        let system = configured(AXUIElementCreateSystemWide())
        guard let before = element(read(system, kAXFocusedUIElementAttribute, stage: "globalFocusUnavailable")), owned(before),
              let beforeWindow = element(read(app, kAXFocusedWindowAttribute, stage: "focusedWindowChanged")), owned(beforeWindow),
              CFEqual(beforeWindow, window), ready() else { return nil }
        diagnostic.stage = "pointEntryUnavailable"
        let pointApplication = configured(app)
        guard ready() else { return nil }
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(pointApplication, Float(point.x), Float(point.y), &hit)
        let hasHit = hit != nil
        hit = nil // Never read or select the object under the preparation point.
        guard ready() else { return nil }
        guard error == .success, hasHit else {
            if error != .success { diagnostic.error = error }
            return nil
        }
        guard let focused = element(read(app, kAXFocusedUIElementAttribute, stage: "appFocusUnavailable")), owned(focused) else { return nil }
        guard !CFEqual(focused, app) else { diagnostic.stage = "applicationStillFocused"; return nil }
        guard let currentWindow = element(read(app, kAXFocusedWindowAttribute, stage: "focusedWindowChanged")),
              CFEqual(currentWindow, window) else { return nil }
        guard let global = element(read(system, kAXFocusedUIElementAttribute, stage: "globalFocusUnavailable")), owned(global) else { return nil }
        guard CFEqual(global, focused) else { diagnostic.stage = "globalFocusMismatch"; return nil }
        guard !CFEqual(global, window) else { diagnostic.stage = "windowStillFocused"; return nil }
        guard let role = read(global, kAXRoleAttribute, stage: "focusRoleUnavailable") as? String else { return nil }
        guard role != kAXWindowRole else { diagnostic.stage = "windowStillFocused"; return nil }
        guard let containingWindow = element(read(global, kAXWindowAttribute, stage: "focusWindowUnavailable")),
              CFEqual(containingWindow, window), ready() else { return nil }
        guard let currentFrame = frame(window) else { return nil }
        guard currentFrame == originalFrame else { diagnostic.stage = "windowGeometryChanged"; return nil }
        guard let currentDisplays = displays() else { return nil }
        guard currentDisplays == originalDisplays else { diagnostic.stage = "displayTopologyChanged"; return nil }
        guard ready() else { return nil }
        diagnostic.stage = "prepared"
        return (focused, AXQtFocusedWindow(window: window, cancellation: cancellation))
    }

    func context(application: EditorApplication, focus: AXUIElement?, spotlight: AXSpotlightFocus? = nil,
                 focusDiscovery initialFocusDiscovery: AXFocusDiscoveryDiagnostic = AXFocusDiscoveryDiagnostic(),
                 cancellation: AttemptCancellation) -> AXEditorContext? {
        let electronPreparation = prepare(application, cancellation: cancellation)
        guard !cancellation.isCancelled else { return nil }
        let policy = EditorCompatibilityPolicy(application: application)
        // Enabling an Electron accessibility tree can replace the focused AX
        // object. Discover it again after prepare instead of using that mirror.
        let app = configured(AXUIElementCreateApplication(application.pid))
        if let spotlight, !systemSpotlightMatches(spotlight, pid: application.pid) { return nil }
        var focusDiscovery = initialFocusDiscovery
        var focused: AXUIElement?
        if let spotlight { focused = spotlight.field }
        else {
            let fresh = focusedElement(app)
            focusDiscovery.application = fresh.diagnostic
            focused = fresh.element ?? focus
        }
        func discover(_ start: AXUIElement?) -> (element: AXUIElement?, snapshot: AXEditorSnapshot?, roles: [String?]) {
            var candidate = start
            var snapshot: AXEditorSnapshot?
            var roles: [String?] = []
            for depth in 0..<6 {
                guard !cancellation.isCancelled, let current = candidate else { break }
                snapshot = read(current, application: application)
                roles.append(snapshot?.role)
                // The verified overlay remains authoritative at this field.
                if spotlight != nil || snapshot?.isSecure == true || snapshot?.range != nil { break }
                guard depth < 5, let parent = snapshot?.parent else { break }
                candidate = parent
            }
            return (candidate, snapshot, roles)
        }
        var discovery = discover(focused)
        let initialFocusRoles = discovery.roles
        var focusPreparation = AXFocusPreparationDiagnostic()
        var qtFocusedWindow: AXQtFocusedWindow?
        if spotlight == nil, focused != nil, discovery.snapshot?.isSecure != true, !cancellation.isCancelled,
           AccessibilityEditorPolicy.needsCanvasFocusPreparation(focusRole: initialFocusRoles.first ?? nil,
                                                                 textRangeFound: discovery.snapshot?.range != nil),
           let prepared = prepareCanvasFocus(application, app: app, cancellation: cancellation, diagnostic: &focusPreparation) {
            focused = prepared
            discovery = discover(focused)
        }
        if application.isQtQuick, !application.isElectron, spotlight == nil,
           discovery.snapshot?.role == kAXApplicationRole,
           discovery.snapshot?.range == nil, discovery.snapshot?.value == nil,
           discovery.snapshot?.isSecure == false, !cancellation.isCancelled {
            if let prepared = prepareQtFocus(application, app: app, cancellation: cancellation, diagnostic: &focusPreparation) {
                focused = prepared.focused
                qtFocusedWindow = prepared.window
                discovery = discover(focused)
            }
        }
        guard !cancellation.isCancelled else { return nil }
        let candidate = discovery.element
        let snapshot = discovery.snapshot
        if spotlight != nil, !SpotlightSearchScope.acceptsDocument(snapshot?.value) { return nil }
        var valueEditable = false
        var valueWriteCapability: AXValueWriteCapability?
        var selectionSettable = false
        if let candidate, snapshot?.range != nil, snapshot?.isSecure != true {
            let key = ElementKey(session: application.session, element: candidate)
            let now = ProcessInfo.processInfo.systemUptime
            var cached = capabilities.value(for: key, at: now) ?? Capabilities()
            if spotlight != nil { cached.selectionSettable = nil }
            if cached.valueWriteCapability == nil {
                var value = DarwinBoolean(false)
                let error = AXUIElementIsAttributeSettable(candidate, kAXValueAttribute as CFString, &value)
                cached.valueWriteCapability = error == .success ? (value.boolValue ? .settable : .notSettable) : .unavailable(error)
            }
            if cached.selectionSettable == nil, policy.canSetSelectionThroughAX(snapshot) {
                var value = DarwinBoolean(false)
                cached.selectionSettable = AXUIElementIsAttributeSettable(candidate, kAXSelectedTextRangeAttribute as CFString, &value) == .success && value.boolValue
            }
            valueWriteCapability = cached.valueWriteCapability
            valueEditable = valueWriteCapability?.allowsWrite == true
            selectionSettable = cached.selectionSettable == true
            let fullySupported = cached.batch && cached.geometrySupported != false && (valueEditable || selectionSettable)
            capabilities.insert(cached, for: key, at: now, lifetime: fullySupported ? 30 : 3)
        }
        return AXEditorContext(application: application, policy: policy, focused: focused, element: candidate,
                               snapshot: snapshot, valueWriteCapability: valueWriteCapability,
                               selectionSettable: selectionSettable,
                               spotlightFocus: spotlight, qtFocusedWindow: qtFocusedWindow,
                               initialFocusRoles: initialFocusRoles, editorDiscoveryRoles: discovery.roles,
                               focusPreparation: focusPreparation, focusDiscovery: focusDiscovery,
                               electronPreparation: electronPreparation)
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
        // Canvas object markers are not proven native attachment offsets.
        // Keep that pre-existing exclusion even when a single-line canvas
        // does not enter the canonical provider below.
        if policy.isCanvasTextEditor(snapshot),
           snapshot.value.map(AccessibilitySelectionPlan.hasTextAttachment) == true ||
            snapshot.selectedText.map(AccessibilitySelectionPlan.hasTextAttachment) == true { return .invalid }
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
    func acknowledgement(_ context: AXEditorContext, replacement: AccessibilityReplacementPlan,
                         cancellation: AttemptCancellation) -> AXSnapshotRead {
        guard focusMatches(context), let editor = context.element else { return .invalid }
        let result = readResult(editor, application: context.application, includeContext: true)
        guard case .snapshot(let snapshot) = result else { return result }
        guard !snapshot.isSecure, context.policy.permitsEditing(snapshot),
              context.policy.isCanvasTextEditor(snapshot) == context.isCanvasTextEditor,
              context.spotlightFocus == nil || SpotlightSearchScope.acceptsDocument(snapshot.value) else { return .invalid }
        // Only an otherwise exact final document/caret can be acknowledged.
        // In an attachment-bearing document, independently prove the replaced
        // logical range; never adopt an expanded/normalized AXValue offset.
        if replacement.confirmsCaret(document: snapshot.value, range: snapshot.range,
                                      selectedText: snapshot.selectedText, selectedRanges: snapshot.selectedRanges) {
            let proof = textScope(context, document: replacement.document, range: replacement.range,
                                  cancellation: cancellation)
            if case .busy = proof { return .busy }
            guard proof.permitsUse else { return .invalid }
        }
        return result
    }

    /// One public, read-only range query for an attachment-bearing document.
    /// The reply is evidence for the already chosen range, never discovery or
    /// an alternative source of document offsets.
    func textScope(_ context: AXEditorContext, document: String, range: NSRange,
                   cancellation: AttemptCancellation) -> AXTextScopeRead {
        guard AccessibilitySelectionPlan.hasTextAttachment(document) else { return .notRequired }
        let expires = ProcessInfo.processInfo.systemUptime + ConversionTiming.attachmentScopeBudget
        func ready() -> AXTextScopeRead? {
            if cancellation.isCancelled { return .cancelled }
            if ProcessInfo.processInfo.systemUptime >= expires { return .timedOut }
            return nil
        }
        if let stopped = ready() { return stopped }
        guard let editor = context.element,
              AccessibilitySelectionPlan.checkedRange(range, in: document) != nil else { return .mismatch }
        var requested = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &requested) else { return .mismatch }
        var value: CFTypeRef?
        if let stopped = ready() { return stopped }
        let error = AXUIElementCopyParameterizedAttributeValue(editor, kAXStringForRangeParameterizedAttribute as CFString,
                                                              parameter, &value)
        if let stopped = ready() { return stopped }
        let failure = error != .success ? error : AccessibilityValue.error(value)
        if failure == .cannotComplete { return .busy }
        if let failure { return .unavailable(failure) }
        return AccessibilitySelectionPlan.confirmsRangeText(AccessibilityValue.usable(value) as? String,
                                                            document: document, range: range) ? .verified : .mismatch
    }

    func focusMatches(_ context: AXEditorContext) -> Bool {
        if let spotlight = context.spotlightFocus { return systemSpotlightMatches(spotlight, pid: context.application.pid) }
        if let window = context.qtFocusedWindow { return qtFocusMatches(context, window: window) }
        guard let current = target(fallbackPID: context.application.pid), current.pid == context.application.pid else { return false }
        if let original = context.focused { return current.focused.map { CFEqual($0, original) } ?? false }
        return false
    }

    /// Recovery never makes an application/window mirror authoritative. Each
    /// later phase requires the same live app/global field and original window.
    private func qtFocusMatches(_ context: AXEditorContext, window: AXQtFocusedWindow) -> Bool {
        let expires = ProcessInfo.processInfo.systemUptime + ConversionTiming.qtFocusProofBudget
        func ready() -> Bool { !window.cancellation.isCancelled && ProcessInfo.processInfo.systemUptime < expires }
        func read(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            guard ready() else { return nil }
            let node = configured(node)
            guard ready() else { return nil }
            let value = attribute(node, name)
            return ready() ? value : nil
        }
        let system = configured(AXUIElementCreateSystemWide())
        let app = configured(AXUIElementCreateApplication(context.application.pid))
        guard let original = context.focused,
              let focused = element(read(system, kAXFocusedUIElementAttribute)), CFEqual(focused, original), ready() else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success, pid == context.application.pid, ready(),
              let appFocus = element(read(app, kAXFocusedUIElementAttribute)), CFEqual(appFocus, focused),
              let currentWindow = element(read(app, kAXFocusedWindowAttribute)), CFEqual(currentWindow, window.window),
              let containingWindow = element(read(focused, kAXWindowAttribute)), CFEqual(containingWindow, window.window),
              ready() else { return false }
        return true
    }

    func validate(_ context: AXEditorContext, document: String? = nil, range: NSRange? = nil, includeContext: Bool = false) -> AXEditorSnapshot? {
        guard focusMatches(context) else { return nil }
        guard let editor = context.element else { return document == nil && range == nil ? context.snapshot : nil }
        guard let snapshot = read(editor, application: context.application, includeContext: includeContext), !snapshot.isSecure,
              context.spotlightFocus == nil || SpotlightSearchScope.acceptsDocument(snapshot.value) else { return nil }
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

    func replacementBackend(_ context: AXEditorContext, snapshot: AXEditorSnapshot, selected: Bool,
                            replacementText: String? = nil) -> TextReplacementBackend {
        if !selected, context.spotlightFocus != nil {
            return context.policy.replacementBackend(for: context.application, snapshot: snapshot, selected: false,
                selectedTextSettable: false, verifiedSpotlightSearch: true,
                queryValueSettable: isEditable(context, snapshot: snapshot), queryRangeSettable: hasNativeRangeSetter(context))
        }
        guard context.policy.replacementBackend(for: context.application, snapshot: snapshot, selected: selected,
                                                selectedTextSettable: true, verifiedSpotlightSearch: context.spotlightFocus != nil,
                                                replacementText: replacementText) == .accessibilitySelectedText,
              let editor = context.element else { return .unicodeEvents }
        var settable = DarwinBoolean(false)
        let supported = AXUIElementIsAttributeSettable(editor, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
        return context.policy.replacementBackend(for: context.application, snapshot: snapshot, selected: selected,
                                                 selectedTextSettable: supported, verifiedSpotlightSearch: context.spotlightFocus != nil,
                                                 replacementText: replacementText)
    }

    func hasNativeRangeSetter(_ context: AXEditorContext) -> Bool {
        guard context.selectionSettable, let editor = context.element else { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(editor, kAXSelectedTextRangeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    /// One selected-fragment setter only. Its success reply is not editor
    /// acknowledgement; ordinary rich editors never get full AXValue writes.
    func replaceSelectedText(_ context: AXEditorContext, selection: AccessibilitySelectionPlan, replacement: String,
                             cancellation: AttemptCancellation) -> Bool? {
        guard !cancellation.isCancelled, TextReplacementBackend.acceptsNativeText(replacement, permitsLineBreaks: context.spotlightFocus == nil),
              let editor = context.element,
              let snapshot = validate(context, document: selection.document, range: selection.range, includeContext: true),
              isEditable(context, snapshot: snapshot),
              selection.matches(document: snapshot.value, range: snapshot.range, selectedText: snapshot.selectedText,
                                selectedRanges: snapshot.selectedRanges),
              textScope(context, document: selection.document, range: selection.range, cancellation: cancellation).permitsUse,
              replacementBackend(context, snapshot: snapshot, selected: true, replacementText: replacement) == .accessibilitySelectedText,
              focusMatches(context),
              !cancellation.isCancelled else { return false }
        let result = AXUIElementSetAttributeValue(editor, kAXSelectedTextAttribute as CFString, replacement as CFString)
        return !cancellation.isCancelled && result == .success
    }

    /// Spotlight may drop fast Backspaces while recomputing search results.
    /// Only the proven plain search field permits one exact query-value write.
    func replaceSpotlightWord(_ context: AXEditorContext, document: String, caret: NSRange,
                              replacement: AccessibilityReplacementPlan, cancellation: AttemptCancellation) -> Bool? {
        guard context.spotlightFocus != nil, !cancellation.isCancelled, let editor = context.element,
              SpotlightSearchScope.wordReplacement(document: document, caret: caret, replacement: replacement.text) == replacement,
              let snapshot = validate(context, document: document, range: caret, includeContext: true),
              AccessibilitySelectionPlan.confirmsCaret(document: snapshot.value, range: snapshot.range,
                  selectedText: snapshot.selectedText, selectedRanges: snapshot.selectedRanges,
                  expectedDocument: document, expectedCaret: caret),
              replacementBackend(context, snapshot: snapshot, selected: false) == .accessibilitySpotlightQuery,
              focusMatches(context), !cancellation.isCancelled else { return false }
        let result = AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, replacement.document as CFString)
        return !cancellation.isCancelled && result == .success
    }

    /// Only the proven Spotlight word path can correct a relocated empty
    /// caret. This never selects a fragment or clears an unexpected selection.
    func restoreCaret(_ context: AXEditorContext, document: String, currentCaret: NSRange, expectedCaret: NSRange,
                      deadline: ReadinessDeadline, cancellation: AttemptCancellation) -> Bool? {
        guard !deadline.expired(at: ProcessInfo.processInfo.systemUptime),
              context.spotlightFocus != nil, currentCaret.length == 0, expectedCaret.length == 0,
              AccessibilitySelectionPlan.checkedRange(expectedCaret, in: document) != nil,
              context.policy.canSetSelectionThroughAX(context.snapshot), context.selectionSettable,
              !cancellation.isCancelled, let editor = context.element,
              let snapshot = validate(context, document: document, range: currentCaret, includeContext: true),
              isEditable(context, snapshot: snapshot),
              context.policy.isCanvasTextEditor(snapshot) == context.isCanvasTextEditor,
              AccessibilitySelectionPlan.confirmsCaret(document: snapshot.value, range: snapshot.range, selectedText: snapshot.selectedText,
                                                       selectedRanges: snapshot.selectedRanges, expectedDocument: document, expectedCaret: currentCaret),
              !cancellation.isCancelled else { return false }
        var value = CFRange(location: expectedCaret.location, length: 0)
        guard let parameter = AXValueCreate(.cfRange, &value),
              hasNativeRangeSetter(context), focusMatches(context), !cancellation.isCancelled,
              !deadline.expired(at: ProcessInfo.processInfo.systemUptime),
              AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, parameter) == .success else { return false }
        guard !cancellation.isCancelled else { return false }
        // A target may apply the range after replying. The coordinator polls
        // the exact document/empty caret within its original fixed budget.
        return true
    }

    func bounds(_ context: AXEditorContext, range: NSRange) -> CGRect? {
        guard context.spotlightFocus == nil || focusMatches(context) else { return nil }
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
