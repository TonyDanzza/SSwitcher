import AppKit

final class DiagnosticsWindow: NSWindowController, NSWindowDelegate {
    private let status = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    private let readStatus: () -> String
    private let runCheck: () -> Void
    private let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 100))

    init(readStatus: @escaping () -> String, runCheck: @escaping () -> Void) {
        self.readStatus = readStatus
        self.runCheck = runCheck
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Проверка SSwitcher"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        // AppKit routes Command-C/V through the main menu's responder actions.
        // A menu-bar-only app otherwise has no Edit menu for this test editor.
        if NSApp.mainMenu == nil {
            let main = NSMenu()
            let item = NSMenuItem()
            let edit = NSMenu(title: "Правка")
            for (title, action, key) in [
                ("Отменить", "undo:", "z"), ("Вырезать", "cut:", "x"),
                ("Скопировать", "copy:", "c"), ("Вставить", "paste:", "v"),
                ("Выделить всё", "selectAll:", "a")
            ] {
                edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
            }
            item.submenu = edit
            main.addItem(item)
            NSApp.mainMenu = main
        }
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
        editor.isRichText = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .systemFont(ofSize: 22)
        editor.string = "ghbdtn"
        editor.setAccessibilityLabel("Тестовый текст")
        scroll.documentView = editor
        content.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        content.addArrangedSubview(NSButton(title: "Проверить замену текста", target: self, action: #selector(check)))
        status.stringValue = readStatus()
        window.center()
    }

    private func startUpdates() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let value = self.readStatus()
            if self.status.stringValue != value { self.status.stringValue = value }
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        startUpdates()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func check() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(editor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.runCheck() }
    }

    deinit { timer?.invalidate() }
}
