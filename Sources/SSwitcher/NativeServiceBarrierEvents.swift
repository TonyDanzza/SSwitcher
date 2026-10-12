import Carbon
import AppKit
import CoreGraphics
import SwitcherCore

/// Immutable non-text key batches for the MAX Services transaction. Context
/// and window ownership must be proved by the caller before dispatch.
enum NativeServiceBarrierEvents {
    /// Preserve AppKit's native window routing while retaining the isolated
    /// source, exact non-text key and neutral release of the original batch.
    static func boundToWindow(_ events: [CGEvent], number: Int) -> [CGEvent]? {
        guard number > 0 else { return nil }
        var result: [CGEvent] = []
        for event in events {
            guard event.type == .keyDown || event.type == .keyUp,
                  let source = CGEventSource(event: event),
                  let native = NSEvent(cgEvent: event), let characters = native.characters,
                  let ignoring = native.charactersIgnoringModifiers,
                  let framed = NSEvent.keyEvent(with: native.type, location: .zero,
                    modifierFlags: native.modifierFlags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil,
                    characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: native.keyCode),
                  let routed = framed.cgEvent else { return nil }
            routed.setSource(source)
            // AppKit marks special navigation/function characters with Fn.
            // Retain that metadata on key-down; key-up must still be neutral.
            routed.flags = event.type == .keyDown ? CGEventFlags(rawValue: UInt64(native.modifierFlags.rawValue)) : []
            routed.setIntegerValueField(.eventSourceUserData, value: event.getIntegerValueField(.eventSourceUserData))
            result.append(routed)
        }
        return result
    }
    static func batch(_ navigation: [(CGKeyCode, CGEventFlags)]) -> [CGEvent]? {
        let modifiers: CGEventFlags = [.maskShift, .maskCommand, .maskControl, .maskAlternate]
        guard CGPreflightPostEventAccess(), !IsSecureEventInputEnabled(),
              CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty,
              !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Function)) else { return nil }
        // Synthetic modifiers must not become hardware state: the conversion
        // guard also checks real held Shift/Option keys between commands.
        return KeyboardNavigationEvents.make(navigation, sourceMarker: KeyboardEventDelivery.sourceMarker, state: .privateState)
    }
}
