import ApplicationServices
import AppKit
import Foundation
import SwitcherCore

/// Reads only the application's native menu hierarchy. No menu is opened and
/// no action is performed. Discovery is not editor or replacement authority.
enum NativeServiceMenuResolver {
    static let selectionTitle = "SSwitcher: преобразовать выделение"
    static let editableTitle = "SSwitcher: проверить ввод MAX"
    static let readonlyTitle = "SSwitcher: проверить нативную замену"

    static func windowNumber(_ window: AXUIElement, pid: pid_t) -> Int? {
        guard let bounds = windowBounds(window, pid: pid),
              let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let matches = entries.compactMap { entry -> Int? in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary),
                  abs(rect.minX - bounds.minX) <= 2, abs(rect.minY - bounds.minY) <= 2,
                  abs(rect.width - bounds.width) <= 2, abs(rect.height - bounds.height) <= 2,
                  let number = entry[kCGWindowNumber as String] as? NSNumber, number.intValue > 0 else { return nil }
            return number.intValue
        }
        return matches.count == 1 ? matches[0] : nil
    }

    struct Result {
        var item: AXUIElement?
        var report: [String: Any]
        var hasNoSelectionCapability: Bool {
            item == nil && report["stage"] as? String == "unavailable" &&
                report["bounded"] as? Bool == false && report["AXError"] == nil &&
                report["ambiguous"] as? Bool == false && report["menuBar"] as? Bool == true &&
                report["applicationMenu"] as? Bool == true
        }
    }

    static func isOnBuiltInDisplay(_ window: AXUIElement, pid: pid_t) -> Bool {
        builtInWindowBounds(window, pid: pid) != nil
    }

    private static func windowBounds(_ window: AXUIElement, pid: pid_t,
                                     report: (([String: Any]) -> Void)? = nil) -> CGRect? {
        let reader = Reader(pid: pid, cancellation: AttemptCancellation(), timeout: 0.2, queryLimit: 8)
        guard let rawPoint = reader.value(window, kAXPositionAttribute),
              let rawSize = reader.value(window, kAXSizeAttribute),
              CFGetTypeID(rawPoint) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else {
            var result: [String: Any] = ["stage": "windowBoundsUnavailable", "bounded": reader.bounded]
            if let failure = reader.failure { result["AXError"] = failure.rawValue }
            report?(result); return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((rawPoint as! AXValue), .cgPoint, &origin),
              AXValueGetValue((rawSize as! AXValue), .cgSize, &size), reader.ready else {
            report?(["stage": "windowBoundsInvalid"]); return nil
        }
        let bounds = CGRect(origin: origin, size: size)
        guard WindowTransferPlan.valid(bounds) else { return nil }
        return bounds
    }

    /// Only explicit automated diagnostics are limited to the built-in screen.
    /// Normal user-triggered conversion resolves the same owned window anywhere.
    static func builtInWindowBounds(_ window: AXUIElement, pid: pid_t,
                                    report: (([String: Any]) -> Void)? = nil) -> CGRect? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displays, &count) == .success,
              let builtIn = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            report?(["stage": "builtInDisplayUnavailable"]); return nil
        }
        guard let bounds = windowBounds(window, pid: pid, report: report) else { return nil }
        let display = CGDisplayBounds(builtIn)
        let contained = display.insetBy(dx: -2, dy: -2).contains(bounds)
        let intersection = display.intersection(bounds)
        report?(["stage": contained ? "builtInWindowConfirmed" : "windowOutsideBuiltIn",
            "overflowPoints": max(0, display.minX - bounds.minX, bounds.maxX - display.maxX,
                                  display.minY - bounds.minY, bounds.maxY - display.maxY),
            "overlapPercent": intersection.isNull ? 0 : Int(100 * intersection.width * intersection.height / (bounds.width * bounds.height))])
        return contained ? bounds : nil
    }

    static func inspect(pid: pid_t, cancellation: AttemptCancellation, inspectEditor: Bool = false,
                        serviceTitle: String = selectionTitle) -> Result {
        let reader = Reader(pid: pid, cancellation: cancellation, serviceTitle: serviceTitle)
        let result = reader.inspect()
        guard inspectEditor else { return result }
        let editorReader = Reader(pid: pid, cancellation: cancellation, timeout: 3, queryLimit: 768)
        editorReader.inspectEditorAtPointer()
        editorReader.inspectEditorTree()
        var combined = result.report
        for (key, value) in editorReader.report where key.hasPrefix("editor") { combined[key] = value }
        return Result(item: result.item, report: combined)
    }

    /// One native action after fresh ownership, window and menu capability
    /// checks. An issued action is never retried, regardless of its AX reply.
    static func press(_ item: AXUIElement, pid: pid_t, window: AXUIElement,
                      cancellation: AttemptCancellation, serviceTitle: String = selectionTitle) -> AXError? {
        let reader = Reader(pid: pid, cancellation: cancellation)
        guard reader.role(item) == kAXMenuItemRole,
              (reader.value(item, kAXTitleAttribute) as? String) == serviceTitle,
              let enabled = reader.value(item, kAXEnabledAttribute),
              CFGetTypeID(enabled) == CFBooleanGetTypeID(), CFBooleanGetValue((enabled as! CFBoolean)) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let rawWindow = reader.value(app, kAXFocusedWindowAttribute),
              let currentWindow = AccessibilityElementReply(error: .success, value: rawWindow).element,
              reader.owned(currentWindow), CFEqual(currentWindow, window), reader.ready else { return nil }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(item, &actions) == .success,
              (actions as? [String])?.contains(kAXPressAction) == true, reader.ready,
              AXUIElementSetMessagingTimeout(item, 0.8) == .success, reader.ready else { return nil }
        return AXUIElementPerformAction(item, kAXPressAction as CFString)
    }

    private final class Reader {
        let pid: pid_t
        let cancellation: AttemptCancellation
        let deadline: ReadinessDeadline
        let queryLimit: Int
        let serviceTitle: String
        var queries = 0
        var failure: AXError?
        var bounded = false
        var report: [String: Any] = ["menuBar": false, "applicationMenu": false, "serviceFound": false]

        init(pid: pid_t, cancellation: AttemptCancellation, timeout: Double = 2, queryLimit: Int = 180,
             serviceTitle: String = selectionTitle) {
            self.pid = pid
            self.cancellation = cancellation
            self.deadline = ReadinessDeadline(start: ProcessInfo.processInfo.systemUptime, timeout: timeout)
            self.queryLimit = queryLimit
            self.serviceTitle = serviceTitle
        }

        var ready: Bool {
            !cancellation.isCancelled && queries < queryLimit && !deadline.expired(at: ProcessInfo.processInfo.systemUptime)
        }

        func owned(_ element: AXUIElement) -> Bool {
            var owner: pid_t = 0
            return ready && AXUIElementGetPid(element, &owner) == .success && owner == pid
        }

        func value(_ element: AXUIElement, _ attribute: String, optional: Bool = false) -> CFTypeRef? {
            guard owned(element) else { bounded = true; return nil }
            let remaining = deadline.expiresAt - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { bounded = true; return nil }
            let timeout = AXUIElementSetMessagingTimeout(element, Float(min(0.08, remaining)))
            guard timeout == .success else { failure = timeout; return nil }
            queries += 1
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
            guard ready else { bounded = true; return nil }
            guard error == .success else {
                if !optional || (error != .noValue && error != .attributeUnsupported) { failure = error }
                return nil
            }
            if let error = AccessibilityValue.error(raw) { failure = error; return nil }
            return AccessibilityValue.usable(raw)
        }

        func role(_ element: AXUIElement) -> String? { value(element, kAXRoleAttribute) as? String }

        func children(_ element: AXUIElement) -> [AXUIElement] {
            guard let raw = value(element, kAXChildrenAttribute, optional: true),
                  CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
            let array = raw as! CFArray
            guard CFArrayGetCount(array) <= 64 else { bounded = true; return [] }
            return (array as [AnyObject]).compactMap {
                guard CFGetTypeID($0) == AXUIElementGetTypeID() else { return nil }
                return ($0 as! AXUIElement)
            }
        }

        /// Explicit diagnostic only. The pointer must be in MAX's window on
        /// the built-in display. No text, coordinates or attribute names leave
        /// this reader; a hit is discovery, never editing authority.
        func inspectEditorAtPointer() {
            report["editorProbe"] = "unavailable"
            var displays = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(16, &displays, &count) == .success,
                  let builtIn = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }),
                  let point = CGEvent(source: nil)?.location, CGDisplayBounds(builtIn).contains(point) else {
                report["editorProbe"] = "outsideBuiltInDisplay"; return
            }
            let app = AXUIElementCreateApplication(pid)
            guard let rawWindow = value(app, kAXFocusedWindowAttribute),
                  let window = AccessibilityElementReply(error: .success, value: rawWindow).element,
                  let rawPoint = value(window, kAXPositionAttribute),
                  let rawSize = value(window, kAXSizeAttribute),
                  CFGetTypeID(rawPoint) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return }
            var origin = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue((rawPoint as! AXValue), .cgPoint, &origin),
                  AXValueGetValue((rawSize as! AXValue), .cgSize, &size),
                  CGRect(origin: origin, size: size).contains(point), ready else {
                report["editorProbe"] = "outsideMAXWindow"; return
            }
            guard AXUIElementSetMessagingTimeout(app, 0.08) == .success, ready else { return }
            queries += 1
            var hit: AXUIElement?
            let error = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
            report["editorProbeError"] = error.rawValue
            guard error == .success, let hit, owned(hit), let actualRole = role(hit) else { return }
            let roles = [kAXTextAreaRole: "textArea", kAXTextFieldRole: "textField",
                         kAXWindowRole: "window", kAXGroupRole: "group", kAXApplicationRole: "application"]
            report["editorHitRole"] = roles[actualRole] ?? "other"
            if let focused = value(hit, kAXFocusedAttribute, optional: true), CFGetTypeID(focused) == CFBooleanGetTypeID() {
                report["editorHitFocused"] = CFBooleanGetValue((focused as! CFBoolean))
            }
            guard ready else { return }
            queries += 1
            var rawNames: CFArray?
            let namesError = AXUIElementCopyAttributeNames(hit, &rawNames)
            report["editorAttributeError"] = namesError.rawValue
            guard namesError == .success, let names = rawNames as? [String], names.count <= 128, ready else { return }
            report["editorValueAdvertised"] = names.contains(kAXValueAttribute)
            report["editorRangeAdvertised"] = names.contains(kAXSelectedTextRangeAttribute)
            report["editorSelectedTextAdvertised"] = names.contains(kAXSelectedTextAttribute)
            report["editorProbe"] = "metadataRead"
        }

        func inspectEditorTree() {
            var displays = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(16, &displays, &count) == .success,
                  let builtIn = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return }
            let app = AXUIElementCreateApplication(pid)
            guard let rawWindow = value(app, kAXFocusedWindowAttribute),
                  let window = AccessibilityElementReply(error: .success, value: rawWindow).element,
                  let rawPoint = value(window, kAXPositionAttribute),
                  let rawSize = value(window, kAXSizeAttribute),
                  CFGetTypeID(rawPoint) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return }
            var origin = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue((rawPoint as! AXValue), .cgPoint, &origin),
                  AXValueGetValue((rawSize as! AXValue), .cgSize, &size), size.width > 0, size.height > 0,
                  CGDisplayBounds(builtIn).contains(CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)) else {
                report["editorTree"] = "outsideBuiltInDisplay"; return
            }
            var pending = [(window, 0)]
            var visited: [AXUIElement] = []
            var textCandidates = 0
            var focusedCandidates = 0
            var textInterfaces = 0
            var usableRanges = 0
            var editableTextInterfaces = 0
            var focusedTextInterfaces = 0
            while !pending.isEmpty && ready && !bounded {
                let (element, depth) = pending.removeFirst()
                guard depth <= 12, visited.count < 192 else { bounded = true; break }
                if visited.contains(where: { CFEqual($0, element) }) { continue }
                visited.append(element)
                guard owned(element), role(element) != nil, ready else { continue }
                queries += 1
                var rawNames: CFArray?
                let error = AXUIElementCopyAttributeNames(element, &rawNames)
                if error == .success, let names = rawNames as? [String], names.count <= 128,
                   names.contains(kAXValueAttribute), names.contains(kAXSelectedTextRangeAttribute) {
                    textCandidates += 1
                    var focused = false
                    if let flag = value(element, kAXFocusedAttribute, optional: true),
                       CFGetTypeID(flag) == CFBooleanGetTypeID() {
                        focused = CFBooleanGetValue((flag as! CFBoolean))
                        if focused { focusedCandidates += 1 }
                    }
                    guard ready else { break }
                    queries += 1
                    var rawParameters: CFArray?
                    let parametersError = AXUIElementCopyParameterizedAttributeNames(element, &rawParameters)
                    if parametersError == .success, let parameters = rawParameters as? [String],
                       parameters.count <= 128, parameters.contains(kAXStringForRangeParameterizedAttribute) {
                        textInterfaces += 1
                        if focused { focusedTextInterfaces += 1 }
                        if let rawRange = value(element, kAXSelectedTextRangeAttribute, optional: true),
                           CFGetTypeID(rawRange) == AXValueGetTypeID(),
                           AXValueGetType((rawRange as! AXValue)) == .cfRange {
                            var range = CFRange()
                            if AXValueGetValue((rawRange as! AXValue), .cfRange, &range),
                               range.location >= 0, range.length >= 0,
                               range.location <= Int.max - range.length { usableRanges += 1 }
                        }
                        if ready {
                            queries += 1
                            var settable = DarwinBoolean(false)
                            if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
                               settable.boolValue { editableTextInterfaces += 1 }
                        }
                    }
                }
                pending.append(contentsOf: children(element).map { ($0, depth + 1) })
            }
            report["editorTree"] = pending.isEmpty && !bounded && ready ? "complete" : "bounded"
            report["editorTreeNodes"] = visited.count
            report["editorTextCandidates"] = textCandidates
            report["editorFocusedCandidates"] = focusedCandidates
            // No value, selected text or range coordinates are persisted.
            // These counts diagnose actual getters/interfaces; they authorize
            // no edit and are never used by the normal conversion route.
            report["editorTextInterfaces"] = textInterfaces
            report["editorUsableRanges"] = usableRanges
            report["editorEditableTextInterfaces"] = editableTextInterfaces
            report["editorFocusedTextInterfaces"] = focusedTextInterfaces
        }

        func inspect() -> Result {
            let app = AXUIElementCreateApplication(pid)
            guard role(app) == kAXApplicationRole,
                  let raw = value(app, kAXMenuBarAttribute),
                  let menuBar = AccessibilityElementReply(error: .success, value: raw).element,
                  role(menuBar) == kAXMenuBarRole else { return finish(nil) }
            report["menuBar"] = true
            let appItems = children(menuBar).filter {
                role($0) == kAXMenuBarItemRole && (value($0, kAXTitleAttribute) as? String) == "MAX"
            }
            guard appItems.count == 1, let appItem = appItems.first else { return finish(nil) }
            report["applicationMenu"] = true
            var pending = children(appItem).map { ($0, 0) }
            var visited: [AXUIElement] = []
            var matches: [AXUIElement] = []
            while !pending.isEmpty && ready && !bounded {
                let (element, depth) = pending.removeFirst()
                guard depth <= 5, visited.count < 64 else { bounded = true; break }
                if visited.contains(where: { CFEqual($0, element) }) { continue }
                visited.append(element)
                guard let role = role(element), role == kAXMenuRole || role == kAXMenuItemRole else { continue }
                if role == kAXMenuItemRole, (value(element, kAXTitleAttribute) as? String) == serviceTitle {
                    matches.append(element)
                }
                pending.append(contentsOf: children(element).map { ($0, depth + 1) })
            }
            report["ambiguous"] = matches.count > 1
            guard matches.count == 1, let item = matches.first, ready, !bounded, failure == nil else { return finish(nil) }
            report["serviceFound"] = true
            if serviceTitle == NativeServiceMenuResolver.editableTitle || serviceTitle == NativeServiceMenuResolver.readonlyTitle {
                let character = value(item, kAXMenuItemCmdCharAttribute, optional: true) as? String
                let expected = serviceTitle == NativeServiceMenuResolver.editableTitle ? "\u{f717}" : "\u{f716}"
                report["probeShortcutDeclared"] = character?.utf16.elementsEqual(expected.utf16) == true
                report["probeShortcutEmpty"] = character?.isEmpty ?? true
                if let modifiers = value(item, kAXMenuItemCmdModifiersAttribute, optional: true) as? NSNumber {
                    report["probeShortcutModifiers"] = modifiers.intValue
                }
            }
            let rawEnabled = value(item, kAXEnabledAttribute)
            let enabled = rawEnabled.map { CFGetTypeID($0) == CFBooleanGetTypeID() && CFBooleanGetValue(($0 as! CFBoolean)) } ?? false
            report["enabled"] = enabled
            guard ready, owned(item) else { return finish(nil) }
            queries += 1
            var names: CFArray?
            let error = AXUIElementCopyActionNames(item, &names)
            if error != .success { failure = error }
            let press = error == .success && (names as? [String])?.contains(kAXPressAction) == true
            report["pressSupported"] = press
            return finish(enabled && press && ready && failure == nil ? item : nil)
        }

        func finish(_ item: AXUIElement?) -> Result {
            report["stage"] = item != nil ? "available" : (bounded || !ready || failure != nil ? "incomplete" : "unavailable")
            report["queries"] = queries
            report["cancelled"] = cancellation.isCancelled
            report["bounded"] = bounded || deadline.expired(at: ProcessInfo.processInfo.systemUptime)
            if let failure { report["AXError"] = failure.rawValue }
            return Result(item: item, report: report)
        }
    }
}
