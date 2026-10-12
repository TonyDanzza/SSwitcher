import AppKit
import Carbon
import SwitcherCore

/// One Carbon shortcut chosen in Settings. Carbon shortcuts need no privacy
/// permission. Each instance has its own signature, so several coexist.
final class GlobalHotKey {
    var onPress: (() -> Void)?
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var presses = WindowShortcutPressGate()
    private let signature: OSType
    private(set) var shortcut: KeyShortcut?
    private(set) var lastError: OSStatus?
    var isRegistered: Bool { registration != nil }
    /// A shortcut was requested and macOS refused it (usually taken elsewhere).
    var isBlocked: Bool { shortcut != nil && !isRegistered }

    init(signature: OSType) { self.signature = signature }

    /// Registers `shortcut`, or removes the registration for nil.
    @discardableResult
    func start(_ shortcut: KeyShortcut?) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if isRegistered && shortcut == self.shortcut { return true }
        stop()
        self.shortcut = shortcut
        guard let shortcut else { return true }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let result = InstallEventHandler(GetApplicationEventTarget(), { next, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            return owner.handle(event) ? noErr : CallNextEventHandler(next, event)
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { lastError = result; removeHandler(); return false }
        var reference: EventHotKeyRef?
        let registered = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers.rawValue,
            EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        guard registered == noErr, let reference else { lastError = registered; removeHandler(); return false }
        registration = reference
        lastError = nil
        return true
    }

    /// Removes the registration and forgets the shortcut.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let registration { UnregisterEventHotKey(registration) }
        registration = nil
        shortcut = nil
        removeHandler()
    }

    private func removeHandler() {
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        presses.reset()
    }

    private func handle(_ event: EventRef) -> Bool {
        guard isRegistered, GetEventClass(event) == OSType(kEventClassKeyboard) else { return false }
        var identifier = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
              identifier.signature == signature else { return false }
        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            if presses.press(identifier.id) { onPress?() }
        case UInt32(kEventHotKeyReleased): presses.release(identifier.id)
        default: return false
        }
        return true
    }

    deinit { if registration != nil || handler != nil { stop() } }
}
