import AppKit
import ApplicationServices
import Carbon
import SwitcherCore

/// Explicit, finite observation only. A notification or AXFocused boolean never
/// supplies conversion authority; this object has no connection to the editor.
final class MaxFocusDiagnostic {
    private static let bundleID = "ru.oneme.desktop"
    private let worker = DispatchQueue(label: "SSwitcher.MAX-focus-diagnostic", qos: .utility)
    private var activationObserver: NSObjectProtocol?
    private var armTimeout: DispatchWorkItem?
    private var control: Control?
    private var targetPID: pid_t?
    private var workerStarted = false
    private var latest: [String: Any] = [:]
    private(set) var status = "Проверка поля MAX: не запускалась"

    /// Main-thread UI entry; never activates MAX or requests a permission.
    func start() {
        cancel()
        guard AXIsProcessTrusted() else {
            publish(["stage": "accessibilityDenied"]); return
        }
        guard !IsSecureEventInputEnabled() else {
            publish(["stage": "secureInput"]); return
        }
        let request = Control()
        control = request
        workerStarted = false
        publish(["stage": "armed"])
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.foregroundChanged(request) }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.control === request, self.targetPID == nil else { return }
            self.finish(request, report: ["stage": "activationTimedOut"])
        }
        armTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
        foregroundChanged(request)
    }

    func cancel() {
        guard let request = control else { return }
        request.stop("cancelled")
        detachMain()
        if workerStarted { status = "Проверка MAX отменена" }
        else { var report = latest; report["stage"] = "cancelled"; finish(request, report: report) }
    }

    private func foregroundChanged(_ request: Control) {
        guard control === request else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let targetPID {
            guard frontmost?.bundleIdentifier == Self.bundleID,
                  frontmost?.processIdentifier == targetPID else {
                request.stop("foregroundChanged")
                detachMain()
                status = "Проверка MAX остановлена: активно другое приложение"
                // Keep this generation until its worker returns the last full
                // sample. A later start replaces control and rejects that reply.
                return
            }
            return
        }
        guard let app = frontmost, app.bundleIdentifier == Self.bundleID, !app.isTerminated else { return }
        targetPID = app.processIdentifier
        workerStarted = true
        armTimeout?.cancel(); armTimeout = nil
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        publish(["stage": "observing"])
        let pid = app.processIdentifier
        worker.async { [weak self] in
            let session = Session(pid: pid, control: request, expiresAt: deadline)
            let report = session.run()
            DispatchQueue.main.async { [weak self] in self?.finish(request, report: report) }
        }
    }

    private func finish(_ request: Control, report: [String: Any]) {
        guard control === request else { return }
        var completed = report
        if request.isCancelled { completed["stage"] = request.stopReason }
        request.stop("cancelled")
        detachMain()
        control = nil
        workerStarted = false
        publish(completed)
    }

    private func detachMain() {
        armTimeout?.cancel(); armTimeout = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        targetPID = nil
    }

    deinit {
        control?.stop("cancelled")
        armTimeout?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    private func publish(_ report: [String: Any]) {
        latest = report
        latest["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        latest["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        UserDefaults.standard.set(latest, forKey: "MaxFocusDiagnosticReport")
        switch report["stage"] as? String {
        case "armed": status = "Проверка MAX: перейдите в MAX в течение минуты"
        case "observing": status = "Проверка MAX: наблюдаю фокус поля до 20 секунд"
        case "accessibilityDenied": status = "Проверка MAX: нет разрешения на Универсальный доступ"
        case "secureInput": status = "Проверка MAX остановлена: защищённый ввод"
        case "activationTimedOut": status = "Проверка MAX: время ожидания приложения истекло"
        case "foregroundChanged": status = "Проверка MAX остановлена: активно другое приложение"
        case "windowChanged": status = "Проверка MAX остановлена: активное окно изменилось"
        case "cancelled": status = "Проверка MAX отменена"
        default:
            if report["candidateRole"] as? String == "textArea" || report["candidateRole"] as? String == "textField" {
                status = "Проверка MAX: получен элемент поля; содержимое не читалось"
            } else if report["candidateRole"] as? String == "window" {
                status = "Проверка MAX: фокус указывает на окно; содержимое не читалось"
            } else {
                status = "Проверка MAX завершена: доступный фокус поля не подтверждён"
            }
        }
    }

    /// Cancellation wakes only this explicitly armed worker run loop. The
    /// lock is never held across AX IPC, UI work or an observer callback.
    private final class Control {
        private let lock = NSLock()
        private var cancelled = false
        private var reason = "cancelled"
        private var loop: CFRunLoop?
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        var stopReason: String { lock.lock(); defer { lock.unlock() }; return reason }
        func attach(_ loop: CFRunLoop) {
            lock.lock(); self.loop = loop; let stopped = cancelled; lock.unlock()
            if stopped { CFRunLoopStop(loop) }
        }
        func detach() { lock.lock(); loop = nil; lock.unlock() }
        func stop(_ reason: String) {
            lock.lock()
            if !cancelled { self.reason = reason }
            cancelled = true; let current = loop; lock.unlock()
            if let current { CFRunLoopStop(current); CFRunLoopWakeUp(current) }
        }
    }

    /// All remote AX calls and callbacks stay on one worker. The run() stack
    /// retains self until every registration/source has been detached.
    private final class Session {
        private let pid: pid_t
        private let control: Control
        private let expiresAt: Double
        private let app: AXUIElement
        private let system = AXUIElementCreateSystemWide()
        private var window: AXUIElement?
        private var observer: AXObserver?
        private var windowFocusReadAttempted = false
        private var windowFocusEntry: AXUIElement?
        private var registrations: [(AXUIElement, CFString)] = []
        private var sampleDeadline: ReadinessDeadline?
        private var callbacks = 0
        private var terminal = false
        private var report: [String: Any] = ["stage": "observing", "callbackCount": 0]
        private let mode = CFRunLoopMode(rawValue: "SSwitcherMAXFocusDiagnostic" as CFString)

        init(pid: pid_t, control: Control, expiresAt: Double) {
            self.pid = pid; self.control = control; self.expiresAt = expiresAt
            app = AXUIElementCreateApplication(pid)
        }

        func run() -> [String: Any] {
            beginSample()
            guard ready(), AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return report }
            guard let original = element(app, kAXFocusedWindowAttribute, key: "initialWindowRead"), owned(original),
                  role(original, key: "initialWindowRole") == "window", ready() else {
                if !terminal { stop("focusedWindowUnavailable") }
                return report
            }
            window = original
            report["initialWindowRole"] = "window"
            var created: AXObserver?
            let error = AXObserverCreate(pid, { _, element, notification, refcon in
                guard let refcon else { return }
                Unmanaged<Session>.fromOpaque(refcon).takeUnretainedValue().received(element, notification)
            }, &created)
            report["observerError"] = error.rawValue
            guard ready(), error == .success, let created else {
                if !terminal { stop("observerUnavailable") }; return report
            }
            observer = created
            register(app, kAXFocusedUIElementChangedNotification, key: "appFocusNotification")
            register(original, kAXFocusedUIElementChangedNotification, key: "windowFocusNotification")
            register(app, kAXFocusedWindowChangedNotification, key: "windowChangeNotification")
            register(original, kAXUIElementDestroyedNotification, key: "windowDestroyedNotification")
            let loop = CFRunLoopGetCurrent()!
            let source = AXObserverGetRunLoopSource(created)
            CFRunLoopAddSource(loop, source, mode)
            control.attach(loop)
            defer {
                for (element, notification) in registrations { AXObserverRemoveNotification(created, element, notification) }
                CFRunLoopRemoveSource(loop, source, mode)
                control.detach()
            }
            sample(nil, startNewDeadline: false)
            if !terminal, !control.isCancelled {
                let remaining = expiresAt - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { CFRunLoopRunInMode(mode, remaining, false) }
            }
            if !terminal { stop(control.isCancelled ? control.stopReason : "observationTimedOut") }
            return report
        }

        private func register(_ element: AXUIElement, _ notification: String, key: String) {
            guard ready(), let observer, setTimeout(element, key: key) else { return }
            let error = AXObserverAddNotification(observer, element, notification as CFString,
                                                  Unmanaged.passUnretained(self).toOpaque())
            report[key] = error == .success
            report[key + "Error"] = error.rawValue
            if error == .success { registrations.append((element, notification as CFString)) }
            _ = ready()
        }

        private func received(_ candidate: AXUIElement, _ notification: CFString) {
            guard !terminal, !control.isCancelled else { return }
            callbacks += 1
            report["callbackCount"] = callbacks
            let name = notification as String
            report["notification"] = name == kAXFocusedUIElementChangedNotification ? "focusChanged" :
                name == kAXFocusedWindowChangedNotification ? "windowChanged" : "windowDestroyed"
            if name == kAXFocusedWindowChangedNotification || name == kAXUIElementDestroyedNotification {
                stop("windowChanged"); return
            }
            sample(candidate)
            if callbacks >= 6, !terminal { stop("callbackLimit") }
        }

        private func beginSample() {
            let now = ProcessInfo.processInfo.systemUptime
            sampleDeadline = ReadinessDeadline(start: now, timeout: max(0, min(0.6, expiresAt - now)))
        }

        private func ready() -> Bool {
            guard !terminal else { return false }
            if control.isCancelled { stop(control.stopReason); return false }
            let now = ProcessInfo.processInfo.systemUptime
            if now >= expiresAt { stop("observationTimedOut"); return false }
            if sampleDeadline?.expired(at: now) == true { stop("sampleTimedOut"); return false }
            if !AXIsProcessTrusted() { stop("accessibilityDenied"); return false }
            if IsSecureEventInputEnabled() { stop("secureInput"); return false }
            return true
        }

        private func stop(_ stage: String) {
            terminal = true; report["stage"] = stage
            CFRunLoopStop(CFRunLoopGetCurrent())
        }

        private func owned(_ element: AXUIElement) -> Bool {
            guard ready() else { return false }
            var owner: pid_t = 0
            let error = AXUIElementGetPid(element, &owner)
            guard ready() else { return false }
            return error == .success && owner == pid
        }

        private func read(_ element: AXUIElement, _ attribute: String, key: String) -> CFTypeRef? {
            guard ready(), setTimeout(element, key: key) else { return nil }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            guard ready() else { return nil }
            if error != .success || AccessibilityValue.error(value) != nil {
                report[key] = "failed"; report[key + "Error"] = (AccessibilityValue.error(value) ?? error).rawValue
                return nil
            }
            report.removeValue(forKey: key + "Error")
            report[key] = AccessibilityValue.usable(value) == nil ? "absent" : "available"
            return AccessibilityValue.usable(value)
        }

        private func element(_ source: AXUIElement, _ attribute: String, key: String) -> AXUIElement? {
            guard let value = read(source, attribute, key: key) else { return nil }
            let reply = AccessibilityElementReply(error: .success, value: value)
            report[key] = reply.status.rawValue
            return reply.element
        }

        private func role(_ element: AXUIElement, key: String) -> String {
            guard let value = read(element, kAXRoleAttribute, key: key + "Read") as? String else { return "absent" }
            switch value {
            case kAXTextAreaRole: return "textArea"
            case kAXTextFieldRole: return "textField"
            case kAXComboBoxRole: return "comboBox"
            case kAXWindowRole: return "window"
            case kAXApplicationRole: return "application"
            case kAXGroupRole: return "group"
            case kAXStaticTextRole: return "staticText"
            case kAXUnknownRole: return "unknown"
            default: return "other"
            }
        }

        private func names(_ element: AXUIElement, parameterized: Bool, key: String) -> Set<String>? {
            guard ready(), setTimeout(element, key: key) else { return nil }
            var raw: CFArray?
            let error = parameterized ? AXUIElementCopyParameterizedAttributeNames(element, &raw) :
                AXUIElementCopyAttributeNames(element, &raw)
            guard ready() else { return nil }
            report[key + "Error"] = error.rawValue
            guard error == .success, let raw, CFArrayGetCount(raw) <= 128, let values = raw as? [String] else {
                report[key] = "unavailable"; return nil
            }
            report[key] = "available"
            // Names are used only against this fixed whitelist; never saved raw.
            return Set(values)
        }

        private func capability(_ element: AXUIElement, _ attribute: String, key: String) {
            guard ready(), setTimeout(element, key: key) else { return }
            var writable = DarwinBoolean(false)
            let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &writable)
            guard ready() else { return }
            report[key] = error == .success ? (writable.boolValue ? "settable" : "notSettable") : "unavailable"
            report[key + "Error"] = error.rawValue
        }

        private func setTimeout(_ element: AXUIElement, key: String) -> Bool {
            guard ready(), let sampleDeadline else { return false }
            let remaining = min(expiresAt, sampleDeadline.expiresAt) - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { _ = ready(); return false }
            // Shorten IPC to the remaining immutable sample/observation budget.
            // This configures messaging, not an Accessibility attribute.
            let error = AXUIElementSetMessagingTimeout(element, Float(min(0.12, remaining)))
            guard ready() else { return false }
            if error != .success {
                report[key] = "timeoutUnavailable"; report[key + "Error"] = error.rawValue
                return false
            }
            return true
        }

        private func sample(_ eventCandidate: AXUIElement?, startNewDeadline: Bool = true) {
            if startNewDeadline { beginSample() }
            for key in Array(report.keys) where key.hasPrefix("candidate") || key.hasPrefix("has") ||
                key.hasPrefix("valueCapability") || key.hasPrefix("selectedTextCapability") {
                report.removeValue(forKey: key)
            }
            guard ready(), let window else { return }
            guard let currentWindow = element(app, kAXFocusedWindowAttribute, key: "currentWindowRead"), owned(currentWindow) else {
                if !terminal { stop("focusedWindowUnavailable") }; return
            }
            guard CFEqual(currentWindow, window) else { stop("windowChanged"); return }
            let appFocus = element(app, kAXFocusedUIElementAttribute, key: "appFocusRead")
            let globalFocus = element(system, kAXFocusedUIElementAttribute, key: "globalFocusRead")
            let appOwned = appFocus.map(owned) ?? false
            let globalOwned = globalFocus.map(owned) ?? false
            report["appFocusOwned"] = appOwned; report["globalFocusOwned"] = globalOwned
            report["appGlobalFocusEqual"] = appOwned && globalOwned && CFEqual(appFocus!, globalFocus!)
            report["appFocusRole"] = appOwned ? role(appFocus!, key: "appFocusRole") : "unavailable"
            report["globalFocusRole"] = globalOwned ? role(globalFocus!, key: "globalFocusRole") : "unavailable"
            guard ready() else { return }
            if !windowFocusReadAttempted {
                windowFocusReadAttempted = true
                if let available = names(window, parameterized: false, key: "windowAttributes") {
                    report["windowFocusAdvertised"] = available.contains(kAXFocusedUIElementAttribute)
                }
                // Qt's public window entry can exist even if the name catalogue
                // omits it. Read this known key once, never retry or adopt it.
                windowFocusEntry = element(window, kAXFocusedUIElementAttribute, key: "windowFocusRead")
                let sameOwner = windowFocusEntry.map(owned) ?? false
                report["windowFocusOwned"] = sameOwner
                report["windowFocusRole"] = sameOwner ? role(windowFocusEntry!, key: "windowFocusRole") : "unavailable"
                report["windowFocusEqualsAppAtRead"] = sameOwner && appOwned && CFEqual(windowFocusEntry!, appFocus!)
                report["windowFocusEqualsGlobalAtRead"] = sameOwner && globalOwned && CFEqual(windowFocusEntry!, globalFocus!)
            }
            guard ready() else { return }
            let candidate = eventCandidate ?? (appOwned ? appFocus : nil)
            guard let candidate else { report["candidateRole"] = "unavailable"; return }
            let candidateOwned = owned(candidate)
            report["candidateOwned"] = candidateOwned
            guard candidateOwned else { report["candidateRole"] = "unavailable"; return }
            report["candidateOrigin"] = eventCandidate == nil ? "currentFocus" : "notification"
            let candidateRole = role(candidate, key: "candidateRole")
            report["candidateRole"] = candidateRole
            let subrole = read(candidate, kAXSubroleAttribute, key: "candidateSubroleRead") as? String
            report["candidateSubrole"] = subrole == nil ? "absent" :
                subrole == kAXSecureTextFieldSubrole ? "secureTextField" : "other"
            if let value = read(candidate, kAXFocusedAttribute, key: "candidateFocusedRead"), CFGetTypeID(value) == CFBooleanGetTypeID() {
                report["candidateFocused"] = CFBooleanGetValue((value as! CFBoolean))
            } else { report.removeValue(forKey: "candidateFocused") }
            let containing = CFEqual(candidate, window) ? window : element(candidate, kAXWindowAttribute, key: "candidateWindowRead")
            report["candidateSameWindow"] = containing.map { owned($0) && CFEqual($0, window) } ?? false
            report["candidateEqualsAppFocus"] = appOwned && CFEqual(candidate, appFocus!)
            report["candidateEqualsGlobalFocus"] = globalOwned && CFEqual(candidate, globalFocus!)
            // An earlier window reply is explicitly historical metadata, not a
            // fresh-focus assertion or a retained candidate for conversion.
            report["candidateEqualsInitialWindowEntry"] = windowFocusEntry.map { CFEqual($0, candidate) } ?? false
            guard ready() else { return }
            if let available = names(candidate, parameterized: false, key: "candidateAttributes") {
                for (key, name) in ["hasValue": kAXValueAttribute, "hasSelectedText": kAXSelectedTextAttribute,
                                    "hasSelectedRange": kAXSelectedTextRangeAttribute, "hasSelectedRanges": kAXSelectedTextRangesAttribute,
                                    "hasFocused": kAXFocusedAttribute, "hasWindow": kAXWindowAttribute, "hasChildren": kAXChildrenAttribute] {
                    report[key] = available.contains(name)
                }
            }
            if let available = names(candidate, parameterized: true, key: "candidateParameterizedAttributes") {
                report["hasStringForRange"] = available.contains(kAXStringForRangeParameterizedAttribute)
                report["hasBoundsForRange"] = available.contains(kAXBoundsForRangeParameterizedAttribute)
            }
            if subrole != kAXSecureTextFieldSubrole, candidateRole == "textArea" || candidateRole == "textField" {
                capability(candidate, kAXValueAttribute, key: "valueCapability")
                capability(candidate, kAXSelectedTextAttribute, key: "selectedTextCapability")
            }
            _ = ready()
        }
    }
}
