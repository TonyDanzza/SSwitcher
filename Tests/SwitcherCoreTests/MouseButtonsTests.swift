import XCTest
@testable import SwitcherCore

final class MouseButtonsTests: XCTestCase {
    func testLeftAndRightButtonsAreNeverTaken() {
        XCTAssertNil(MouseButtonBinding(button: 0, action: .back))
        XCTAssertNil(MouseButtonBinding(button: 1, action: .back))
        XCTAssertNotNil(MouseButtonBinding(button: 2, action: .missionControl))
        XCTAssertNil(MouseButtonBinding(button: 32, action: .back))
    }

    func testMatchesTheButtonWithExactlyItsModifiers() throws {
        let plain = try XCTUnwrap(MouseButtonBinding(button: 3, action: .back))
        XCTAssertTrue(plain.matches(button: 3, modifiers: []))
        XCTAssertFalse(plain.matches(button: 3, modifiers: .command))
        XCTAssertFalse(plain.matches(button: 4, modifiers: []))
        let held = try XCTUnwrap(MouseButtonBinding(button: 3, modifiers: [.command], action: .spaceLeft))
        XCTAssertTrue(held.matches(button: 3, modifiers: .command))
        XCTAssertFalse(held.matches(button: 3, modifiers: [.command, .shift]))
    }

    func testStorageRoundTripKeepsTheRecordedShortcut() throws {
        let closeTab = KeyShortcut(keyCode: 13, modifiers: .command) // ⌘W, refused as a global shortcut
        let bindings = [
            try XCTUnwrap(MouseButtonBinding(button: 3, action: .back)),
            try XCTUnwrap(MouseButtonBinding(button: 2, modifiers: [.option], action: .shortcut(closeTab))),
            try XCTUnwrap(MouseButtonBinding(button: 5, action: .shortcut(nil)))
        ]
        XCTAssertEqual(MouseButtonBinding.list(from: bindings.map(\.storage)), bindings)
    }

    func testListDropsUnreadableAndRepeatedEntries() {
        let list = MouseButtonBinding.list(from: [
            ["button": 3, "modifiers": 0, "action": "back"],
            ["button": 3, "modifiers": 0, "action": "forward"],
            ["button": 0, "modifiers": 0, "action": "back"],
            ["button": 4, "modifiers": 0, "action": "launchRockets"],
            ["button": 4, "modifiers": 0, "action": "forward"]
        ])
        XCTAssertEqual(list.map(\.button), [3, 4])
        XCTAssertEqual(list.map(\.action), [.back, .forward])
    }

    func testBackAndForwardAreBracketShortcuts() {
        XCTAssertEqual(MouseAction.back.keys, KeyShortcut(keyCode: 33, modifiers: .command))
        XCTAssertEqual(MouseAction.forward.keys, KeyShortcut(keyCode: 30, modifiers: .command))
        XCTAssertNil(MouseAction.missionControl.keys)
        XCTAssertNil(MouseAction.shortcut(nil).keys)
    }

    func testEveryKindRoundTrips() {
        for kind in MouseAction.Kind.allCases { XCTAssertEqual(MouseAction(kind: kind).kind, kind) }
    }

    func testTitlesAndSuggestions() throws {
        XCTAssertEqual(try XCTUnwrap(MouseButtonBinding(button: 2, action: .back)).title, "Средняя кнопка")
        XCTAssertEqual(try XCTUnwrap(MouseButtonBinding(button: 3, modifiers: [.command], action: .back)).title, "⌘ + кнопка «Назад»")
        XCTAssertEqual(try XCTUnwrap(MouseButtonBinding(button: 6, action: .back)).title, "Кнопка 7")
        XCTAssertEqual(MouseButtonBinding.suggestedAction(for: 3), .back)
        XCTAssertEqual(MouseButtonBinding.suggestedAction(for: 4), .forward)
        XCTAssertEqual(MouseButtonBinding.suggestedAction(for: 2), .missionControl)
    }

    func testOnlyALineBasedWheelIsReversed() {
        XCTAssertTrue(ScrollWheelReversal.applies(enabled: true, isContinuous: false))
        XCTAssertFalse(ScrollWheelReversal.applies(enabled: true, isContinuous: true))
        XCTAssertFalse(ScrollWheelReversal.applies(enabled: false, isContinuous: false))
    }
}
