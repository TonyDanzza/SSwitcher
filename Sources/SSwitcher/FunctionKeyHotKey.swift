import AppKit
import Carbon
import SwitcherCore

/// Control+Option+Command+F toggles the top-row mode. Carbon shortcuts need no
/// privacy permission, so this works before Input Monitoring is granted.
final class FunctionKeyHotKey {
    var onPress: (() -> Void)?
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var presses = WindowShortcutPressGate()
    private let signature: OSType = 0x5353464E // SSFN
    private(set) var lastError: OSStatus?
    var isRegistered: Bool { registration != nil }

    @discardableResult
    func start() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if isRegistered { return true }
        stop()
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let result = InstallEventHandler(GetApplicationEventTarget(), { next, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<FunctionKeyHotKey>.fromOpaque(context).takeUnretainedValue()
            return owner.handle(event) ? noErr : CallNextEventHandler(next, event)
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { lastError = result; stop(); return false }
        var reference: EventHotKeyRef?
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_F), UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        guard registered == noErr, let reference else { lastError = registered; stop(); return false }
        registration = reference
        lastError = nil
        return true
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let registration { UnregisterEventHotKey(registration) }
        registration = nil
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

    deinit { stop() }
}
