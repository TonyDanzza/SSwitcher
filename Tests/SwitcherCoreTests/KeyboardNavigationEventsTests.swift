import XCTest
import AppKit
import CoreGraphics
@testable import SwitcherCore

final class KeyboardNavigationEventsTests: XCTestCase {
    func testArrowEnvelopeAndReceiptNeverAcquireUnicodeTextPayload() throws {
        for (key, character) in [(CGKeyCode(123), "\u{f702}"), (124, "\u{f703}"), (125, "\u{f701}"), (126, "\u{f700}")] {
            let events = try XCTUnwrap(KeyboardNavigationEvents.make([(key, .maskShift)], sourceMarker: 7))
            for tagged in [false, true] {
                if tagged { XCTAssertTrue(KeyboardEventDelivery.tagFinalPair(events, marker: 42)) }
                for event in events {
                    var unit: UniChar = 0
                    var count = 0
                    event.keyboardGetUnicodeString(maxStringLength: 1, actualStringLength: &count, unicodeString: &unit)
                    XCTAssertEqual(count, 0, "Navigation must not carry ASCII control text")
                    let native = try XCTUnwrap(NSEvent(cgEvent: event))
                    XCTAssertEqual(native.characters, character)
                    XCTAssertEqual(native.charactersIgnoringModifiers, character)
                    XCTAssertEqual(native.keyCode, key)
                    XCTAssertEqual(native.windowNumber, 0)
                    XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeyboardType),
                                   Int64(try XCTUnwrap(CGEventSource(event: event)).keyboardType))
                }
                XCTAssertEqual(events[0].flags, .maskShift)
                XCTAssertTrue(events[1].flags.isEmpty)
            }
        }
    }

    func testServiceFunctionKeysCarryTheirNativeCharacterAndNeutralRelease() throws {
        for (key, expected) in [(CGKeyCode(80), UniChar(0xf716)), (CGKeyCode(90), UniChar(0xf717))] {
            let events = try XCTUnwrap(KeyboardNavigationEvents.make([(key, .maskCommand)], sourceMarker: 7))
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(events[0].flags, .maskCommand)
            XCTAssertEqual(events[1].flags, [])
            for event in events {
                var character: UniChar = 0
                var count = 0
                event.keyboardGetUnicodeString(maxStringLength: 1, actualStringLength: &count, unicodeString: &character)
                XCTAssertEqual(count, 1)
                XCTAssertEqual(character, expected)
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(key))
            }
            XCTAssertFalse(events.contains { $0.type == .flagsChanged })
        }
    }
    func testNavigationDefaultsToIsolatedStateAndReceiptRetainsIt() throws {
        let events = try XCTUnwrap(KeyboardNavigationEvents.make([(123, .maskShift)], sourceMarker: 7))
        for event in events {
            let source = try XCTUnwrap(CGEventSource(event: event))
            XCTAssertNotEqual(source.sourceStateID, .hidSystemState)
            XCTAssertNotEqual(source.sourceStateID, .combinedSessionState)
        }
        XCTAssertTrue(KeyboardEventDelivery.tagFinalPair(events, marker: 42))
        let terminal = try XCTUnwrap(events.last)
        XCTAssertNotEqual(try XCTUnwrap(CGEventSource(event: terminal)).sourceStateID, .hidSystemState)
    }
    func testWordSelectionUsesOnlyArrowPairsWithModifierFlags() throws {
        let flags: CGEventFlags = [.maskAlternate, .maskShift]
        let events = try XCTUnwrap(KeyboardNavigationEvents.make([(123, flags)], sourceMarker: 7))
        let keys = events.filter { $0.type == .keyDown || $0.type == .keyUp }
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys.first?.flags, flags)
        XCTAssertEqual(keys.last?.flags, [])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.type, .keyDown)
        XCTAssertEqual(events.last?.type, .keyUp)
        XCTAssertFalse(events.contains { $0.type == .flagsChanged })
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == 7 })
    }

    func testBareArrowCannotInheritPreviousSelectionModifiers() throws {
        let events = try XCTUnwrap(KeyboardNavigationEvents.make([(123, [.maskAlternate, .maskShift]), (124, [])], sourceMarker: 7))
        let bareIndex = try XCTUnwrap(events.firstIndex { $0.type == .keyDown && $0.getIntegerValueField(.keyboardEventKeycode) == 124 })
        XCTAssertEqual(events[bareIndex - 1].type, .keyUp)
        XCTAssertEqual(events[bareIndex].flags, [])
        XCTAssertEqual(events.last?.type, .keyUp)
    }

    func testRepeatedSelectionArrowsNeverPressModifierKeys() throws {
        let events = try XCTUnwrap(KeyboardNavigationEvents.make(Array(repeating: (123, .maskShift), count: 6), sourceMarker: 7))
        XCTAssertFalse(events.contains { $0.type == .flagsChanged })
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 123 })
        XCTAssertEqual(events.filter { $0.type == .keyDown }.count, 6)
        XCTAssertTrue(events.filter { $0.type == .keyUp }.allSatisfy { $0.flags.isEmpty })
        let terminal = try XCTUnwrap(events.last)
        XCTAssertTrue(KeyboardEventDelivery.tagFinalPair(events, marker: 42))
        XCTAssertEqual(terminal.flags, [])
        XCTAssertEqual(terminal.getIntegerValueField(.eventSourceUserData), 42)
        XCTAssertEqual(try XCTUnwrap(CGEventSource(event: terminal)).userData, 42)
    }

    func testSyntheticSourcesAndReceiptsExplicitlyPermitHardwareInput() throws {
        let source = try XCTUnwrap(SyntheticKeyboardSource.make())
        let all: CGEventFilterMask = [.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents]
        XCTAssertEqual(source.localEventsSuppressionInterval, 0)
        for state in [CGEventSuppressionState.eventSuppressionStateSuppressionInterval, .eventSuppressionStateRemoteMouseDrag] {
            XCTAssertEqual(source.getLocalEventsFilterDuringSuppressionState(state), all)
        }
        let events = try XCTUnwrap(KeyboardNavigationEvents.make([(123, [.maskAlternate, .maskShift])], sourceMarker: 7))
        XCTAssertTrue(KeyboardEventDelivery.tagFinalPair(events, marker: 42))
        for event in events {
            let eventSource = try XCTUnwrap(CGEventSource(event: event))
            XCTAssertEqual(eventSource.localEventsSuppressionInterval, 0)
            XCTAssertEqual(eventSource.getLocalEventsFilterDuringSuppressionState(.eventSuppressionStateSuppressionInterval), all)
        }
    }

    func testNavigationCannotEmitTextOrUnsupportedModifierAndIsBounded() {
        XCTAssertNil(KeyboardNavigationEvents.make([], sourceMarker: 7))
        XCTAssertNil(KeyboardNavigationEvents.make([(0, [])], sourceMarker: 7))
        XCTAssertNil(KeyboardNavigationEvents.make([(123, .maskSecondaryFn)], sourceMarker: 7))
        XCTAssertNil(KeyboardNavigationEvents.make(Array(repeating: (123, []), count: 258), sourceMarker: 7))
    }
}
