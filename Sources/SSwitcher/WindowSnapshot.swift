import AppKit
import ScreenCaptureKit
import SwitcherCore

private final class SnapshotPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One in-memory screenshot of exact screen bounds, for the MAX visual
/// shield. The main-thread owner holds the pending capture and the visible
/// panel; a late completion cannot publish pixels after cancellation.
final class WindowSnapshot {
    private(set) var lastStatus = "Ожидание снимка"
    private var pending: CaptureRequest?
    private var active: ImageOverlay?

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        let request = pending; pending = nil
        request?.finish(.cancelled)
        active?.close(); active = nil
    }

    func prepare(bounds: CGRect?, valid: @escaping () -> Bool, completion: @escaping (PreparationResult<ImageOverlay>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        cancel()
        guard #available(macOS 15.2, *) else { lastStatus = "Снимок требует macOS 15.2"; completion(.skipped); return }
        guard CGPreflightScreenCaptureAccess() else { lastStatus = "Для снимка разрешите запись экрана"; completion(.skipped); return }
        guard let bounds, let primary = NSScreen.screens.first else {
            lastStatus = "Нет точных границ окна"; completion(.skipped); return
        }
        let area = bounds.integral
        let frame = CGRect(x: area.minX, y: primary.frame.maxY - area.maxY, width: area.width, height: area.height)
        guard NSScreen.screens.contains(where: { $0.frame.contains(frame) }), valid() else {
            lastStatus = "Снимок пропущен: границы вне экрана"; completion(.skipped); return
        }
        let request = CaptureRequest(completion: completion)
        pending = request
        let timeout = DispatchWorkItem { [weak self, weak request] in
            guard let self, let request, self.pending === request else { return }
            self.pending = nil
            self.lastStatus = "Снимок пропущен: превышено время захвата"
            request.finish(.skipped)
        }
        request.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + ConversionTiming.snapshotBudget, execute: timeout)
        SCScreenshotManager.captureImage(in: area) { [weak self, weak request] image, _ in
            DispatchQueue.main.async {
                guard let self, let request, self.pending === request else { return }
                self.pending = nil
                guard valid() else { self.lastStatus = "Снимок отменён"; request.finish(.cancelled); return }
                guard let image else { self.lastStatus = "Снимок недоступен"; request.finish(.skipped); return }
                let overlay = ImageOverlay(image: image, frame: frame)
                self.active = overlay
                overlay.onClose = { [weak self, weak overlay] in
                    if self?.active === overlay { self?.active = nil }
                }
                self.lastStatus = "Снимок готов"
                request.finish(.ready(overlay))
            }
        }
    }

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
    func show(watchdogDuration: Double) {
        guard !closed else { return }
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        let watchdog = DispatchWorkItem { [weak self] in self?.close() }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogDuration, execute: watchdog)
    }
    func close() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !closed else { return }
        closed = true
        watchdog?.cancel(); watchdog = nil
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        let closedCallback = onClose; onClose = nil
        closedCallback?()
    }
    deinit { if !closed { close() } }
}
