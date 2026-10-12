import AppKit
import Carbon
import SwitcherCore

/// Carbon shortcuts under one signature: one event handler, any number of
/// registrations and press/release pairing per id, so a held key fires once.
/// Carbon shortcuts need no privacy permission; each signature coexists.
final class CarbonHotKeySet {
    var onPress: ((UInt32) -> Void)?
    private let signature: OSType
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var presses = WindowShortcutPressGate()
    var isRegistered: Bool { !registrations.isEmpty }

    init(signature: OSType) { self.signature = signature }

    /// Replaces every registration. On failure nothing stays registered and
    /// the Carbon status is returned.
    func register(_ keys: [(id: UInt32, keyCode: UInt32, modifiers: UInt32)]) -> OSStatus {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        guard !keys.isEmpty else { return noErr }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let installed = InstallEventHandler(GetApplicationEventTarget(), { next, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<CarbonHotKeySet>.fromOpaque(context).takeUnretainedValue()
            return owner.handle(event) ? noErr : CallNextEventHandler(next, event)
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { stop(); return installed }
        for key in keys {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: signature, id: key.id),
                                             GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            guard result == noErr, let reference else { stop(); return result }
            registrations.append(reference)
        }
        return noErr
    }

    func stop() {
        for reference in registrations { UnregisterEventHotKey(reference) }
        registrations.removeAll()
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
            if presses.press(identifier.id) { onPress?(identifier.id) }
        case UInt32(kEventHotKeyReleased): presses.release(identifier.id)
        default: return false
        }
        return true
    }

    deinit { stop() }
}

/// One Carbon shortcut chosen in Settings.
final class GlobalHotKey {
    var onPress: (() -> Void)?
    private let keys: CarbonHotKeySet
    private(set) var shortcut: KeyShortcut?
    var isRegistered: Bool { keys.isRegistered }
    /// A shortcut was requested and macOS refused it (usually taken elsewhere).
    var isBlocked: Bool { shortcut != nil && !isRegistered }

    init(signature: OSType) {
        keys = CarbonHotKeySet(signature: signature)
        keys.onPress = { [weak self] _ in self?.onPress?() }
    }

    /// Registers `shortcut`, or removes the registration for nil.
    @discardableResult
    func start(_ shortcut: KeyShortcut?) -> Bool {
        if isRegistered && shortcut == self.shortcut { return true }
        self.shortcut = shortcut
        guard let shortcut else { keys.stop(); return true }
        return keys.register([(1, shortcut.keyCode, shortcut.modifiers.rawValue)]) == noErr
    }

    /// Removes the registration and forgets the shortcut.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        keys.stop()
        shortcut = nil
    }
}
