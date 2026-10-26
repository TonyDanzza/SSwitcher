import AppKit
import SwitcherCore

private final class LockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Fills linearly while the unlock chord is held; drops back when released.
private final class HoldProgressView: NSView {
    private let track = CALayer()
    private let fill = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        track.addSublayer(fill)
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Удержание сочетания")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 268, height: 6) }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        track.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        fill.cornerRadius = bounds.height / 2
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        fill.bounds.size.height = bounds.height
        fill.position = CGPoint(x: 0, y: bounds.midY)
        CATransaction.commit()
    }

    /// Runs from `progress` to full in `duration` seconds.
    func run(from progress: Double, duration: Double) {
        animate(to: bounds.width, from: bounds.width * progress, duration: duration, timing: .linear)
    }

    func reset() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animate(to: 0, from: fill.presentation()?.bounds.width ?? fill.bounds.width, duration: reduce ? 0 : 0.2, timing: .easeOut)
    }

    private func animate(to width: CGFloat, from start: CGFloat, duration: Double, timing: CAMediaTimingFunctionName) {
        fill.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.bounds.size.width = width
        CATransaction.commit()
        guard duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = start
        animation.toValue = width
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        fill.add(animation, forKey: "width")
    }
}

/// Blocks the keyboard, trackpad and mouse while they are being wiped: one
/// HID-level tap swallows keys, the brightness, sound and media keys, pointer
/// moves, clicks, scrolling and gestures. Holding left and right
/// Option+Command for five seconds unlocks it (`KeyboardLockUnlock`). As a
/// safeguard it unlocks itself after a few minutes, and before the Mac sleeps
/// or locks its screen, where the password must be typed. The power button
/// and Touch ID cannot be blocked this way. If SSwitcher quits, macOS removes
/// the tap with the process.
final class KeyboardLock: NSObject {
    static let duration: TimeInterval = 3 * 60
    var onChange: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var panel: LockPanel?
    private let countdown = NSTextField(labelWithString: "")
    private let progress = HoldProgressView()
    private var unlock = KeyboardLockUnlock()
    private var fnDown = false
    private var holdWork: DispatchWorkItem?
    /// macOS moves the cursor before the tap sees the event; it is put back.
    private var cursor = CGPoint.zero
    private var timer: Timer?
    private var endDate: Date?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    var isActive: Bool { tap != nil }

    func start() {
        guard !isActive else { return }
        // Keys, NX_SYSDEFINED (brightness, sound, media), pointer, scroll,
        // tablet and trackpad gesture events (rotate…pressure).
        let types: [UInt32] = [10, 11, 12, 14, 1, 2, 3, 4, 5, 6, 7, 22, 23, 24, 25, 26, 27, 18, 19, 20, 29, 30, 31, 32, 34]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        guard AXIsProcessTrusted(), let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<KeyboardLock>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            StatusHUD.shared.show("Блокировка не включилась", detail: "Разрешите SSwitcher Универсальный доступ", force: true)
            return
        }
        self.tap = tap
        self.source = source
        unlock = KeyboardLockUnlock()
        fnDown = false
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        cursor = CGEvent(source: nil)?.location ?? .zero
        endDate = Date().addingTimeInterval(Self.duration)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        watchSleepAndScreenLock()
        showPanel()
        tick()
        onChange?()
    }

    func stop(notice: Bool = true) {
        guard isActive else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        holdWork?.cancel(); holdWork = nil
        timer?.invalidate(); timer = nil
        endDate = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        progress.reset()
        panel?.orderOut(nil)
        if notice { StatusHUD.shared.show("Клавиатура и трекпад разблокированы", detail: "Можно работать", force: true) }
        onChange?()
    }

    func menuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: "Заблокировать клавиатуру и трекпад", action: #selector(startFromMenu), keyEquivalent: "")
        item.target = self
        return [item]
    }

    @objc private func startFromMenu() { start() }

    // MARK: Tap

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = ProcessInfo.processInfo.systemUptime
        let wasHolding = unlock.isHoldingChord
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a slow tap off; the lock must not silently end.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            unlock.keyChanged(code: event.getIntegerValueField(.keyboardEventKeycode), down: type == .keyDown, at: now)
        case .flagsChanged:
            if event.getIntegerValueField(.keyboardEventKeycode) == 63 { fnDown = event.flags.contains(.maskSecondaryFn) }
            unlock.modifiersChanged(deviceFlags: event.flags.rawValue, fnDown: fnDown, at: now)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            CGWarpMouseCursorPosition(cursor)
        default:
            break
        }
        if unlock.isHoldingChord != wasHolding { holdChanged(at: now) }
        return nil
    }

    private func holdChanged(at now: Double) {
        holdWork?.cancel(); holdWork = nil
        guard let unlockTime = unlock.unlockTime else { progress.reset(); return }
        progress.run(from: unlock.progress(at: now), duration: max(0, unlockTime - now))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.unlock.shouldUnlock(at: ProcessInfo.processInfo.systemUptime) else { return }
            self.stop()
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, unlockTime - now), execute: work)
    }

    // MARK: Safeguards

    private func tick() {
        guard let endDate else { return }
        let left = max(0, Int(endDate.timeIntervalSinceNow.rounded()))
        guard left > 0 else { stop(); return }
        countdown.stringValue = String(format: "Блокировка снимется сама через\u{00A0}%d:%02d", left / 60, left % 60)
    }

    private func watchSleepAndScreenLock() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop(notice: false)
        }))
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.stop(notice: false)
        }))
    }

    // MARK: Panel

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = panel.frame.size
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: round(area.midX - size.width / 2), y: round(area.midY - size.height / 2)))
        }
        progress.reset()
        panel.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Клавиатура и трекпад заблокированы", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func keycap(_ text: String, width: CGFloat = 40, faded: Bool = false) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.alignment = .center
        label.textColor = faded ? .tertiaryLabelColor : .labelColor
        let cap = NSView()
        cap.wantsLayer = true
        cap.layer?.cornerRadius = 7
        cap.layer?.borderWidth = 1
        cap.layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(faded ? 0.25 : 0.6).cgColor
        cap.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(label)
        NSLayoutConstraint.activate([
            cap.widthAnchor.constraint(equalToConstant: width), cap.heightAnchor.constraint(equalToConstant: 36),
            label.centerXAnchor.constraint(equalTo: cap.centerXAnchor), label.centerYAnchor.constraint(equalTo: cap.centerYAnchor)
        ])
        return cap
    }

    private func makePanel() -> LockPanel {
        let panel = LockPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.setAccessibilityRole(.window)
        panel.setAccessibilityLabel("Клавиатура и трекпад заблокированы")

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "Клавиатура и трекпад заблокированы")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let detail = NSTextField(labelWithString: "Можно протирать: нажатия никуда не\u{00A0}попадут")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor

        let keys = NSStackView(views: [keycap("⌥"), keycap("⌘"), keycap("", width: 116, faded: true), keycap("⌘"), keycap("⌥")])
        keys.spacing = 6
        keys.setAccessibilityElement(true)
        keys.setAccessibilityLabel("Option и Command слева и справа от пробела")
        let hint = NSTextField(wrappingLabelWithString: "Чтобы разблокировать, держите эти клавиши 5\u{00A0}секунд")
        hint.font = .systemFont(ofSize: 13)
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 380
        hint.textColor = .labelColor
        countdown.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countdown.textColor = .secondaryLabelColor
        let note = NSTextField(labelWithString: "Кнопка питания и\u{00A0}Touch ID работают как обычно")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [title, detail, keys, progress, hint, countdown, note])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(22, after: detail)
        stack.setCustomSpacing(14, after: keys)
        stack.setCustomSpacing(14, after: progress)
        stack.setCustomSpacing(18, after: hint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            progress.widthAnchor.constraint(equalTo: keys.widthAnchor),
            progress.heightAnchor.constraint(equalToConstant: 6)
        ])
        panel.contentView = background
        return panel
    }

    deinit { stop(notice: false) }
}
