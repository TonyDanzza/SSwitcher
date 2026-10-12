import AppKit
import SwitcherCore

/// Reverses the mouse wheel and gives extra mouse buttons actions. Its active
/// session tap exists only while one of these is on or a button is being
/// recorded, and needs Accessibility. The conversion listener stays a
/// separate listen-only tap. The callback only edits or drops events; actions
/// run on the next main-queue turn.
final class MouseController: ObservableObject {
    @Published private(set) var isRecording = false
    private var reverseWheel = false
    private var bindings: [MouseButtonBinding] = []
    private var onRecorded: ((Int, KeyShortcut.Modifiers) -> Void)?
    /// Buttons whose press was taken: their drags and release are taken too,
    /// so the application never sees half a click.
    private var taken = Set<Int>()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var reversedEvents = 0
    private(set) var buttonActions = 0
    var isRunning: Bool { tap != nil }

    func configure(reverseWheel: Bool, bindings: [MouseButtonBinding]) {
        self.reverseWheel = reverseWheel
        self.bindings = bindings
        refresh()
    }

    /// Starts or stops the tap to match what is needed. Also the retry point
    /// after Accessibility is granted.
    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        let needed = reverseWheel || !bindings.isEmpty || isRecording || !taken.isEmpty
        if needed && tap == nil { start() } else if !needed && tap != nil { stop() }
    }

    /// The next press of a button other than left or right is reported
    /// instead of acted on. False when the tap cannot run.
    @discardableResult
    func record(_ completion: @escaping (Int, KeyShortcut.Modifiers) -> Void) -> Bool {
        onRecorded = completion
        isRecording = true
        refresh()
        if tap == nil { cancelRecording(); return false }
        return true
    }

    func cancelRecording() {
        onRecorded = nil
        guard isRecording else { return }
        isRecording = false
        refresh()
    }

    func shutdown() {
        onRecorded = nil
        isRecording = false
        reverseWheel = false
        bindings = []
        taken.removeAll()
        stop()
    }

    var statusDescription: String {
        let state = tap != nil ? "работает" : (reverseWheel || !bindings.isEmpty ? "нет Универсального доступа" : "выключена")
        return "Мышь: обратное колесо \(reverseWheel ? "вкл" : "выкл"), кнопок \(bindings.count); перехват \(state); " +
            "развёрнуто прокруток \(reversedEvents), действий кнопок \(buttonActions)"
    }

    // MARK: Tap

    private func start() {
        guard AXIsProcessTrusted() else { return }
        let types: [CGEventType] = [.scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // Appended after the listening tap, so it still observes the clicks taken here.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MouseController>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { CFMachPortInvalidate(tap); return }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        taken.removeAll()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .scrollWheel:
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            if ScrollWheelReversal.applies(enabled: reverseWheel, isContinuous: continuous) {
                Self.reverse(event)
                reversedEvents += 1
            }
        case .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            let modifiers = ShortcutConflicts.modifiers(fromEventFlags: Int(event.flags.rawValue))
            if let recorded = onRecorded, MouseButtonBinding.bindableButtons.contains(button) {
                onRecorded = nil
                taken.insert(button)
                DispatchQueue.main.async { [weak self] in
                    self?.isRecording = false
                    recorded(button, modifiers)
                    self?.refresh()
                }
                return nil
            }
            guard let binding = bindings.first(where: { $0.matches(button: button, modifiers: modifiers) }) else { break }
            taken.insert(button)
            buttonActions += 1
            DispatchQueue.main.async { MouseActions.perform(binding.action) }
            return nil
        case .otherMouseDragged:
            if taken.contains(Int(event.getIntegerValueField(.mouseEventButtonNumber))) { return nil }
        case .otherMouseUp:
            guard taken.remove(Int(event.getIntegerValueField(.mouseEventButtonNumber))) != nil else { break }
            if taken.isEmpty { DispatchQueue.main.async { [weak self] in self?.refresh() } }
            return nil
        default: break
        }
        return pass
    }

    /// Both axes: natural scrolling turns a tilt wheel as well.
    private static func reverse(_ event: CGEvent) {
        let lines: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2]
        let points: [CGEventField] = [.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2]
        let fixed: [CGEventField] = [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2]
        // Read every field before writing: one setter can recompute another.
        let integers = (lines + points).map { ($0, event.getIntegerValueField($0)) }
        let doubles = fixed.map { ($0, event.getDoubleValueField($0)) }
        for (field, value) in integers { event.setIntegerValueField(field, value: -value) }
        for (field, value) in doubles { event.setDoubleValueField(field, value: -value) }
    }
}

/// What a mouse button does. Mission Control, application windows and the
/// desktop go through the Dock's own notification (what the function keys
/// use); without it, and for Spaces, the macOS shortcut from Keyboard
/// Shortcuts is posted.
enum MouseActions {
    private typealias DockNotify = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
    private static let dockNotify: DockNotify? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification")
        .map { unsafeBitCast($0, to: DockNotify.self) }

    static func perform(_ action: MouseAction) {
        switch action {
        case .missionControl: dock("com.apple.expose.awake", symbolicHotKey: 32, fallback: KeyShortcut(keyCode: 126, modifiers: .control))
        case .applicationWindows: dock("com.apple.expose.front.awake", symbolicHotKey: 33, fallback: KeyShortcut(keyCode: 125, modifiers: .control))
        case .desktop: dock("com.apple.showdesktop.awake", symbolicHotKey: 36, fallback: KeyShortcut(keyCode: 103, modifiers: []))
        case .spaceLeft: post(systemShortcut(79) ?? KeyShortcut(keyCode: 123, modifiers: .control))
        case .spaceRight: post(systemShortcut(81) ?? KeyShortcut(keyCode: 124, modifiers: .control))
        case .back, .forward, .shortcut: if let keys = action.keys { post(keys) }
        }
    }

    private static func dock(_ notification: String, symbolicHotKey id: Int, fallback: KeyShortcut) {
        if let dockNotify { dockNotify(notification as CFString, nil); return }
        post(systemShortcut(id) ?? fallback)
    }

    /// The user's binding for a macOS shortcut, when it is turned on.
    private static func systemShortcut(_ id: Int) -> KeyShortcut? {
        ShortcutChecks.systemEntries().shortcuts.first { $0.id == id && $0.enabled }?.shortcut
    }

    /// Arrow, navigation and function keys carry fn (arrows also the keypad
    /// flag) like the hardware, so macOS shortcuts stored with them match.
    private static func post(_ shortcut: KeyShortcut) {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        source.localEventsSuppressionInterval = 0
        let code = CGKeyCode(shortcut.keyCode)
        var flags = CGEventFlags()
        if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }
        if (123...126).contains(code) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        if [115, 116, 117, 119, 121].contains(code) || KeyNames.isFunctionKey(shortcut.keyCode) { flags.insert(.maskSecondaryFn) }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}
