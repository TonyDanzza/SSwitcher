import AppKit

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A short, non-activating notice below the menu bar, so a global shortcut
/// confirms what it changed without taking focus from the user's editor.
final class StatusHUD {
    private var panel: HUDPanel?
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    func show(_ text: String, detail subtitle: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let panel = self.panel ?? makePanel()
        self.panel = panel
        title.stringValue = text
        detail.stringValue = subtitle
        let width = max(220, ceil(max(title.intrinsicContentSize.width, detail.intrinsicContentSize.width)) + 40)
        let size = NSSize(width: width, height: 64)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            panel.setFrame(NSRect(x: round(area.midX - size.width / 2), y: round(area.maxY - size.height - 12),
                                  width: size.width, height: size.height), display: true)
        }
        hideWork?.cancel()
        generation += 1
        let shown = generation
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !panel.isVisible {
            panel.alphaValue = animate ? 0 : 1
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? 0.12 : 0
            panel.animator().alphaValue = 1
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(text), \(subtitle)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let work = DispatchWorkItem { [weak self] in self?.hide(shown, animated: animate) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func hide(_ shown: Int, animated: Bool) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated ? 0.25 : 0
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A newer notice shown during the fade keeps the panel.
            guard self?.generation == shown else { return }
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 64),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        panel.contentView = background
        panel.setAccessibilityRole(.popover)
        return panel
    }
}
