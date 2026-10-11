import CoreGraphics
import Foundation
import SwitcherCore

enum KeyboardEvents {
    private static var delivery = KeyboardEventDelivery()
    private static var deliveryCompletion: ((Bool) -> Void)?
    private static var deliveryTimeout: DispatchWorkItem?
    private static var targetTap: CFMachPort?
    private static var targetSource: CFRunLoopSource?

    /// The final key-up receipt paces our batches through the system queue.
    /// It does not prove editor handling; fresh AX evidence is still required.
    static func postAndAwaitDelivery(_ events: [CGEvent], targetPID: pid_t? = nil, directToTarget: Bool = true,
                                    postingTap: CGEventTapLocation = .cghidEventTap,
                                    completion: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let last = events.last, last.type == .keyUp, last.flags.isEmpty,
              events.allSatisfy({ $0.type == .keyDown || $0.type == .keyUp }),
              let token = delivery.begin() else {
            completion(false); return
        }
        deliveryCompletion = completion
        guard KeyboardEventDelivery.tagFinalPair(events, marker: token) else {
            _ = delivery.cancel()
            completeDelivery(false)
            return
        }
        if let targetPID {
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            guard let tap = CGEvent.tapCreateForPid(pid: targetPID, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: { _, type, event, _ in
                    if type == .keyDown || type == .keyUp { _ = KeyboardEvents.received(event, fromTarget: true) }
                    return Unmanaged.passUnretained(event)
                }, userInfo: nil), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
                _ = delivery.cancel(); completeDelivery(false); return
            }
            targetTap = tap; targetSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        let timeout = DispatchWorkItem {
            guard delivery.acknowledge(marker: token) else { return }
            completeDelivery(false)
        }
        deliveryTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + ConversionTiming.eventDeliveryDeadline, execute: timeout)
        func post(_ event: CGEvent) {
            event.timestamp = DispatchTime.now().uptimeNanoseconds
            // One batch uses one posting route. Splitting navigation and its
            // dependent service key across routes can reorder their arrival.
            if let targetPID, directToTarget { event.postToPid(targetPID) }
            else { event.post(tap: postingTap) }
        }
        for event in events { post(event) }
    }

    /// Called only from the listening tap; callbacks resume after it returns.
    static func received(_ event: CGEvent, fromTarget: Bool = false) -> Bool {
        let token = event.getIntegerValueField(.eventSourceUserData)
        guard KeyboardEventDelivery.isSynthetic(marker: token) else { return false }
        if event.type == .keyUp, (targetTap == nil || fromTarget),
           delivery.acknowledge(marker: token) { completeDelivery(true) }
        return true
    }

    static func cancelDelivery() {
        if delivery.cancel() { completeDelivery(false) }
    }

    private static func completeDelivery(_ delivered: Bool) {
        if let targetSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), targetSource, .commonModes) }
        if let targetTap { CGEvent.tapEnable(tap: targetTap, enable: false); CFMachPortInvalidate(targetTap) }
        targetSource = nil; targetTap = nil
        deliveryTimeout?.cancel(); deliveryTimeout = nil
        let completion = deliveryCompletion
        deliveryCompletion = nil
        DispatchQueue.main.async { completion?(delivered) }
    }

    /// Text payloads are immutable before the first batch. Receipt paces the
    /// stream; it is never editor proof. A repeated Shift may release within
    /// the existing budget, while all other real input/focus cancels at once.
    /// With `targetPID`, each batch waits for the target's own receipt and is
    /// posted through the session, the route MAX accepted for typed text.
    static func postTextReplacement(_ batches: [[CGEvent]], targetPID: pid_t? = nil,
                                    interval: Double = ConversionTiming.textPairInterval,
                                    valid: @escaping () -> Bool,
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
            postAndAwaitDelivery(batches[index], targetPID: targetPID, directToTarget: false,
                                 postingTap: targetPID == nil ? .cghidEventTap : .cgSessionEventTap) { delivered in
                guard delivered, valid() else { completion(false); return }
                index += 1
                if index == batches.count { completion(true) }
                else if interval <= 0 { postNext() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + interval) { postNext() } }
            }
        }
        postNext()
    }

}
