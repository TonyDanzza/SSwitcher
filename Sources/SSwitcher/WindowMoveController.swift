import AppKit
import ApplicationServices
import SwitcherCore

private struct WindowScreenSnapshot: Equatable {
    let displays: [WindowDisplay]
    let primaryTop: CGFloat
    static func capture() -> Self? {
        dispatchPrecondition(condition: .onQueue(.main))
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }
        let top = primary.frame.maxY
        var displays: [WindowDisplay] = []
        for screen in screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            displays.append(WindowDisplay(id: id.uint32Value,
                frame: WindowTransferPlan.accessibilityRect(fromAppKit: screen.frame, primaryTop: top),
                visibleFrame: WindowTransferPlan.accessibilityRect(fromAppKit: screen.visibleFrame, primaryTop: top)))
        }
        return Self(displays: displays, primaryTop: top)
    }
}

private struct WindowAXContext {
    let pid: pid_t
    let application: AXUIElement
    let window: AXUIElement
    let frame: CGRect
    let canResize: Bool
}

private enum WindowAXFailure: Error { case busy, invalid }
private enum WindowFrameRead { case frame(CGRect), busy, invalid }

/// Uses only public AX messages and geometry; never reads window titles or text.
private final class WindowAXClient {
    let execution: AccessibilityExecution
    init(policy: AccessibilityExecution.Policy) { execution = AccessibilityExecution(policy: policy) }
    private func configured(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, ConversionTiming.axMessageTimeout)
        return element
    }
    private func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if error == .cannotComplete { throw WindowAXFailure.busy }
        guard error == .success, let value = AccessibilityValue.usable(value) else { throw WindowAXFailure.invalid }
        return value
    }
    private func element(_ value: CFTypeRef) throws -> AXUIElement {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw WindowAXFailure.invalid }
        return configured(value as! AXUIElement)
    }
    private func boolean(_ value: CFTypeRef) throws -> Bool {
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { throw WindowAXFailure.invalid }
        let boolean = value as! CFBoolean
        return CFBooleanGetValue(boolean)
    }
    private func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var supported = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &supported) == .success && supported.boolValue
    }
    private func focusedWindow(application: AXUIElement, pid: pid_t) throws -> AXUIElement {
        let system = configured(AXUIElementCreateSystemWide())
        let focusedApp = try element(attribute(system, kAXFocusedApplicationAttribute))
        var owner: pid_t = 0
        guard AXUIElementGetPid(focusedApp, &owner) == .success, owner == pid else { throw WindowAXFailure.invalid }
        let window = try element(attribute(application, kAXFocusedWindowAttribute))
        guard AXUIElementGetPid(window, &owner) == .success, owner == pid else { throw WindowAXFailure.invalid }
        return window
    }
    private func frame(_ window: AXUIElement, screens: WindowScreenSnapshot) throws -> CGRect {
        guard try attribute(window, kAXRoleAttribute) as? String == kAXWindowRole,
              try !boolean(attribute(window, kAXMinimizedAttribute)) else { throw WindowAXFailure.invalid }
        var names: CFArray?
        let error = AXUIElementCopyAttributeNames(window, &names)
        if error == .cannotComplete { throw WindowAXFailure.busy }
        guard error == .success, let names = names as? [String] else { throw WindowAXFailure.invalid }
        // Read this state only if the target publicly advertises the attribute.
        // The SDK exposes a fullscreen button but no universal window-state API.
        var knownFullscreen: Bool?
        if names.contains("AXFullScreen") { knownFullscreen = try boolean(attribute(window, "AXFullScreen")) }
        guard knownFullscreen != true else { throw WindowAXFailure.invalid }
        if execution.policy == .localApplication {
            guard let own = NSApp.keyWindow, !own.styleMask.contains(.fullScreen), !own.isMiniaturized else { throw WindowAXFailure.invalid }
            knownFullscreen = false
        }
        let rawPoint = try attribute(window, kAXPositionAttribute), rawSize = try attribute(window, kAXSizeAttribute)
        guard CFGetTypeID(rawPoint) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID(),
              AXValueGetType(rawPoint as! AXValue) == .cgPoint, AXValueGetType(rawSize as! AXValue) == .cgSize else { throw WindowAXFailure.invalid }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(rawPoint as! AXValue, .cgPoint, &origin), AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { throw WindowAXFailure.invalid }
        let frame = CGRect(origin: origin, size: size)
        guard WindowTransferPlan.valid(frame) else { throw WindowAXFailure.invalid }
        if knownFullscreen == nil && screens.displays.contains(where: { WindowTransferPlan.approximatelyEqual(frame, $0.frame, tolerance: 2) }) {
            throw WindowAXFailure.invalid
        }
        return frame
    }
    func context(pid: pid_t, screens: WindowScreenSnapshot) -> WindowAXContext? {
        execution.assertIsolated()
        do {
            let application = configured(AXUIElementCreateApplication(pid))
            let window = try focusedWindow(application: application, pid: pid)
            let frame = try frame(window, screens: screens)
            guard settable(window, kAXPositionAttribute) else { return nil }
            return WindowAXContext(pid: pid, application: application, window: window, frame: frame, canResize: settable(window, kAXSizeAttribute))
        } catch { return nil }
    }
    func read(_ context: WindowAXContext, screens: WindowScreenSnapshot) -> WindowFrameRead {
        execution.assertIsolated()
        do {
            let current = try focusedWindow(application: context.application, pid: context.pid)
            guard CFEqual(current, context.window) else { return .invalid }
            let result = try frame(current, screens: screens)
            guard CFEqual(try focusedWindow(application: context.application, pid: context.pid), context.window) else { return .invalid }
            return .frame(result)
        } catch WindowAXFailure.busy { return .busy }
        catch { return .invalid }
    }
    func write(_ operation: WindowFrameOperation, context: WindowAXContext, expected: CGRect,
               screens: WindowScreenSnapshot, cancellation: AttemptCancellation, deadline: Double) -> Bool {
        execution.assertIsolated()
        guard !cancellation.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
              case .frame(let current) = read(context, screens: screens),
              WindowTransferPlan.approximatelyEqual(current, expected), !cancellation.isCancelled else { return false }
        let name: String
        let value: AXValue?
        switch operation {
        case .size(var size): name = kAXSizeAttribute; value = AXValueCreate(.cgSize, &size)
        case .position(var point): name = kAXPositionAttribute; value = AXValueCreate(.cgPoint, &point)
        }
        guard let value, settable(context.window, name), !cancellation.isCancelled else { return false }
        guard let current = try? focusedWindow(application: context.application, pid: context.pid),
              CFEqual(current, context.window), !cancellation.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return false }
        return AXUIElementSetAttributeValue(context.window, name as CFString, value) == .success
    }
}

/// One shortcut owns one focused window. AX setters cannot be atomic across
/// processes; every step revalidates identity and never retries a mutation.
final class WindowMoveController {
    private final class Attempt {
        let pid: pid_t
        let screens: WindowScreenSnapshot
        let cancellation = AttemptCancellation()
        let writeDeadline = ProcessInfo.processInfo.systemUptime + 2
        var context: WindowAXContext?
        var plan: WindowTransferPlan?
        var expected: CGRect = .zero
        var operations: [WindowFrameOperation] = []
        var didIssueWrite = false
        var poll: DispatchWorkItem?
        var preparationTimeout: DispatchWorkItem?
        init(pid: pid_t, screens: WindowScreenSnapshot) { self.pid = pid; self.screens = screens }
    }
    private let remote = WindowAXClient(policy: .remoteApplication)
    private let local = WindowAXClient(policy: .localApplication)
    private var attempt: Attempt?
    private var screenObserver: NSObjectProtocol?
    private(set) var lastResult = "Перенос окна: ещё не выполнялся"
    var onResult: (() -> Void)?

    init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.cancel() }
    }
    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let attempt else { return }
        finish(attempt, message: attempt.didIssueWrite ? "Перенос окна: результат не подтверждён" : "Перенос окна отменён")
    }
    /// Event-tap callback performs only cancellation bookkeeping. UI status is
    /// dispatched after returning from the tap, while the worker sees it now.
    func userInteracted() {
        guard let attempt else { return }
        attempt.cancellation.cancel()
        DispatchQueue.main.async { [weak self] in
            guard self?.attempt === attempt else { return }
            self?.cancel()
        }
    }
    func move(_ direction: WindowMoveDirection) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard attempt == nil else { return } // Drop repeated presses; never queue a different target.
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              let screens = WindowScreenSnapshot.capture() else { lastResult = "Для переноса окна нужен Универсальный доступ"; onResult?(); return }
        let attempt = Attempt(pid: app.processIdentifier, screens: screens)
        self.attempt = attempt
        let timeout = DispatchWorkItem { [weak self] in self?.finish(attempt, message: "Не удалось вовремя получить активное окно") }
        attempt.preparationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: timeout)
        read(attempt, operation: { $0.context(pid: attempt.pid, screens: screens) }) { context in
            attempt.preparationTimeout?.cancel(); attempt.preparationTimeout = nil
            guard let context else { self.finish(attempt, message: "Это окно нельзя перенести; полноэкранные Spaces не перемещаются"); return }
            let decision = WindowTransferPlan.decide(window: context.frame, displays: screens.displays, direction: direction, canResize: context.canResize)
            switch decision {
            case .noNeighbor: self.finish(attempt, message: "В этом направлении нет соседнего дисплея")
            case .invalidGeometry: self.finish(attempt, message: "Не удалось определить положение окна и дисплеев")
            case .resizeUnavailable: self.finish(attempt, message: "Это окно нельзя подогнать под соседний дисплей")
            case .move(let plan):
                attempt.context = context; attempt.plan = plan; attempt.expected = context.frame
                attempt.operations = WindowFrameOperation.sequence(from: context.frame, to: plan.frame)
                self.writeNext(attempt)
            }
        }
    }
    private func valid(_ attempt: Attempt) -> Bool {
        self.attempt === attempt && !attempt.cancellation.isCancelled && AXIsProcessTrusted() &&
        NSWorkspace.shared.frontmostApplication?.processIdentifier == attempt.pid && WindowScreenSnapshot.capture() == attempt.screens
    }
    private func read<T>(_ attempt: Attempt, operation: @escaping (WindowAXClient) -> T, completion: @escaping (T) -> Void) {
        let client = attempt.pid == ProcessInfo.processInfo.processIdentifier ? local : remote
        client.execution.submit {
            guard !attempt.cancellation.isCancelled else { return }
            let result = operation(client)
            DispatchQueue.main.async {
                guard self.attempt === attempt else { return }
                guard self.valid(attempt) else { self.cancel(); return }
                completion(result)
            }
        }
    }
    private func writeNext(_ attempt: Attempt) {
        guard valid(attempt), let context = attempt.context, let plan = attempt.plan else { cancel(); return }
        while let first = attempt.operations.first, first.matches(attempt.expected) { attempt.operations.removeFirst() }
        guard let operation = attempt.operations.first else {
            finish(attempt, message: WindowTransferPlan.approximatelyEqual(attempt.expected, plan.frame) ? "Окно перенесено на соседний дисплей" : "Перенос окна: результат не подтверждён")
            return
        }
        guard ProcessInfo.processInfo.systemUptime < attempt.writeDeadline else { finish(attempt, message: "Перенос окна: время ожидания истекло"); return }
        let expected = attempt.expected
        attempt.didIssueWrite = true
        read(attempt, operation: { $0.write(operation, context: context, expected: expected, screens: attempt.screens, cancellation: attempt.cancellation, deadline: attempt.writeDeadline) }) { issued in
            guard issued else { self.finish(attempt, message: "Перенос окна: результат не подтверждён"); return }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            self.acknowledge(attempt, operation: operation, deadline: deadline)
        }
    }
    private func acknowledge(_ attempt: Attempt, operation: WindowFrameOperation, deadline: Double) {
        guard valid(attempt), let context = attempt.context, let plan = attempt.plan else { cancel(); return }
        guard ProcessInfo.processInfo.systemUptime < deadline else { finish(attempt, message: "Перенос окна: результат не подтверждён"); return }
        read(attempt, operation: { $0.read(context, screens: attempt.screens) }) { result in
            guard ProcessInfo.processInfo.systemUptime < deadline else { self.finish(attempt, message: "Перенос окна: результат не подтверждён"); return }
            switch result {
            case .invalid: self.finish(attempt, message: "Перенос окна: результат не подтверждён")
            case .frame(let frame) where operation.acknowledges(frame, previous: attempt.expected) && (attempt.operations.count > 1 || WindowTransferPlan.approximatelyEqual(frame, plan.frame)):
                attempt.expected = frame; attempt.operations.removeFirst()
                if attempt.operations.isEmpty { self.finish(attempt, message: "Окно перенесено на соседний дисплей") }
                else { self.writeNext(attempt) }
            case .busy, .frame:
                let work = DispatchWorkItem { [weak self = self] in self?.acknowledge(attempt, operation: operation, deadline: deadline) }
                attempt.poll = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
            }
        }
    }
    private func finish(_ attempt: Attempt, message: String) {
        guard self.attempt === attempt else { return }
        attempt.cancellation.cancel(); attempt.poll?.cancel(); attempt.preparationTimeout?.cancel(); self.attempt = nil
        lastResult = message; onResult?()
    }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
}
