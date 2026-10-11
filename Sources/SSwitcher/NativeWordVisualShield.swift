import AppKit
import SwitcherCore

/// A short-lived, nonactivating snapshot hides MAX's intermediate selection.
/// It changes no text and never holds input. Missing capture capability leaves
/// the independently validated Services transaction unchanged.
final class NativeWordVisualShield {
    private let capture = ReplacementOverlay()
    private var generation = 0
    private var image: ImageOverlay?
    private var removal: DispatchWorkItem?
    private var preparationCompletion: (() -> Void)?
    private var started = 0.0
    private var earlyBounds: CGRect?
    private var earlyExpiry: DispatchWorkItem?

    /// Starts the snapshot at the gesture release, overlapping the Shift
    /// quiet interval. A matching `prepare` claims it; otherwise it closes
    /// itself shortly, so a gesture that never converts leaves no cover.
    func prepareEarly(bounds: CGRect?, valid: @escaping () -> Bool) {
        guard let bounds else { return }
        prepare(bounds: bounds, valid: valid) {}
        guard preparationCompletion != nil || image != nil else { return }
        earlyBounds = bounds
        let epoch = generation
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, self.generation == epoch, self.earlyBounds != nil else { return }
            self.cancel()
        }
        earlyExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + ConversionTiming.nativeVisualEarlyClaim, execute: expiry)
    }

    func prepare(bounds: CGRect?, valid: @escaping () -> Bool, completion: @escaping () -> Void) {
        if let early = earlyBounds, let bounds, early == bounds.integral || early == bounds {
            // Claim the snapshot already prepared for this window.
            earlyBounds = nil
            earlyExpiry?.cancel(); earlyExpiry = nil
            if let pending = preparationCompletion {
                preparationCompletion = { pending(); completion() }
            } else { completion() }
            return
        }
        cancel()
        let epoch = generation
        preparationCompletion = completion
        started = ProcessInfo.processInfo.systemUptime
        capture.prepare(bounds: bounds, padding: false, requiredMask: true, valid: valid) { [weak self] result in
            guard let self, self.generation == epoch else { return }
            switch result {
            case .ready(let image):
                guard valid() else { image.close(); self.completePreparation(); return }
                self.image = image
                let captureClosed = image.onClose
                image.onClose = { [weak self] in
                    captureClosed?()
                    guard let self, self.generation == epoch else { return }
                    self.image = nil
                }
                image.show(watchdogDuration: ConversionTiming.nativeVisualWatchdog)
                self.record("shown")
                // Allow the snapshot to reach the compositor before the first
                // native selection event. This is not editor acknowledgement.
                DispatchQueue.main.asyncAfter(deadline: .now() + ConversionTiming.nativeVisualPresentationSettle) { [weak self] in
                    guard let self, self.generation == epoch else { return }
                    self.completePreparation()
                }
            case .skipped:
                self.record("skipped", reason: self.capture.lastStatus)
                self.completePreparation()
            case .cancelled:
                self.record("cancelled")
                self.completePreparation()
            }
        }
    }

    func finish(submitted: Bool) {
        guard submitted, image != nil else { cancel(); return }
        let epoch = generation
        // Services publication precedes requestor drawing. Keep the snapshot
        // briefly after return, then remove it atomically, without a fade.
        let removal = DispatchWorkItem { [weak self] in
            guard let self, self.generation == epoch else { return }
            self.record("removedAfterSubmission")
            self.cancel()
        }
        self.removal = removal
        DispatchQueue.main.asyncAfter(deadline: .now() + ConversionTiming.nativeVisualCommitSettle, execute: removal)
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation += 1
        earlyBounds = nil
        earlyExpiry?.cancel(); earlyExpiry = nil
        let completion = preparationCompletion
        preparationCompletion = nil
        removal?.cancel(); removal = nil
        image?.close(); image = nil
        capture.cancel()
        // A visual cancellation must not strand an otherwise valid text
        // transaction. Its owner rechecks input/focus before starting keys.
        completion?()
    }

    private func completePreparation() {
        let completion = preparationCompletion
        preparationCompletion = nil
        completion?()
    }

    private func record(_ stage: String, reason: String? = nil) {
        var report: [String: Any] = ["stage": stage,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "elapsedMS": Int(max(0, ProcessInfo.processInfo.systemUptime - started) * 1000)]
        if let reason { report["reason"] = reason }
        UserDefaults.standard.set(report, forKey: "NativeWordVisualReport")
    }
}
