import AppKit
import CoreGraphics

final class DiagnosticsWindow: NSWindowController, NSWindowDelegate {
    private let status = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    private let readStatus: () -> String
    private let runCheck: () -> Void
    private let requestCapture: () -> Void
    private let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 100))
    private let fixtureStatus = NSTextField(labelWithString: "")
    private var fixtureNeighbors: (prefix: NSAttributedString, suffix: NSAttributedString)?

    init(readStatus: @escaping () -> String, runCheck: @escaping () -> Void, requestCapture: @escaping () -> Void) {
        self.readStatus = readStatus
        self.runCheck = runCheck
        self.requestCapture = requestCapture
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Проверка SSwitcher"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        // Command-C/V reach the test editor through AppMainMenu's Edit menu.
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        if let parent = window.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 24),
                content.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -24),
                content.topAnchor.constraint(equalTo: parent.topAnchor, constant: 24)
            ])
        }
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        content.addArrangedSubview(status)
        let hint = NSTextField(wrappingLabelWithString: "Поставьте курсор после ghbdtn и дважды нажмите один и тот же Shift. Должно получиться «привет».")
        content.addArrangedSubview(hint)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        editor.isRichText = true
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .systemFont(ofSize: 22)
        editor.string = "ghbdtn"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.setAccessibilityLabel("Тестовый текст")
        scroll.documentView = editor
        content.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        let checks = NSStackView(views: [NSButton(title: "Проверить замену текста", target: self, action: #selector(check)),
                                         NSButton(title: "Переместить проверку на MacBook", target: self, action: #selector(moveToMacBook))])
        checks.orientation = .horizontal
        checks.spacing = 12
        content.addArrangedSubview(checks)
        let fixtures = NSStackView(views: [
            NSButton(title: "Слово рядом с вложением", target: self, action: #selector(attachmentWord)),
            NSButton(title: "Выделение у вложения", target: self, action: #selector(attachmentSelection)),
            NSButton(title: "Несколько строк", target: self, action: #selector(multilineSelection))
        ])
        fixtures.orientation = .horizontal
        fixtures.spacing = 8
        content.addArrangedSubview(fixtures)
        fixtureStatus.font = .systemFont(ofSize: 11)
        content.addArrangedSubview(fixtureStatus)
        let actions = NSStackView(views: [NSButton(title: "Разрешить анимацию замены…", target: self, action: #selector(allowCapture)),
                                         NSButton(title: "Скопировать диагностику", target: self, action: #selector(copyDiagnostics))])
        actions.orientation = .horizontal
        actions.spacing = 12
        content.addArrangedSubview(actions)
        status.stringValue = readStatus()
        window.center()
    }

    @objc private func allowCapture() { requestCapture() }
    @objc private func copyDiagnostics() { Self.copyReport(readStatus()) }

    /// The only explicit clipboard write: the user's "copy report" button.
    static func copyReport(_ status: String) {
        let report = "SSwitcher \(DiagnosticReports.version)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n" + status
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(report, forType: .string) { NSSound.beep() }
    }

    private func startUpdates() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.window?.isVisible == true, self.window?.isMiniaturized == false else { return }
            let value = self.readStatus()
            if self.status.stringValue != value { self.status.stringValue = value }
            self.updateFixtureStatus()
        }
        timer?.tolerance = 0.05
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
    func windowDidMiniaturize(_ notification: Notification) { timer?.invalidate(); timer = nil }
    func windowDidDeminiaturize(_ notification: Notification) { startUpdates() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(activateApplication: Bool = true) {
        moveToMacBook()
        startUpdates()
        if activateApplication {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window?.orderFront(nil)
        }
    }

    /// Only this owned window moves. Identify the built-in display through its
    /// public display ID, independent of main-screen order, name or arrangement.
    /// No activation, foreign AX access or display-setting change occurs here.
    @objc private func moveToMacBook() {
        guard let window, let screen = NSScreen.screens.first(where: { $0.displayID.map(CGDisplayIsBuiltin) ?? 0 != 0 })
        else { return }
        let work = screen.visibleFrame
        guard [work.minX, work.minY, work.width, work.height].allSatisfy({ $0.isFinite }),
              work.width > 0, work.height > 0 else { return }
        let size = NSSize(width: min(window.frame.width, work.width), height: min(window.frame.height, work.height))
        let origin = NSPoint(x: min(max(work.midX - size.width / 2, work.minX), work.maxX - size.width),
                             y: min(max(work.midY - size.height / 2, work.minY), work.maxY - size.height))
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    @objc private func check() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(editor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.runCheck() }
    }

    @objc private func attachmentWord() { prepareFixture(text: "ghbdtn", selected: false) }
    @objc private func attachmentSelection() { prepareFixture(text: "ghbdtn", selected: true) }
    @objc private func multilineSelection() { prepareFixture(text: "ghbdtn\nvbh 🙂 e\u{301}", selected: true) }

    /// These buttons replace only this diagnostic window's own disposable text.
    /// Preserve attributed neighbors to expose unintended attachment/style edits.
    private func prepareFixture(text: String, selected: Bool) {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
        attachment.bounds = NSRect(x: 0, y: 0, width: 24, height: 24)
        let value = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        value.append(NSAttributedString(string: "\nprefix ", attributes: [.font: NSFont.boldSystemFont(ofSize: 19)]))
        let start = value.length
        value.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 22)]))
        let end = value.length
        value.append(NSAttributedString(string: " suffix", attributes: [.font: NSFont.boldSystemFont(ofSize: 19)]))
        fixtureNeighbors = (value.attributedSubstring(from: NSRange(location: 0, length: start)),
                            value.attributedSubstring(from: NSRange(location: end, length: value.length - end)))
        editor.textStorage?.setAttributedString(value)
        editor.setSelectedRange(NSRange(location: selected ? start : end, length: selected ? end - start : 0))
        window?.makeFirstResponder(editor)
        updateFixtureStatus()
    }

    private func updateFixtureStatus() {
        guard let expected = fixtureNeighbors, let value = editor.textStorage else { return }
        let fits = value.length >= expected.prefix.length + expected.suffix.length
        let unchanged = fits &&
            value.attributedSubstring(from: NSRange(location: 0, length: expected.prefix.length)).isEqual(to: expected.prefix) &&
            value.attributedSubstring(from: NSRange(location: value.length - expected.suffix.length,
                                                    length: expected.suffix.length)).isEqual(to: expected.suffix)
        let message = unchanged ? "Вложение и оформление соседнего текста сохранены" : "Вложение или соседний текст изменились"
        if fixtureStatus.stringValue != message { fixtureStatus.stringValue = message }
    }

    deinit { timer?.invalidate() }
}
