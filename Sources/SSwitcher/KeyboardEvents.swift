import CoreGraphics

enum KeyboardEvents {
    static let marker: Int64 = 0x53535749544348

    @discardableResult
    static func command(_ key: CGKeyCode) -> Bool {
        guard let events = sequence([(key, .maskCommand)]) else { return false }
        post(events)
        return true
    }

    static func sequence(_ keys: [(CGKeyCode, CGEventFlags)]) -> [CGEvent]? {
        guard CGPreflightPostEventAccess(), let source = CGEventSource(stateID: .privateState) else { return nil }
        var events: [CGEvent] = []
        for (key, flags) in keys {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return nil }
            for event in [down, up] {
                event.flags = flags
                event.setIntegerValueField(.eventSourceUserData, value: marker)
                events.append(event)
            }
        }
        return events
    }

    static func post(_ events: [CGEvent]) {
        for event in events { event.post(tap: .cghidEventTap) }
    }
}
