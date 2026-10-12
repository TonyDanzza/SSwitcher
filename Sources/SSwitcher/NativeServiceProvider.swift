import AppKit
import Carbon
import SwitcherCore

/// AppKit Services provider for MAX. Cmd+F19 (`checkNativeSelection`) carries
/// the selected packet; Cmd+F20 (`checkNativeEditable`) is the return-only
/// barrier. Only the current MAX gesture may publish a response.
final class NativeServiceProvider: NSObject {
    private let selectionProof = NativeSelectionServiceProof()
    var conversionStatus: String { selectionProof.status }
    var isConverting: Bool { selectionProof.isConverting }
    var lastDirectConversion: String? { selectionProof.lastDirectConversion }

    func convertAtCursor(valid: @escaping () -> Bool, knownNoSelection: Bool = false,
                         completion: @escaping (NativeServiceDispatchState.Outcome, TISInputSource?) -> Void) {
        selectionProof.convertAtCursor(valid: valid, knownNoSelection: knownNoSelection, completion: completion)
    }

    func cancelConversion() {
        selectionProof.cancelAutomatic()
        selectionProof.cancelVisualShield()
    }
    func cancelVisualShield() { selectionProof.cancelVisualShield() }
    func prepareEarlyShield(valid: @escaping () -> Bool) { selectionProof.prepareEarlyShield(valid: valid) }
    func cancel() {
        guard Thread.isMainThread else { return }
        selectionProof.cancel()
    }

    @objc(checkNativeSelection:userData:error:)
    func checkNativeSelection(_ pasteboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let error else { return }
        error.pointee = "SSwitcher: проверка завершена, текст не изменён" as NSString
        // The gesture-owned commit consumes this exact native packet once.
        // It owns response cleanup itself.
        if selectionProof.convertWordPacketIfRequested(pasteboard, error: error) { return }
        // A two-way declaration keeps MAX active. Never leave the sent text
        // as a return value: Qt could insert it again and collapse selection.
        // Clear formats, not an empty string (which would delete selection).
        _ = NativeServicePacket.discardReturnValue(pasteboard)
    }

    @objc(checkNativeEditable:userData:error:)
    func checkNativeEditable(_ pasteboard: NSPasteboard, userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        selectionProof.receiveBarrier(pasteboard, error: error)
    }
}
