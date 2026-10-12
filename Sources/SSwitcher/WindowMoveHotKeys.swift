import AppKit
import Carbon
import SwitcherCore

/// Carbon owns only the registered arrow shortcuts: the directions chosen in
/// Settings (by default those with a neighboring display) with the chosen
/// modifiers. The conversion listener stays listen-only; disabling this
/// feature removes every registration.
final class WindowMoveHotKeys {
    var onMove: ((WindowMoveDirection) -> Void)?
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var presses = WindowShortcutPressGate()
    private let signature: OSType = 0x5353574D // SSWM
    private(set) var lastError: OSStatus?
    private(set) var directions: Set<WindowMoveDirection> = []
    private(set) var modifiers: KeyShortcut.Modifiers = [.option, .shift]
    var isRegistered: Bool { !registrations.isEmpty && registrations.count == directions.count }

    @discardableResult
    func start(directions: Set<WindowMoveDirection>, modifiers: KeyShortcut.Modifiers) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if isRegistered && directions == self.directions && modifiers == self.modifiers { return true }
        stop()
        self.directions = directions
        self.modifiers = modifiers
        guard !directions.isEmpty else { return false }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let result = InstallEventHandler(GetApplicationEventTarget(), { next, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<WindowMoveHotKeys>.fromOpaque(context).takeUnretainedValue()
            return owner.handle(event) ? noErr : CallNextEventHandler(next, event)
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { lastError = result; stop(); return false }
        for (direction, code) in [(WindowMoveDirection.left, kVK_LeftArrow), (.right, kVK_RightArrow), (.up, kVK_UpArrow), (.down, kVK_DownArrow)]
        where directions.contains(direction) {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(code), modifiers.rawValue,
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
