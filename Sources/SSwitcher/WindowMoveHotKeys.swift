import AppKit
import Carbon
import SwitcherCore

/// Carbon owns only the registered arrow shortcuts: the directions chosen in
/// Settings (by default those with a neighboring display) with the chosen
/// modifiers. The conversion listener stays listen-only; disabling this
/// feature removes every registration.
final class WindowMoveHotKeys {
    var onMove: ((WindowMoveDirection) -> Void)?
    private let keys = CarbonHotKeySet(signature: 0x5353574D) // SSWM
    private(set) var lastError: OSStatus?
    private(set) var directions: Set<WindowMoveDirection> = []
    private(set) var modifiers: KeyShortcut.Modifiers = [.option, .shift]
    var isRegistered: Bool { keys.isRegistered }

    init() {
        keys.onPress = { [weak self] id in
            if let direction = WindowMoveDirection(rawValue: id) { self?.onMove?(direction) }
        }
    }

    @discardableResult
    func start(directions: Set<WindowMoveDirection>, modifiers: KeyShortcut.Modifiers) -> Bool {
        if isRegistered && directions == self.directions && modifiers == self.modifiers { return true }
        self.directions = directions
        self.modifiers = modifiers
        let ordered = WindowMoveDirection.allCases.filter(directions.contains)
        let result = keys.register(ordered.map { ($0.rawValue, $0.keyCode, modifiers.rawValue) })
        lastError = result == noErr ? nil : result
        return result == noErr && !directions.isEmpty
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        keys.stop()
        lastError = nil
    }
}
