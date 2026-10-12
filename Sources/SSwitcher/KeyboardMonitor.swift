import AppKit
import Carbon
import SwitcherCore

final class KeyboardMonitor {
    var onDoubleShift: (() -> Void)?
    /// Called inside the listening tap for every non-key-up event; keep it to
    /// a cheap check and dispatch AppKit work.
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

    /// Settings: which Shift counts and how fast both taps must be. Main thread,
    /// like the tap itself; a change drops any half-finished pair.
    func configureDoubleShift(keys: Set<UInt16>, interval: Double) {
        guard detector.keys != keys || detector.interval != interval else { return }
        detector.keys = keys
        detector.interval = interval
        detector.reset()
    }
    private var typedWord = TypedWordTracker()
    private var layoutData: CFData?
    /// Text-free counters explaining why a MAX gesture had no known word.
    private(set) var typedWordReset = "start"
    private(set) var typedKeysSinceReset = 0
    private(set) var translatedKeysSinceReset = 0
    /// Typed characters are remembered only while an editor that needs them
    /// (MAX) is frontmost; switching it off forgets them immediately.
    var tracksTypedWord = false { didSet { forgetTypedWord("activation") } }
    var typedWordCandidate: TypedWordTracker.Candidate { tracksTypedWord ? typedWord.candidate : .unknown }
    /// MAX only: true when no editor selection can exist, because the last
    /// caret change was typing, Backspace, a plain arrow or a plain single
    /// click. Drags, multi-clicks, Shift navigation, shortcuts, other control
    /// keys and app changes make a selection possible.
    private(set) var selectionKnownEmpty = false
    func replaceTypedWord(_ word: String, with replacement: String) { typedWord.replaceWord(word, with: replacement) }
    /// After a native conversion the editor's own text ends at the caret.
    func assumeTypedWord(_ text: String) {
        forgetTypedWord("nativeConversion")
        typedWord.assume(text)
        selectionKnownEmpty = true
    }
    func assumeSelectionEmpty() { selectionKnownEmpty = true }
    func forgetTypedWord(_ reason: String = "replacement") {
        if reason != "nativeConversion" && reason != "click" { selectionKnownEmpty = false }
        typedWord.reset()
        typedWordReset = reason; typedKeysSinceReset = 0; translatedKeysSinceReset = 0
    }
    /// The layout used to translate key codes is read again after a change.
    func keyboardLayoutChanged() { layoutData = nil }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var isRunning: Bool { tap != nil }
    private var hardwareModifierKeysDown: Set<UInt16> {
        Set(PhysicalModifierState.unsafeKeys.filter(Self.hardwareKeyDown))
    }
    private static func hardwareKeyDown(_ key: UInt16) -> Bool { CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key)) }
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
        DiagnosticReports.shared.record("DiagnosticTriggerReport", ["allowed": allowed, "physicalClear": clear,
            "observedClear": observedModifiersClear, "heldModifiers": hardwareModifierKeysDown.sorted()])
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
        forgetTypedWord("stopped")
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            detector.reset()
            forgetTypedWord("tapDisabled")
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
        switch type {
        case .keyDown: recordTyping(event, key: key)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard tracksTypedWord else { break }
            forgetTypedWord("click")
            selectionKnownEmpty = type == .leftMouseDown && event.getIntegerValueField(.mouseEventClickState) == 1 &&
                event.flags.intersection([.maskShift, .maskCommand, .maskControl, .maskAlternate]).isEmpty
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: selectionKnownEmpty = false
        default: break
        }
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
        // The listening tap does only local bookkeeping/invalidation; the
        // callback dispatches AppKit work only when something is on screen.
        onUserActivity?()
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
        let shiftDown = modifiers.shiftHeld || Self.hardwareKeyDown(56) || Self.hardwareKeyDown(60)
        if key == 56 || key == 60 {
            shiftEventCount += 1
            burst.shiftChanged(down: shiftDown, at: ProcessInfo.processInfo.systemUptime)
            pendingDispatch?.cancel()
        }
        if detector.shiftChanged(
            key: key, anyShiftDown: shiftDown,
            otherModifierDown: modifiers.otherModifierHeld ||
                PhysicalModifierState.unsafeKeys.contains { $0 != 56 && $0 != 60 && Self.hardwareKeyDown($0) },
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

    /// Runs inside the listening tap: only local string bookkeeping.
    private func recordTyping(_ event: CGEvent, key: UInt16) {
        guard tracksTypedWord else { return }
        guard event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty else { forgetTypedWord("shortcut"); return }
        if key == 51 {
            let before = typedWord.candidate
            typedWord.backspace()
            if before != .unknown, typedWord.candidate == .unknown { forgetTypedWord("backspaceAcrossSpace") }
            selectionKnownEmpty = true
            return
        }
        var text = withUnsafeTemporaryAllocation(of: UniChar.self, capacity: 8) { units -> String in
            var length = 0
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: units.baseAddress!)
            return String(utf16CodeUnits: units.baseAddress!, count: min(max(length, 0), units.count))
        }
        // Hardware key events may reach a session tap without their text;
        // translate the key with the current layout as the editor will.
        if text.isEmpty, let translated = translate(key, flags: event.flags) {
            text = translated
            translatedKeysSinceReset += 1
        }
        typedWord.typed(text)
        if typedWord.candidate == .unknown {
            forgetTypedWord(text.isEmpty ? "noText" : "controlKey")
            // A plain arrow, Home, End or page key collapses any selection.
            switch key {
            case 115, 116, 119, 121, 123...126: selectionKnownEmpty = !event.flags.contains(.maskShift)
            default: selectionKnownEmpty = false
            }
        } else {
            typedKeysSinceReset += 1
            selectionKnownEmpty = true
        }
    }

    private func translate(_ key: UInt16, flags: CGEventFlags) -> String? {
        if layoutData == nil, let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        }
        guard let layoutData, let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var modifiers = 0
        if flags.contains(.maskShift) { modifiers |= shiftKey }
        if flags.contains(.maskAlphaShift) { modifiers |= alphaLock }
        return withUnsafeTemporaryAllocation(of: UniChar.self, capacity: 8) { buffer -> String? in
            var deadKey: UInt32 = 0
            var length = 0
            guard UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), UInt32(modifiers >> 8), UInt32(LMGetKbdType()),
                                 0, &deadKey, buffer.count, &length, buffer.baseAddress!) == noErr,
                  deadKey == 0, length > 0, length <= buffer.count else { return nil }
            return String(utf16CodeUnits: buffer.baseAddress!, count: length)
        }
    }

    deinit { stop() }
}
