import AppKit
import SwiftUI
import SwitcherCore

/// Click, then press a combination. Esc cancels; Delete clears when the
/// shortcut is optional. macOS has no public recorder control, so this view
/// draws a field-like bezel and reads key events while it is first responder.
final class ShortcutRecorderView: NSView {
    var shortcut: KeyShortcut? { didSet { refresh() } }
    var allowsEmpty = true
    var onChange: ((KeyShortcut?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    /// Extra checks, such as a clash with another SSwitcher shortcut.
    var validate: ((KeyShortcut) -> String?)?

    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            live = []
            message = nil
            onRecordingChange?(isRecording)
            refresh()
        }
    }
    private var live: NSEvent.ModifierFlags = []
    private var message: String?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        if isRecording { window?.makeFirstResponder(nil); return }
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            if event.keyCode == 49 || event.keyCode == 36 { isRecording = true } else { super.keyDown(with: event) }
            return
        }
        record(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        live = event.modifierFlags.intersection([.control, .option, .shift, .command])
        refresh()
    }

    private func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if flags.isEmpty && event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        if flags.isEmpty && (event.keyCode == 51 || event.keyCode == 117) && allowsEmpty {
            shortcut = nil
            onChange?(nil)
            window?.makeFirstResponder(nil)
            return
        }
        var modifiers: KeyShortcut.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        let candidate = KeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        let problem: String?
        switch candidate.problem {
        case .needsModifier: problem = "Добавьте ⌃, ⌥ или ⌘"
        case .reserved: problem = "Занято macOS"
        case .modifierKey: return
        case nil: problem = validate?(candidate)
        }
        if let problem {
            message = problem
            NSSound.beep()
            refresh()
            return
        }
        shortcut = candidate
        onChange?(candidate)
        window?.makeFirstResponder(nil)
    }

    private var text: String {
        if isRecording {
            if let message { return message }
            return live.isEmpty ? "Нажмите сочетание" : KeyShortcut.Modifiers(flags: live).symbols
        }
        return shortcut.map(KeyNames.string) ?? "Не задано"
    }

    private func refresh() {
        setAccessibilityLabel("Сочетание клавиш: \(shortcut.map(KeyNames.string) ?? "не задано")")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        shape.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let color: NSColor = message != nil && isRecording ? .systemRed
            : (shortcut == nil && !isRecording ? .placeholderTextColor : .labelColor)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: color]
        let value = NSAttributedString(string: text, attributes: attributes)
        let size = value.size()
        value.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

private extension KeyShortcut.Modifiers {
    init(flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}

struct ShortcutField: NSViewRepresentable {
    @Binding var shortcut: KeyShortcut?
    var allowsEmpty = true
    var validate: ((KeyShortcut) -> String?)?
    var onRecordingChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.setContentHuggingPriority(.required, for: .horizontal)
        update(view)
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) { update(view) }

    private func update(_ view: ShortcutRecorderView) {
        if view.shortcut != shortcut { view.shortcut = shortcut }
        view.allowsEmpty = allowsEmpty
        view.validate = validate
        view.onChange = { shortcut = $0 }
        view.onRecordingChange = onRecordingChange
    }
}
