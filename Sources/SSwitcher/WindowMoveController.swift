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
            guard let id = screen.displayID else { return nil }
            displays.append(WindowDisplay(id: id,
                frame: WindowTransferPlan.accessibilityRect(fromAppKit: screen.frame, primaryTop: top),
                visibleFrame: WindowTransferPlan.accessibilityRect(fromAppKit: screen.visibleFrame, primaryTop: top)))
        }
        return Self(displays: displays, primaryTop: top)
    }
}

extension WindowMoveController {
    /// Current displays in AX coordinates, for choosing shortcut directions.
    static func currentDisplays() -> [WindowDisplay] { WindowScreenSnapshot.capture()?.displays ?? [] }
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
/// A failed lookup names the step that refused, for the move report.
private enum WindowContextRead { case context(WindowAXContext), busy(String), invalid(String) }

/// Uses only public AX messages and geometry; never reads window titles or text.
private final class WindowAXClient {
    let execution: AccessibilityExecution
    /// The step being read; reported when a context lookup fails.
    private var step = ""
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
    /// The system-wide focus check only refuses a different owner. When it
    /// cannot be read (Chrome was seen refusing every reply until relaunch),
    /// the caller's frontmost-process check on the main queue still applies.
    /// A missing focused window falls back to the main window.
    private func focusedWindow(application: AXUIElement, pid: pid_t) throws -> AXUIElement {
        var owner: pid_t = 0
        step = "focusedApplication"
        if let focusedApp = try? element(attribute(configured(AXUIElementCreateSystemWide()), kAXFocusedApplicationAttribute)),
           AXUIElementGetPid(focusedApp, &owner) == .success, owner != pid { throw WindowAXFailure.invalid }
        step = "focusedWindow"
        let window: AXUIElement
        do { window = try element(attribute(application, kAXFocusedWindowAttribute)) }
        catch {
            step = "mainWindow"
            window = try element(attribute(application, kAXMainWindowAttribute))
        }
        step = "windowOwner"
        guard AXUIElementGetPid(window, &owner) == .success, owner == pid else { throw WindowAXFailure.invalid }
        return window
    }
    private func frame(_ window: AXUIElement, screens: WindowScreenSnapshot) throws -> CGRect {
        step = "windowState"
        guard try attribute(window, kAXRoleAttribute) as? String == kAXWindowRole,
              try !boolean(attribute(window, kAXMinimizedAttribute)) else { throw WindowAXFailure.invalid }
        var names: CFArray?
        let error = AXUIElementCopyAttributeNames(window, &names)
        if error == .cannotComplete { throw WindowAXFailure.busy }
        guard error == .success, let names = names as? [String] else { throw WindowAXFailure.invalid }
        // Read this state only if the target publicly advertises the attribute.
        // The SDK exposes a fullscreen button but no universal window-state API.
        var knownFullscreen: Bool?
        step = "fullScreen"
        if names.contains("AXFullScreen") { knownFullscreen = try boolean(attribute(window, "AXFullScreen")) }
        guard knownFullscreen != true else { throw WindowAXFailure.invalid }
        if execution.policy == .localApplication {
            guard let own = NSApp.keyWindow, !own.styleMask.contains(.fullScreen), !own.isMiniaturized else { throw WindowAXFailure.invalid }
            knownFullscreen = false
        }
        step = "geometry"
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
    func context(pid: pid_t, screens: WindowScreenSnapshot) -> WindowContextRead {
        execution.assertIsolated()
        do {
            let application = configured(AXUIElementCreateApplication(pid))
            let window = try focusedWindow(application: application, pid: pid)
            let frame = try frame(window, screens: screens)
            guard settable(window, kAXPositionAttribute) else { return .invalid("positionNotSettable") }
            return .context(WindowAXContext(pid: pid, application: application, window: window, frame: frame,
                                            canResize: settable(window, kAXSizeAttribute)))
        } catch WindowAXFailure.busy { return .busy(step) }
        catch { return .invalid(step) }
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
/// processes; every step revalidates identity and is never repeated blindly.
/// macOS or the application may adjust a step (minimum sizes, size
/// increments, display constraints); a stable AX frame is then accepted.
final class WindowMoveController {
    private final class Attempt {
        let pid: pid_t
        let direction: WindowMoveDirection
        let screens: WindowScreenSnapshot
        let cancellation = AttemptCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        let writeDeadline = ProcessInfo.processInfo.systemUptime + 2
        var context: WindowAXContext?
        var plan: WindowTransferPlan?
        var expected: CGRect = .zero
        var operations: [WindowFrameOperation] = []
        var didIssueWrite = false
        /// Origin macOS accepted for the move; later position steps that
        /// would request the same target are already satisfied by it.
        var acceptedOrigin: CGPoint?
        var changedDisplay = false
        var settledForGrowth = false
        var repeatedGrowth = false
        var steps: [[String: Any]] = []
        /// AX step that refused the last context lookup.
        var failedStep: String?
        var poll: DispatchWorkItem?
        var preparationTimeout: DispatchWorkItem?
        init(pid: pid_t, direction: WindowMoveDirection, screens: WindowScreenSnapshot) {
            self.pid = pid; self.direction = direction; self.screens = screens
        }
    }
    private let remote = WindowAXClient(policy: .remoteApplication)
    private let local = WindowAXClient(policy: .localApplication)
    private var attempt: Attempt?
    private var screenObserver: NSObjectProtocol?
    private(set) var lastResult = "Перенос окна: ещё не выполнялся"
    /// Planned and actual geometry of the last transfer, for the diagnostics window.
    private(set) var lastDetails = ""
    var onResult: (() -> Void)?

    init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.cancel() }
    }
    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let attempt else { return }
        finish(attempt, message: attempt.didIssueWrite ? "Перенос окна: результат не подтверждён" : "Перенос окна отменён", outcome: "cancelled")
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
        let attempt = Attempt(pid: app.processIdentifier, direction: direction, screens: screens)
        self.attempt = attempt
        let timeout = DispatchWorkItem { [weak self] in self?.finish(attempt, message: "Не удалось вовремя получить активное окно", outcome: "contextTimeout") }
        attempt.preparationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: timeout)
        prepare(attempt)
    }
    /// A busy application is asked again until the preparation timeout.
    private func prepare(_ attempt: Attempt) {
        let screens = attempt.screens, direction = attempt.direction
        read(attempt, operation: { $0.context(pid: attempt.pid, screens: screens) }) { read in
            let context: WindowAXContext
            switch read {
            case .context(let found): context = found
            case .busy(let step):
                attempt.failedStep = step
                self.schedule(attempt, after: ConversionTiming.windowPollInterval) { self.prepare(attempt) }
                return
            case .invalid(let step):
                attempt.failedStep = step
                self.finish(attempt, message: "Это окно нельзя перенести; полноэкранные Spaces не перемещаются", outcome: "windowUnavailable")
                return
            }
            attempt.preparationTimeout?.cancel(); attempt.preparationTimeout = nil
            attempt.failedStep = nil
            attempt.expected = context.frame
            let decision = WindowTransferPlan.decide(window: context.frame, displays: screens.displays, direction: direction, canResize: context.canResize)
            switch decision {
            case .noNeighbor: self.finish(attempt, message: "В этом направлении нет соседнего дисплея", outcome: "noNeighbor")
            case .invalidGeometry: self.finish(attempt, message: "Не удалось определить положение окна и дисплеев", outcome: "invalidGeometry")
            case .resizeUnavailable: self.finish(attempt, message: "Это окно нельзя подогнать под соседний дисплей", outcome: "resizeUnavailable")
            case .move(let plan):
                attempt.context = context; attempt.plan = plan
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
    private func schedule(_ attempt: Attempt, after delay: Double, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem { [weak self] in
            guard self?.attempt === attempt else { return }
            work()
        }
        attempt.poll = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    private func writeNext(_ attempt: Attempt) {
        guard valid(attempt), let context = attempt.context, let plan = attempt.plan else { cancel(); return }
        while let first = attempt.operations.first, first.isSatisfied(by: attempt.expected, acceptedOrigin: attempt.acceptedOrigin) {
            attempt.operations.removeFirst()
        }
        guard let operation = attempt.operations.first else { complete(attempt, plan: plan); return }
        guard ProcessInfo.processInfo.systemUptime < attempt.writeDeadline else {
            finish(attempt, message: "Перенос окна: время ожидания истекло", outcome: "deadline"); return
        }
        // The application keeps constraining a resize to the previous display
        // for a few milliseconds after the window changed displays.
        if operation.grows(attempt.expected), attempt.changedDisplay, !attempt.settledForGrowth {
            attempt.settledForGrowth = true
            attempt.steps.append(["settleMS": Int(ConversionTiming.windowDisplaySettle * 1000)])
            schedule(attempt, after: ConversionTiming.windowDisplaySettle) { self.writeNext(attempt) }
            return
        }
        let expected = attempt.expected
        attempt.didIssueWrite = true
        let issuedAt = ProcessInfo.processInfo.systemUptime
        read(attempt, operation: { $0.write(operation, context: context, expected: expected, screens: attempt.screens, cancellation: attempt.cancellation, deadline: attempt.writeDeadline) }) { issued in
            guard issued else { self.finish(attempt, message: "Перенос окна: результат не подтверждён", outcome: "writeRefused"); return }
            self.acknowledge(attempt, progress: WindowStepProgress(operation: operation, before: expected), issuedAt: issuedAt,
                             deadline: ProcessInfo.processInfo.systemUptime + ConversionTiming.windowStepDeadline)
        }
    }
    private func acknowledge(_ attempt: Attempt, progress: WindowStepProgress, issuedAt: Double, deadline: Double) {
        guard valid(attempt), let context = attempt.context, let plan = attempt.plan else { cancel(); return }
        read(attempt, operation: { $0.read(context, screens: attempt.screens) }) { result in
            var progress = progress
            let now = ProcessInfo.processInfo.systemUptime
            let state: WindowStepProgress.State
            switch result {
            case .invalid: self.finish(attempt, message: "Перенос окна: результат не подтверждён", outcome: "readInvalid"); return
            case .busy: state = .waiting
            case .frame(let frame): state = progress.observe(frame, at: now)
            }
            let frame: CGRect
            let kind: String
            switch state {
            case .waiting:
                guard now < deadline else {
                    self.record(attempt, progress.operation, result: "timeout", frame: nil, issuedAt: issuedAt)
                    self.finish(attempt, message: "Перенос окна: результат не подтверждён", outcome: "stepTimeout"); return
                }
                self.schedule(attempt, after: ConversionTiming.windowPollInterval) {
                    self.acknowledge(attempt, progress: progress, issuedAt: issuedAt, deadline: deadline)
                }
                return
            case .applied(let value): frame = value; kind = "applied"
            case .adjusted(let value): frame = value; kind = "adjusted"
            case .unchanged(let value): frame = value; kind = "unchanged"
            }
            self.record(attempt, progress.operation, result: kind, frame: frame, issuedAt: issuedAt)
            attempt.expected = frame
            if case .position = progress.operation, attempt.acceptedOrigin == nil {
                attempt.acceptedOrigin = frame.origin
                attempt.changedDisplay = WindowTransferPlan.mainDisplay(of: frame, in: attempt.screens.displays)?.id != plan.sourceID
            }
            // A growth cut short right after a display change is issued once
            // more after a longer settle; any other result is final.
            if progress.operation.fallsShort(frame), progress.operation.grows(progress.before), attempt.changedDisplay, !attempt.repeatedGrowth {
                attempt.repeatedGrowth = true
                attempt.steps.append(["settleMS": Int(ConversionTiming.windowGrowthRepeatSettle * 1000)])
                self.schedule(attempt, after: ConversionTiming.windowGrowthRepeatSettle) { self.writeNext(attempt) }
                return
            }
            attempt.operations.removeFirst()
            self.writeNext(attempt)
        }
    }
    private func complete(_ attempt: Attempt, plan: WindowTransferPlan) {
        switch WindowTransferOutcome.classify(final: attempt.expected, plan: plan, displays: attempt.screens.displays) {
        case .moved: finish(attempt, message: "Окно перенесено на соседний дисплей", outcome: "moved")
        case .adjusted: finish(attempt, message: "Окно перенесено; macOS или программа изменили его размер или положение", outcome: "adjusted")
        case .unconfirmed: finish(attempt, message: "Перенос окна: результат не подтверждён", outcome: "unconfirmed")
        }
    }
    private func record(_ attempt: Attempt, _ operation: WindowFrameOperation, result: String, frame: CGRect?, issuedAt: Double) {
        var step: [String: Any] = ["result": result, "ms": Int((ProcessInfo.processInfo.systemUptime - issuedAt) * 1000)]
        switch operation {
        case .size(let size): step["size"] = [size.width, size.height]
        case .position(let point): step["position"] = [point.x, point.y]
        }
        if let frame { step["frame"] = Self.numbers(frame) }
        attempt.steps.append(step)
    }
    private static func numbers(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) } }
    private static func text(_ rect: CGRect) -> String {
        String(format: "%.0f, %.0f, %.0f×%.0f", rect.minX, rect.minY, rect.width, rect.height)
    }
    private func finish(_ attempt: Attempt, message: String, outcome: String) {
        guard self.attempt === attempt else { return }
        attempt.cancellation.cancel(); attempt.poll?.cancel(); attempt.preparationTimeout?.cancel(); self.attempt = nil
        // Work items capture the attempt; dropping them breaks that cycle.
        attempt.poll = nil; attempt.preparationTimeout = nil
        // Geometry only: no window titles, application names or contents.
        var report: [String: Any] = ["outcome": outcome, "direction": String(describing: attempt.direction),
                                     "elapsedMS": Int((ProcessInfo.processInfo.systemUptime - attempt.started) * 1000),
                                     "displays": attempt.screens.displays.map { ["id": Int($0.id), "frame": Self.numbers($0.frame),
                                                                                  "visible": Self.numbers($0.visibleFrame)] },
                                     "steps": attempt.steps]
        if let context = attempt.context { report["source"] = Self.numbers(context.frame) }
        if let failedStep = attempt.failedStep { report["failedStep"] = failedStep }
        if let plan = attempt.plan {
            report["plan"] = Self.numbers(plan.frame)
            report["sourceDisplay"] = Int(plan.sourceID); report["destinationDisplay"] = Int(plan.destinationID)
            report["final"] = Self.numbers(attempt.expected)
            lastDetails = "Перенос окна: план \(Self.text(plan.frame)); итог \(Self.text(attempt.expected))"
        } else { lastDetails = "" }
        DiagnosticReports.shared.record("WindowMoveReport", report)
        lastResult = message; onResult?()
    }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
}
