import CoreGraphics
import Foundation
import SwitcherCore

enum KeyboardEvents {
    static let marker = KeyboardEventDelivery.sourceMarker
    private static var delivery = KeyboardEventDelivery()
    private static var deliveryCompletion: ((Bool) -> Void)?
    private static var deliveryTimeout: DispatchWorkItem?

    @discardableResult
    static func command(_ key: CGKeyCode) -> Bool {
        guard let events = sequence([(key, .maskCommand)]) else { return false }
        post(events)
        return true
    }

    static func sequence(_ keys: [(CGKeyCode, CGEventFlags)]) -> [CGEvent]? {
        guard CGPreflightPostEventAccess(), let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = marker
        var events: [CGEvent] = []
        for (key, flags) in keys {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return nil }
            down.flags = flags
            // Leaving Command/Shift on key-up can leave Quartz's modifier/key
            // state sticky after our Copy or selection arrows. Release only
            // the synthetic shortcut state; hardware guards remain separate.
            up.flags = []
            for event in [down, up] {
                event.setIntegerValueField(.eventSourceUserData, value: marker)
                events.append(event)
            }
        }
        return events
    }

    static func post(_ events: [CGEvent]) {
        for event in events { event.post(tap: .cghidEventTap) }
    }

    /// The final key-up receipt paces our batches through the system queue.
    /// It does not prove Figma has handled them; actual Copy remains required.
    static func postAndAwaitDelivery(_ events: [CGEvent], completion: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let last = events.last, last.type == .keyUp, let token = delivery.begin() else {
            completion(false); return
        }
        deliveryCompletion = completion
        guard KeyboardEventDelivery.tagFinalPair(events, marker: token) else {
            _ = delivery.cancel()
            completeDelivery(false)
            return
        }
        let timeout = DispatchWorkItem {
            guard delivery.acknowledge(marker: token) else { return }
            completeDelivery(false)
        }
        deliveryTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + ConversionTiming.eventDeliveryDeadline, execute: timeout)
        post(events)
    }

    /// Called only from the listening tap; callbacks resume after it returns.
    static func received(_ event: CGEvent) -> Bool {
        let token = event.getIntegerValueField(.eventSourceUserData)
        guard KeyboardEventDelivery.isSynthetic(marker: token) else { return false }
        if event.type == .keyUp, delivery.acknowledge(marker: token) { completeDelivery(true) }
        return true
    }

    static func cancelDelivery() {
        if delivery.cancel() { completeDelivery(false) }
    }

    private static func completeDelivery(_ delivered: Bool) {
        deliveryTimeout?.cancel(); deliveryTimeout = nil
        let completion = deliveryCompletion
        deliveryCompletion = nil
        DispatchQueue.main.async { completion?(delivered) }
    }

    /// Text payloads are immutable before the first batch. Receipt paces the
    /// stream; it is never editor proof. A repeated Shift may release within
    /// the existing budget, while all other real input/focus cancels at once.
    static func postTextReplacement(_ batches: [[CGEvent]], valid: @escaping () -> Bool,
                                    modifiersClear: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        guard !batches.isEmpty else { completion(false); return }
        var index = 0
        var modifierReadiness: ModifierReleaseReadiness?
        func postNext() {
            guard valid() else { completion(false); return }
            let clear = modifiersClear()
            if modifierReadiness != nil || !clear {
                let now = ProcessInfo.processInfo.systemUptime
                let wait = modifierReadiness ?? ModifierReleaseReadiness(start: now, timeout: ConversionTiming.modifierReleaseDeadline,
                                                                        pollInterval: ConversionTiming.pollInterval)
                modifierReadiness = wait
                switch wait.decision(at: now, inputUnchanged: valid(), modifiersClear: clear) {
                case .ready: break
                case .wait(let delay):
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { postNext() }
                    return
                case .cancelled, .timedOut: completion(false); return
                }
            }
            modifierReadiness = nil
            postAndAwaitDelivery(batches[index]) { delivered in
                guard delivered, valid() else { completion(false); return }
                index += 1
                if index == batches.count { completion(true) }
                else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + ConversionTiming.textPairInterval) { postNext() }
                }
            }
        }
        postNext()
    }

    /// Canvas selection has no truthful external atomic setter. Memory and
    /// main-run-loop work are bounded per batch. A next batch is posted only
    /// after the last key-up of this batch reaches the listening session tap.
    static func restoreCanvasSelection(plan: CanvasSelectionPlan, valid: @escaping () -> Bool,
                                       modifiersClear: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        if case .entireDocument = plan {
            guard valid(), modifiersClear(), let events = sequence([(0, .maskCommand)]) else { completion(false); return }
            postAndAwaitDelivery(events) { completion($0 && valid()) }
            return
        }
        guard case .characters(let characterCount) = plan else { completion(false); return }
        var modifierReadiness: ModifierReleaseReadiness?
        func postBatch(_ remaining: Int) {
            guard valid() else { completion(false); return }
            let clear = modifiersClear()
            if modifierReadiness != nil || !clear {
                let now = ProcessInfo.processInfo.systemUptime
                let wait = modifierReadiness ?? ModifierReleaseReadiness(start: now, timeout: ConversionTiming.modifierReleaseDeadline,
                                                                        pollInterval: ConversionTiming.pollInterval)
                modifierReadiness = wait
                switch wait.decision(at: now, inputUnchanged: valid(), modifiersClear: clear) {
                case .ready: break
                case .wait(let delay):
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { postBatch(remaining) }
                    return
                case .cancelled, .timedOut: completion(false); return
                }
            }
            modifierReadiness = nil
            let count = min(remaining, 32)
            guard count > 0 else { completion(true); return }
            guard let events = sequence(Array(repeating: (CGKeyCode(123), CGEventFlags.maskShift), count: count)) else {
                completion(false); return
            }
            postAndAwaitDelivery(events) { delivered in
                guard delivered, valid() else { completion(false); return }
                if remaining == count { completion(true) }
                else { postBatch(remaining - count) }
            }
        }
        postBatch(characterCount)
    }
}
