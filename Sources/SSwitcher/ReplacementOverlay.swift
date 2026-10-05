import AppKit
import ScreenCaptureKit

/// A short-lived, click-through image of the old word. Never activates or stores pixels on disk.
private final class SnapshotPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ReplacementOverlay {
    static var enabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "disableSmoothReplacement") }
        set { UserDefaults.standard.set(!newValue, forKey: "disableSmoothReplacement") }
    }
    static var active: ReplacementOverlay?
    static var lastStatus = "Ожидание замены"
    private let panel: NSPanel
    private var watchdog: DispatchWorkItem?
    private var closed = false

    static func cancel() { active?.close() }

    static func bounds(of element: AXUIElement, range: NSRange) -> CGRect? {
        guard range.length > 0 else { return nil }
        func rect(_ range: NSRange) -> CGRect? {
            var value = CFRange(location: range.location, length: range.length)
            guard let parameter = AXValueCreate(.cfRange, &value) else { return nil }
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result) == .success,
                  let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
            var rectangle = CGRect.zero
            guard AXValueGetValue(result as! AXValue, .cgRect, &rectangle) else { return nil }
            return rectangle
        }
        // Reject empty, multiline and inconsistent AX geometry (common in canvas editors).
        guard let full = rect(range), full.width > 1, full.height >= 5,
              let first = rect(NSRange(location: range.location, length: 1)),
              let last = rect(NSRange(location: NSMaxRange(range) - 1, length: 1)),
              full.origin.x.isFinite, full.origin.y.isFinite,
              full.width.isFinite, full.height.isFinite,
              full.width > 1, full.width <= 900, full.height >= 5, full.height <= 180,
              first.width > 0, last.width > 0,
              abs(first.midY - last.midY) < 3,
              full.insetBy(dx: -2, dy: -2).contains(first),
              full.insetBy(dx: -2, dy: -2).contains(last),
              range.length == 1 || last.minX > first.minX else { return nil }
        return full
    }

    static func prepare(element: AXUIElement?, range: NSRange?, valid: @escaping () -> Bool,
                        completion: @escaping (ReplacementOverlay?) -> Void) {
        cancel()
        guard enabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            lastStatus = "Анимация выключена"; completion(nil); return
        }
        guard #available(macOS 15.2, *) else {
            lastStatus = "Анимация требует macOS 15.2"; completion(nil); return
        }
        guard let element, let range, let bounds = bounds(of: element, range: range),
              let primary = NSScreen.screens.first else {
            lastStatus = "Редактор не предоставил точные границы слова"; completion(nil); return
        }
        guard CGPreflightScreenCaptureAccess() else {
            lastStatus = "Для анимации разрешите запись экрана"; completion(nil); return
        }
        // AX/ScreenCaptureKit use top-left screen coordinates; AppKit uses bottom-left.
        let padded = bounds.insetBy(dx: -max(10, bounds.width * 0.35), dy: -4).integral
        let appKit = CGRect(x: padded.minX, y: primary.frame.maxY - padded.maxY,
                            width: padded.width, height: padded.height)
        guard NSScreen.screens.contains(where: { $0.frame.contains(appKit) }), valid() else {
            lastStatus = "Анимация пропущена: границы вне экрана"; completion(nil); return
        }
        let started = ProcessInfo.processInfo.systemUptime
        var delivered = false
        // Never let a cold screenshot service hold up text replacement indefinitely.
        let timeout = DispatchWorkItem {
            guard !delivered else { return }
            delivered = true
            lastStatus = "Анимация пропущена: захват дольше 100 мс"
            completion(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: timeout)
        SCScreenshotManager.captureImage(in: padded) { image, _ in
            DispatchQueue.main.async {
                guard !delivered else { return }
                delivered = true
                timeout.cancel()
                guard let image, valid() else {
                    lastStatus = "Анимация пропущена: захват отменён"; completion(nil); return
                }
                let overlay = ReplacementOverlay(image: image, frame: appKit)
                active = overlay
                lastStatus = "Снимок: \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) мс; переход: 120 мс"
                completion(overlay)
            }
        }
    }

    private init(image: CGImage, frame: CGRect) {
        panel = SnapshotPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setAccessibilityElement(false)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        let view = NSImageView(frame: CGRect(origin: .zero, size: frame.size))
        view.image = NSImage(cgImage: image, size: frame.size)
        view.imageScaling = .scaleAxesIndependently
        view.setAccessibilityElement(false)
        panel.contentView = view
    }

    func show() {
        guard !closed else { return }
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        let watchdog = DispatchWorkItem { [weak self] in self?.close() }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: watchdog)
    }

    func reveal() {
        guard !closed else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in self?.close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        watchdog?.cancel()
        watchdog = nil
        panel.orderOut(nil)
        panel.contentView = nil
        if Self.active === self { Self.active = nil }
    }
}
