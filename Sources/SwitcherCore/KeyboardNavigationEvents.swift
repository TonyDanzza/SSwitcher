import AppKit
import Carbon
import CoreGraphics

/// Constructs non-text navigation without posting events. Modifiers belong to
/// each arrow event; no separate Shift/Option press can remain held globally.
public enum KeyboardNavigationEvents {
    public static func make(_ sequence: [(CGKeyCode, CGEventFlags)], sourceMarker: Int64,
                            state: CGEventSourceStateID = .privateState) -> [CGEvent]? {
        let allowed: CGEventFlags = [.maskShift, .maskAlternate, .maskCommand, .maskControl]
        let keys: Set<CGKeyCode> = [123, 124, 125, 126, 80, 90]
        guard !sequence.isEmpty, sequence.count <= 257,
              sequence.allSatisfy({ keys.contains($0.0) && $0.1.subtracting(allowed).isEmpty }),
              let source = SyntheticKeyboardSource.make(state: state) else { return nil }
        source.userData = sourceMarker
        source.keyboardType = UInt32(LMGetKbdType())
        var events: [CGEvent] = []
        for (key, flags) in sequence {
            let down: CGEvent
            let up: CGEvent
            if let arrow = arrowCharacter(key) {
                // A raw Quartz arrow carries an ASCII control character. Build
                // the AppKit navigation envelope instead: its native special
                // character is retained without a Unicode text payload.
                guard let press = nativeArrow(key: key, character: arrow, down: true, flags: flags, source: source),
                      let release = nativeArrow(key: key, character: arrow, down: false, flags: [], source: source) else { return nil }
                down = press; up = release
            } else {
                guard let press = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                      let release = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return nil }
                down = press; up = release
            }
            // Service function keys carry their explicit native character.
            let character: UniChar?
            switch key {
            case CGKeyCode(kVK_F20): character = 0xf717
            case CGKeyCode(kVK_F19): character = 0xf716
            default: character = nil
            }
            down.flags = flags
            // A synthetic key-up carrying Shift/Option can leave Quartz's
            // aggregate modifier state set after the batch. End each pair
            // with neutral flags; the next arrow carries its own modifiers.
            up.flags = []
            for event in [down, up] {
                if var character {
                    event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                }
                event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
                event.setIntegerValueField(.eventSourceUserData, value: sourceMarker)
            }
            events += [down, up]
        }
        return events
    }

    private static func arrowCharacter(_ key: CGKeyCode) -> String? {
        switch key {
        case CGKeyCode(kVK_LeftArrow): return "\u{f702}"
        case CGKeyCode(kVK_RightArrow): return "\u{f703}"
        case CGKeyCode(kVK_UpArrow): return "\u{f700}"
        case CGKeyCode(kVK_DownArrow): return "\u{f701}"
        default: return nil
        }
    }

    private static func nativeArrow(key: CGKeyCode, character: String, down: Bool,
                                    flags: CGEventFlags, source: CGEventSource) -> CGEvent? {
        guard let native = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)),
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: key),
              let event = native.cgEvent else { return nil }
        event.setSource(source)
        event.flags = flags
        event.setIntegerValueField(.keyboardEventKeyboardType, value: Int64(source.keyboardType))
        return event
    }
}
