import AppKit
import SwitcherCore

final class KeyboardMonitor {
    var onDoubleShift: (() -> Void)?
    var canStartConversion: (() -> Bool)?
    private var burst = ShiftBurstGate()
    private var pendingDispatch: DispatchWorkItem?
    private(set) var inputGeneration: UInt64 = 0
    private(set) var shiftEventCount = 0
    private(set) var doubleShiftCount = 0
    private(set) var syntheticEventCount = 0
    private var detector = DoubleShiftDetector()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        guard CGPreflightListenEventAccess() else { return false }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
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
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        inputGeneration &+= 1
        pendingDispatch?.cancel()
        pendingDispatch = nil
        burst.cancel()
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
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == KeyboardEvents.marker {
            syntheticEventCount += 1
            return
        }
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        // A second double Shift must not cancel selection restoration from the
        // first conversion. Actual typing, clicks and other modifiers still do.
        if type != .flagsChanged || (key != 56 && key != 60) {
            inputGeneration &+= 1
            burst.cancel()
            pendingDispatch?.cancel()
        }
        guard type == .flagsChanged else { detector.cancelGesture(); return }
        if key == 56 || key == 60 {
            shiftEventCount += 1
            burst.shiftChanged(down: event.flags.contains(.maskShift), at: ProcessInfo.processInfo.systemUptime)
            pendingDispatch?.cancel()
        }
        let otherModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
        if detector.shiftChanged(
            key: key, anyShiftDown: event.flags.contains(.maskShift),
            otherModifierDown: !event.flags.intersection(otherModifiers).isEmpty,
            time: Double(event.timestamp) / 1_000_000_000
        ) {
            doubleShiftCount += 1
            if canStartConversion?() != false { burst.request() }
        }
        guard burst.pending, !event.flags.contains(.maskShift) else { return }
        let generation = inputGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.inputGeneration == generation,
                  self.burst.consume(at: ProcessInfo.processInfo.systemUptime),
                  self.canStartConversion?() != false else { return }
            self.onDoubleShift?()
        }
        pendingDispatch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + burst.quietInterval + 0.005, execute: work)
    }

    deinit { stop() }
}
