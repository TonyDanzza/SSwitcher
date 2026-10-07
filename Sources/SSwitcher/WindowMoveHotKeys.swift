import AppKit
import Carbon
import SwitcherCore

/// Carbon owns only the four registered shortcuts. The conversion listener
/// stays listen-only; disabling this feature removes every registration.
final class WindowMoveHotKeys {
    var onMove: ((WindowMoveDirection) -> Void)?
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var presses = WindowShortcutPressGate()
    private let signature: OSType = 0x5353574D // SSWM
    private(set) var lastError: OSStatus?
    var isRegistered: Bool { registrations.count == 4 }

    @discardableResult
    func start() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if isRegistered { return true }
        stop()
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let result = InstallEventHandler(GetApplicationEventTarget(), { next, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<WindowMoveHotKeys>.fromOpaque(context).takeUnretainedValue()
            return owner.handle(event) ? noErr : CallNextEventHandler(next, event)
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { lastError = result; stop(); return false }
        for (direction, code) in [(WindowMoveDirection.left, kVK_LeftArrow), (.right, kVK_RightArrow), (.up, kVK_UpArrow), (.down, kVK_DownArrow)] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(code), UInt32(optionKey | shiftKey),
                EventHotKeyID(signature: signature, id: direction.rawValue), GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive), &reference)
            guard result == noErr, let reference else { lastError = result; stop(); return false }
            registrations.append(reference)
        }
        lastError = nil
        return true
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
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
              identifier.signature == signature, let direction = WindowMoveDirection(rawValue: identifier.id) else { return false }
        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            if presses.press(identifier.id) { onMove?(direction) }
        case UInt32(kEventHotKeyReleased): presses.release(identifier.id)
        default: return false
        }
        return true
    }

    deinit { stop() }
}
