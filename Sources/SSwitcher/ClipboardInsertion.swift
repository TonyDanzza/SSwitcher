import AppKit
import SwitcherCore

/// A normal Paste command works in editors that ignore Unicode key events.
/// Keep clipboard data only in memory and restore it unless another copy occurs.
final class ClipboardInsertion {
    private let transaction: PasteboardTransaction

    init?() {
        guard let transaction = PasteboardTransaction() else { return nil }
        self.transaction = transaction
    }

    func paste(_ text: String, deletingBeforeCaret count: Int = 0) -> Bool {
        // Prepare the complete sequence and clipboard before deleting anything.
        var keys = Array(repeating: (CGKeyCode(51), CGEventFlags()), count: count)
        keys.append((9, .maskCommand))
        guard let events = KeyboardEvents.sequence(keys) else { return false }
        guard transaction.write(text) else { return false }
        KeyboardEvents.post(events)
        return true
    }

    func restore() {
        transaction.restore()
    }

    deinit { restore() }
}
