import AppKit
import ScreenCaptureKit
import SwitcherCore

private final class SnapshotPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Main-thread presenter owns both pending captures and visible panels. A late
/// screenshot completion cannot publish pixels after input/focus cancellation.
final class ReplacementOverlay {
    static var enabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "disableSmoothReplacement") }
        set { UserDefaults.standard.set(!newValue, forKey: "disableSmoothReplacement") }
    }
    private(set) var lastStatus = "Ожидание замены"
    private var pending: CaptureRequest?
    private var active: ImageOverlay?
    /// No capture is pending and no snapshot is on screen.
    var isIdle: Bool { pending == nil && active == nil }
    var canCapture: Bool {
        canCapture(requiredMask: false)
    }
    private func canCapture(requiredMask: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard requiredMask || (Self.enabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) else { lastStatus = "Анимация выключена"; return false }
        guard #available(macOS 15.2, *) else { lastStatus = "Анимация требует macOS 15.2"; return false }
        guard CGPreflightScreenCaptureAccess() else { lastStatus = "Для анимации разрешите запись экрана"; return false }
        return true
    }
    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        let request = pending; pending = nil
        request?.finish(.cancelled)
        active?.close(); active = nil
    }
    func prepare(bounds: CGRect?, padding: Bool = true, requiredMask: Bool = false, valid: @escaping () -> Bool, completion: @escaping (PreparationResult<ImageOverlay>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        cancel()
        guard canCapture(requiredMask: requiredMask) else { completion(.skipped); return }
        guard #available(macOS 15.2, *), let bounds, let primary = NSScreen.screens.first else {
            lastStatus = "Редактор не предоставил точные границы слова"; completion(.skipped); return
        }
        let padded = padding ? bounds.insetBy(dx: -max(10, bounds.width * 0.35), dy: -4).integral : bounds.integral
        let frame = CGRect(x: padded.minX, y: primary.frame.maxY - padded.maxY, width: padded.width, height: padded.height)
        guard NSScreen.screens.contains(where: { $0.frame.contains(frame) }), valid() else {
            lastStatus = "Анимация пропущена: границы вне экрана"; completion(.skipped); return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let request = CaptureRequest(completion: completion)
        pending = request
        let timeout = DispatchWorkItem { [weak self, weak request] in
            guard let self, let request, self.pending === request else { return }
            self.pending = nil
            self.lastStatus = "Анимация пропущена: превышено время захвата"
            request.finish(.skipped)
        }
        request.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + (requiredMask ? 0.2 : ConversionTiming.captureBudget), execute: timeout)
        SCScreenshotManager.captureImage(in: padded) { [weak self, weak request] image, _ in
            DispatchQueue.main.async {
                guard let self, let request, self.pending === request else { return }
                self.pending = nil
                guard valid() else { self.lastStatus = "Анимация пропущена: захват отменён"; request.finish(.cancelled); return }
                guard let image else { self.lastStatus = "Анимация пропущена: захват недоступен"; request.finish(.skipped); return }
                let overlay = ImageOverlay(image: image, frame: frame)
                self.active = overlay
                overlay.onClose = { [weak self, weak overlay] in
                    if self?.active === overlay { self?.active = nil }
                }
                self.lastStatus = "Снимок: \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) мс; переход: 90 мс"
                request.finish(.ready(overlay))
            }
        }
    }
    func skipMultiline() { lastStatus = "Анимация пропущена: многострочный текст" }
    private final class CaptureRequest {
        var timeout: DispatchWorkItem?
        private let delivery: PreparationDelivery<ImageOverlay>
        init(completion: @escaping (PreparationResult<ImageOverlay>) -> Void) { delivery = PreparationDelivery(completion: completion) }
        func finish(_ result: PreparationResult<ImageOverlay>) {
            timeout?.cancel(); timeout = nil
            delivery.complete(result)
        }
    }
}

/// Short-lived, click-through image. Closing releases image/view/window data.
final class ImageOverlay {
    var onClose: (() -> Void)?
    private let panel: NSPanel
    private var watchdog: DispatchWorkItem?
    private var closed = false
    private var revealed: (() -> Void)?
    init(image: CGImage, frame: CGRect) {
        dispatchPrecondition(condition: .onQueue(.main))
        panel = SnapshotPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setAccessibilityElement(false)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        // AppKit may animate even a borderless, nonactivating panel when it is
        // ordered in/out. Scaling a captured editor creates a whole-window
        // jump. The snapshot must enter and leave at its exact pixel geometry.
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        let view = NSImageView(frame: CGRect(origin: .zero, size: frame.size))
        view.image = NSImage(cgImage: image, size: frame.size)
        view.imageScaling = .scaleAxesIndependently
        view.setAccessibilityElement(false)
        panel.contentView = view
    }
    func show(watchdogDuration: Double = ConversionTiming.overlayWatchdog) {
        guard !closed else { return }
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        let watchdog = DispatchWorkItem { [weak self] in self?.close() }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogDuration, execute: watchdog)
    }
    func reveal(completion: @escaping () -> Void) {
        guard !closed else { completion(); return }
        guard ReplacementOverlay.enabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { close(); completion(); return }
        revealed = completion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ConversionTiming.revealDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in self?.close() }
    }
    func close() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !closed else { return }
        closed = true
        watchdog?.cancel(); watchdog = nil
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        let completion = revealed; revealed = nil
        completion?()
        let closedCallback = onClose; onClose = nil
        closedCallback?()
    }
    deinit { if !closed { close() } }
}
