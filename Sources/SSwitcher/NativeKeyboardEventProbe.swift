import AppKit
import CoreGraphics

/// Explicit, finite, listen-only comparison of one navigation event in MAX.
/// Stores event metadata only, never typed text or clipboard contents.
enum NativeKeyboardEventProbe {
    private static var tap: CFMachPort?
    private static var source: CFRunLoopSource?
    private static var expiry: DispatchWorkItem?

    static func start() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "ru.oneme.desktop")
        guard apps.count == 1, let app = apps.first else { return }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let port = CGEvent.tapCreateForPid(pid: app.processIdentifier, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, _ in
                let key = event.getIntegerValueField(.keyboardEventKeycode)
                guard type == .keyDown, [123, 124].contains(key) else { return Unmanaged.passUnretained(event) }
                let native = NSEvent(cgEvent: event)
                var unit: UniChar = 0
                var count = 0
                event.keyboardGetUnicodeString(maxStringLength: 1, actualStringLength: &count, unicodeString: &unit)
                UserDefaults.standard.set(["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                    "flags": event.flags.rawValue, "nativeFlags": native?.modifierFlags.rawValue ?? 0,
                    "windowNumber": native?.windowNumber ?? 0, "key": key,
                    "unicodeCount": count, "specialUnicode": count == 1 && (0xf700...0xf717).contains(unit),
                    "charactersAreArrow": native?.characters == (key == 123 ? "\u{f702}" : "\u{f703}"),
                    "ignoringModifiersAreArrow": native?.charactersIgnoringModifiers == (key == 123 ? "\u{f702}" : "\u{f703}"),
                    "keyboardType": event.getIntegerValueField(.keyboardEventKeyboardType),
                    "sourceState": event.getIntegerValueField(.eventSourceStateID)] as [String: Any],
                    forKey: "NativeKeyboardEventProbeReport")
                DispatchQueue.main.async { NativeKeyboardEventProbe.stop() }
                return Unmanaged.passUnretained(event)
            }, userInfo: nil), let runSource = CFMachPortCreateRunLoopSource(nil, port, 0) else { return }
        tap = port; source = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        let item = DispatchWorkItem { stop() }
        expiry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }

    private static func stop() {
        expiry?.cancel(); expiry = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil; source = nil
    }
}
