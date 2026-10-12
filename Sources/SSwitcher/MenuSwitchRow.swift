import AppKit

/// A status-menu row with a switch on the right, like Control Center: a
/// title, an optional second line and the switch. Clicking anywhere on the
/// row flips it; the menu stays open so the result is visible.
final class MenuSwitchRow: NSView {
    let item = NSMenuItem()
    var onToggle: ((Bool) -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let details = NSStackView()
    private let toggle = MenuToggle()
    /// Matches the text of ordinary items in a menu without a state column.
    static let leadingInset: CGFloat = 17

    init(title text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        autoresizingMask = [.width]
        title.stringValue = text
        title.font = .menuFont(ofSize: 0)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        details.orientation = .horizontal
        details.spacing = 5
        details.alignment = .centerY
        toggle.onPress = { [weak self] in self?.flip() }
        toggle.setAccessibilityLabel(text)
        let labels = NSStackView(views: [title, details])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        for view in [labels, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.leadingInset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: MenuToggle.size.width),
            toggle.heightAnchor.constraint(equalToConstant: MenuToggle.size.height)
        ])
        item.view = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `details` parts are separated by thin vertical rules.
    func update(isOn: Bool, details parts: [String], enabled: Bool = true) {
        toggle.isOn = isOn
        toggle.isEnabled = enabled
        details.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, part) in parts.enumerated() {
            if index > 0 { details.addArrangedSubview(Self.rule()) }
            let label = NSTextField(labelWithString: part)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            details.addArrangedSubview(label)
        }
        details.isHidden = parts.isEmpty
        let height: CGFloat = parts.isEmpty ? 26 : 40
        setFrameSize(NSSize(width: frame.width, height: height))
        setAccessibilityElement(false)
        toggle.setAccessibilityHelp(parts.joined(separator: ", "))
    }

    /// Draws itself so the color follows light and dark menus.
    private final class Hairline: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.4).setFill()
            bounds.fill()
        }
    }

    private static func rule() -> NSView {
        let rule = Hairline()
        rule.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([rule.widthAnchor.constraint(equalToConstant: 1),
                                     rule.heightAnchor.constraint(equalToConstant: 9)])
        return rule
    }

    private func flip() {
        guard toggle.isEnabled else { return }
        toggle.isOn.toggle()
        onToggle?(toggle.isOn)
    }

    override func mouseUp(with event: NSEvent) { flip() }
}

/// A switch that keeps its accent color in a menu. Menus are never the key
/// window, so `NSSwitch` there draws "on" in inactive gray, which looks almost
/// like "off". Colors follow the accent color, light/dark and Increase Contrast.
final class MenuToggle: NSView {
    static let size = NSSize(width: 28, height: 16)
    var onPress: (() -> Void)?
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true; moveKnob() } } }
    var isEnabled = true { didSet { needsDisplay = true } }
    private let knob = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.size.height / 2
        knob.backgroundColor = NSColor.white.cgColor
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 1
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(knob)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let track = isOn ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.15)
            layer?.backgroundColor = (isEnabled ? track : track.withAlphaComponent(0.3)).cgColor
            layer?.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
        setAccessibilityValue(isOn ? 1 : 0)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeKnob()
        CATransaction.commit()
    }

    private func moveKnob() {
        CATransaction.begin()
        CATransaction.setDisableActions(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        CATransaction.setAnimationDuration(0.15)
        placeKnob()
        CATransaction.commit()
    }

    private func placeKnob() {
        let side = bounds.height - 4
        knob.frame = CGRect(x: isOn ? bounds.width - side - 2 : 2, y: 2, width: side, height: side)
        knob.cornerRadius = side / 2
    }

    /// The row handles clicks, so the whole line is one target.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
