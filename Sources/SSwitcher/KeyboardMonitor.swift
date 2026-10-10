import AppKit
import SwitcherCore

final class KeyboardMonitor {
    var onDoubleShift: (() -> Void)?
    var onUserActivity: (() -> Void)?
    var onRealInput: (() -> Void)?
    var onWindowInteraction: (() -> Void)?
    var onGestureRelease: ((Double) -> Void)?
    var onGestureCancelled: (() -> Void)?
    var onBlockedGesture: (() -> Void)?
    var canStartConversion: (() -> Bool)?
    private var burst = ShiftBurstGate(quietInterval: ConversionTiming.shiftQuiet)
    private var pendingDispatch: DispatchWorkItem?
    private(set) var inputGeneration: UInt64 = 0
    private(set) var activityGeneration: UInt64 = 0
    private(set) var lastGestureRelease = ProcessInfo.processInfo.systemUptime
    private var modifiers = PhysicalModifierState()
    private static let modifierFlags: [UInt16: CGEventFlags] = [56: .maskShift, 60: .maskShift, 55: .maskCommand, 54: .maskCommand,
                                                               59: .maskControl, 62: .maskControl, 58: .maskAlternate, 61: .maskAlternate, 63: .maskSecondaryFn]
    private(set) var shiftEventCount = 0
    private(set) var doubleShiftCount = 0
    private(set) var syntheticEventCount = 0
    private var detector = DoubleShiftDetector()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var isRunning: Bool { tap != nil }
    private var hardwareModifierKeysDown: Set<UInt16> {
        Set(PhysicalModifierState.unsafeKeys.filter { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) })
    }
    var physicalModifiersClear: Bool {
        modifiers.permitsMutation(hardwareKeysDown: hardwareModifierKeysDown)
    }
    // After posting our own arrows, HID key state can still describe queued
    // synthetic Shift. Only unmarked transitions update this tracked state.
    var observedModifiersClear: Bool { modifiers.observedModifiersClear }

    func claimConversion() -> Bool {
        if burst.state == .running { return true }
        return burst.beginConversion(allowed: canStartConversion?() != false)
    }
    func conversionFinished(unverified: Bool) {
        burst.complete(at: ProcessInfo.processInfo.systemUptime, unverified: unverified)
        detector.reset()
    }
    func focusChanged(isUserIntervention: Bool = true) {
        inputGeneration &+= 1
        if isUserIntervention { burst.realInput() }
        else { burst.cancel() }
        pendingDispatch?.cancel(); pendingDispatch = nil
        detector.cancelGesture()
        onGestureCancelled?()
        onRealInput?()
    }
    func triggerForDiagnostics() {
        let allowed = canStartConversion?() != false
        let clear = physicalModifiersClear
        UserDefaults.standard.set(["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "allowed": allowed, "physicalClear": clear, "observedClear": observedModifiersClear,
            "heldModifiers": hardwareModifierKeysDown.sorted()], forKey: "DiagnosticTriggerReport")
        guard allowed, clear else { return }
        lastGestureRelease = ProcessInfo.processInfo.systemUptime
        burst.shiftChanged(down: false, at: lastGestureRelease)
        onGestureRelease?(lastGestureRelease)
        onDoubleShift?()
    }

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        guard CGPreflightListenEventAccess() else { return false }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.source = source
        detector.reset()
        modifiers.reset()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        inputGeneration &+= 1
        pendingDispatch?.cancel()
        pendingDispatch = nil
        burst.cancel()
        burst.realInput()
        onGestureCancelled?()
        onRealInput?()
        KeyboardEvents.cancelDelivery()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        detector.reset()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            detector.reset()
            burst.cancel()
            pendingDispatch?.cancel()
            inputGeneration &+= 1
            onGestureCancelled?()
            onRealInput?()
            onWindowInteraction?()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if KeyboardEvents.received(event) {
            // Keep the diagnostic counter comparable to earlier releases:
            // one count per synthetic command, excluding its release receipt.
            if type != .keyUp { syntheticEventCount += 1 }
            return
        }
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let interaction: WindowShortcutInteraction
        switch type {
        case .keyDown: interaction = .keyDown
        case .keyUp: interaction = .keyUp
        case .flagsChanged: interaction = .modifierChanged
        default: interaction = .pointer
        }
        if interaction.cancelsMove(key: key, option: event.flags.contains(.maskAlternate), shift: event.flags.contains(.maskShift),
                                   command: event.flags.contains(.maskCommand), control: event.flags.contains(.maskControl)) {
            onWindowInteraction?()
        }
        // Real key-down already invalidates the attempt. Listening for key-up
        // is needed only for our delivery receipt, not a second input change.
        if type == .keyUp { return }
        activityGeneration &+= 1
        // The listening tap does only local bookkeeping/invalidation. AppKit
        // work is dispatched after the callback has returned to its run loop.
        DispatchQueue.main.async { [weak self] in self?.onUserActivity?() }
        // A second double Shift is drained during the existing replacement.
        // Actual typing, clicks and other modifiers still cancel that attempt.
        if type != .flagsChanged || (key != 56 && key != 60) {
            inputGeneration &+= 1
            burst.realInput()
            pendingDispatch?.cancel()
            onGestureCancelled?()
            onRealInput?()
        }
        guard type == .flagsChanged else { detector.cancelGesture(); return }
        if let flag = Self.modifierFlags[key] { modifiers.changed(key: key, groupDown: event.flags.contains(flag)) }
        let hardwareDown = hardwareModifierKeysDown
        let shiftDown = modifiers.shiftHeld || hardwareDown.contains(56) || hardwareDown.contains(60)
        if key == 56 || key == 60 {
            shiftEventCount += 1
            burst.shiftChanged(down: shiftDown, at: ProcessInfo.processInfo.systemUptime)
            pendingDispatch?.cancel()
        }
        if detector.shiftChanged(
            key: key, anyShiftDown: shiftDown,
            otherModifierDown: modifiers.otherModifierHeld || !hardwareDown.subtracting([56, 60]).isEmpty,
            time: Double(event.timestamp) / 1_000_000_000
        ) {
            doubleShiftCount += 1
            if burst.state == .blocked {
                DispatchQueue.main.async { [weak self] in self?.onBlockedGesture?() }
            }
            burst.request(allowed: canStartConversion?() != false)
        }
        guard burst.pending, !shiftDown else { return }
        lastGestureRelease = ProcessInfo.processInfo.systemUptime
        onGestureRelease?(lastGestureRelease)
        let generation = inputGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.inputGeneration == generation,
                  self.physicalModifiersClear, self.burst.consume(at: ProcessInfo.processInfo.systemUptime),
                  self.burst.beginConversion(allowed: self.canStartConversion?() != false) else { return }
            self.detector.reset()
            self.onDoubleShift?()
        }
        pendingDispatch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + burst.quietInterval, execute: work)
    }

    deinit { stop() }
}
