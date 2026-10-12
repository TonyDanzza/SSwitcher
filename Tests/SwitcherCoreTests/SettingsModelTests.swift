import XCTest
@testable import SwitcherCore

final class WindowShortcutDirectionsTests: XCTestCase {
    private func display(_ id: UInt32, _ frame: CGRect) -> WindowDisplay {
        WindowDisplay(id: id, frame: frame, visibleFrame: frame.insetBy(dx: 0, dy: 10))
    }

    func testMonitorAboveMacBookUsesOnlyUpAndDown() {
        let lg = display(1, CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let macBook = display(2, CGRect(x: 579, y: 1440, width: 1470, height: 956))
        XCTAssertEqual(WindowShortcutDirections.available(in: [lg, macBook]), [.up, .down])
    }

    func testSideBySideDisplaysUseLeftAndRight() {
        let left = display(1, CGRect(x: 0, y: 0, width: 1470, height: 956))
        let right = display(2, CGRect(x: 1470, y: -200, width: 2560, height: 1440))
        XCTAssertEqual(WindowShortcutDirections.available(in: [left, right]), [.left, .right])
    }

    func testSingleAndMirroredDisplaysUseNoArrows() {
        let frame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        XCTAssertEqual(WindowShortcutDirections.available(in: [display(1, frame)]), [])
        XCTAssertEqual(WindowShortcutDirections.available(in: [display(1, frame), display(2, frame)]), [])
    }

    func testThreeDisplaysCombineDirections() {
        let center = display(1, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let above = display(2, CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        let right = display(3, CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(WindowShortcutDirections.available(in: [center, above, right]), Set(WindowMoveDirection.allCases))
    }

    func testManualChoiceIgnoresTopology() {
        let only = display(1, CGRect(x: 0, y: 0, width: 1470, height: 956))
        XCTAssertEqual(WindowShortcutDirections.resolve(.manual([.left]), displays: [only]), [.left])
        XCTAssertEqual(WindowShortcutDirections.resolve(.automatic, displays: [only]), [])
        XCTAssertEqual(WindowShortcutDirections.arrows([.down, .up, .left]), "←↑↓")
    }
}

final class KeyShortcutTests: XCTestCase {
    func testDefaultToggleIsValidAndRoundTrips() {
        let shortcut = KeyShortcut.functionKeyToggle
        XCTAssertNil(shortcut.problem)
        XCTAssertEqual(shortcut.modifiers.symbols, "⌃⌥⌘")
        XCTAssertEqual(KeyShortcut(storage: shortcut.storage), shortcut)
    }

    func testRejectsShortcutsWithoutCommandOptionOrControl() {
        XCTAssertEqual(KeyShortcut(keyCode: 3, modifiers: []).problem, .needsModifier)
        XCTAssertEqual(KeyShortcut(keyCode: 3, modifiers: .shift).problem, .needsModifier)
        XCTAssertNil(KeyShortcut(keyCode: 105, modifiers: []).problem, "F13 works alone")
        XCTAssertEqual(KeyShortcut(keyCode: 122, modifiers: []).problem, .needsModifier, "F1 needs a modifier")
    }

    func testRejectsReservedSystemShortcutsAndModifierKeys() {
        XCTAssertEqual(KeyShortcut(keyCode: 12, modifiers: .command).problem, .reserved)
        XCTAssertEqual(KeyShortcut(keyCode: 49, modifiers: .command).problem, .reserved)
        XCTAssertNil(KeyShortcut(keyCode: 12, modifiers: [.command, .option]).problem)
        XCTAssertEqual(KeyShortcut(keyCode: 56, modifiers: .command).problem, .modifierKey)
    }

    func testStorageRejectsInvalidValues() {
        XCTAssertNil(KeyShortcut(storage: nil))
        XCTAssertNil(KeyShortcut(storage: ["keyCode": 12, "modifiers": 0x0100]))
        XCTAssertNil(KeyShortcut(storage: ["keyCode": -1, "modifiers": 0x0800]))
        XCTAssertEqual(KeyShortcut(keyCode: 3, modifiers: .init(rawValue: 0x1800 | 0x4000)).modifiers, [.control, .option])
    }
}

final class DoubleShiftKeyChoiceTests: XCTestCase {
    private func tap(_ detector: inout DoubleShiftDetector, key: UInt16, at time: Double) -> Bool {
        _ = detector.shiftChanged(key: key, anyShiftDown: true, otherModifierDown: false, time: time)
        return detector.shiftChanged(key: key, anyShiftDown: false, otherModifierDown: false, time: time + 0.05)
    }

    func testOnlyLeftShiftIgnoresRightShiftPairs() {
        var detector = DoubleShiftDetector()
        detector.keys = [56]
        XCTAssertFalse(tap(&detector, key: 60, at: 0))
        XCTAssertFalse(tap(&detector, key: 60, at: 0.15))
        XCTAssertFalse(tap(&detector, key: 56, at: 1))
        XCTAssertTrue(tap(&detector, key: 56, at: 1.15))
    }

    func testLongerIntervalAcceptsSlowerPair() {
        var detector = DoubleShiftDetector()
        XCTAssertFalse(tap(&detector, key: 56, at: 0))
        XCTAssertFalse(tap(&detector, key: 56, at: 0.4))
        detector.reset()
        detector.interval = 0.5
        XCTAssertFalse(tap(&detector, key: 56, at: 1))
        XCTAssertTrue(tap(&detector, key: 56, at: 1.4))
    }
}
