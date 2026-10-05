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
            down.flags = flags
            // Leaving Command/Shift on key-up can leave Quartz's modifier/key
            // state sticky after our Copy or selection arrows. Release only
            // the synthetic shortcut state; hardware guards remain separate.
            up.flags = []
            for event in [down, up] {
                event.setIntegerValueField(.eventSourceUserData, value: marker)
                events.append(event)
            }
        }
        return events
    }

    static func post(_ events: [CGEvent]) {
        for event in events { event.post(tap: .cghidEventTap) }
    }

    /// Canvas selection has no truthful external atomic setter. Memory and
    /// main-run-loop work are bounded per batch, with no mandatory batch sleeps.
    static func restoreCanvasSelection(characterCount: Int, valid: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        func postBatch(_ remaining: Int) {
            guard valid() else { completion(false); return }
            let count = min(remaining, 32)
            guard count > 0 else { completion(true); return }
            guard let events = sequence(Array(repeating: (CGKeyCode(123), CGEventFlags.maskShift), count: count)) else {
                completion(false); return
            }
            post(events)
            if remaining == count { completion(true) }
            else { DispatchQueue.main.async { postBatch(remaining - count) } }
        }
        postBatch(characterCount)
    }
}
