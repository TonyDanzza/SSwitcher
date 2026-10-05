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

    func paste(_ text: String) -> Bool {
        guard transaction.write(text) else { return false }
        guard KeyboardEvents.command(9) else { restore(); return false }
        return true
    }

    func restore() {
        transaction.restore()
    }

    deinit { restore() }
}
