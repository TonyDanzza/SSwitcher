import AppKit
import CoreGraphics
import XCTest
@testable import SwitcherCore

final class UnicodeTextInputTests: XCTestCase {
    func testChunksPreserveGraphemesAndExactMultilineText() throws {
        let text = String(repeating: "аб🙂é\n", count: 60) + "\u{2028}конец"
        let input = try XCTUnwrap(UnicodeTextInput(text: text, controlPolicy: .literalLines))
        XCTAssertEqual(input.chunks.joined(), text)
        XCTAssertTrue(input.chunks.allSatisfy { !$0.isEmpty && $0.utf16.count <= 20 })
        XCTAssertEqual(input.chunks.flatMap(Array.init), Array(text))
    }

    func testBoundaryMovesWholeEmojiAndCombiningCharacterToNextEvent() throws {
        let input = try XCTUnwrap(UnicodeTextInput(text: String(repeating: "a", count: 19) + "🙂é"))
        XCTAssertEqual(input.chunks, [String(repeating: "a", count: 19), "🙂é"])
    }

    func testRejectsUnsupportedGraphemeBeforeCreatingAnyEvents() {
        let oversizedGrapheme = "e" + String(repeating: "\u{301}", count: 20)
        XCTAssertEqual(oversizedGrapheme.count, 1)
        XCTAssertNil(UnicodeTextInput(text: "supported prefix" + oversizedGrapheme))
        XCTAssertNil(UnicodeTextInput(text: ""))
        XCTAssertNil(UnicodeTextInput(text: "text", maximumUTF16UnitsPerEvent: 0))
    }

    func testReplacementIsEncodedInEveryEventWithoutCommandV() throws {
        let text = String(repeating: "привет🙂é\n", count: 30)
        let input = try XCTUnwrap(UnicodeTextInput(text: text, controlPolicy: .literalLines))
        let events = try XCTUnwrap(input.makeEvents())
        XCTAssertEqual(events.count, input.chunks.count * 2)
        for (index, chunk) in input.chunks.enumerated() {
            let pair = Array(events[(index * 2)..<(index * 2 + 2)])
            XCTAssertEqual(pair.map(\.type), [.keyDown, .keyUp])
            for event in pair {
                XCTAssertEqual(event.flags, [])
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 0)
                XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), KeyboardEventDelivery.sourceMarker)
                XCTAssertEqual(try unicodeText(in: event), chunk)
            }
        }
    }

    func testImmutableEventsIgnoreClipboardChangesAndKeepNewUserCopy() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("OLD clipboard", forType: .string)
        let originalRevision = pasteboard.changeCount
        let input = try XCTUnwrap(UnicodeTextInput(text: "привет"))
        let delayedEvents = try XCTUnwrap(input.makeEvents())
        XCTAssertEqual(pasteboard.changeCount, originalRevision)
        XCTAssertEqual(pasteboard.string(forType: .string), "OLD clipboard")

        // Another app may publish a new Copy before the target consumes an
        // event. The immutable payload is independent of that shared state.
        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)
        let newRevision = pasteboard.changeCount
        let serialized = try XCTUnwrap(CGEvent(withDataAllocator: nil, data: try XCTUnwrap(delayedEvents[0].data)))
        XCTAssertEqual(try unicodeText(in: serialized), "привет")
        XCTAssertEqual(try unicodeText(in: delayedEvents[0]), "привет")
        XCTAssertEqual(pasteboard.changeCount, newRevision)
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testControlsAreScopedToProvenCanvasAndOwnTextView() {
        typealias Policy = UnicodeTextInput.ControlPolicy
        XCTAssertEqual(Policy.forEditor(isCurrentProcess: false, isFigma: true, role: "AXTextArea", description: "Text"), .figmaText)
        for (isFigma, role, description) in [(true, "AXTextArea", "Comment"), (true, "AXTextField", "Text"),
                                            (false, "AXTextArea", "Text")] {
            XCTAssertEqual(Policy.forEditor(isCurrentProcess: false, isFigma: isFigma, role: role, description: description), .singleLine)
        }
        XCTAssertEqual(Policy.forEditor(isCurrentProcess: false, isFigma: true, role: nil, description: nil), .singleLine)
        XCTAssertEqual(Policy.forEditor(isCurrentProcess: true, isFigma: false, role: "AXTextArea", description: nil), .literalLines)
        XCTAssertNil(UnicodeTextInput(text: "first\nsecond"))
        XCTAssertNil(UnicodeTextInput(text: "first\u{2028}second"))
    }

    func testUnprovenControlCharactersRejectBeforeWordDeletion() {
        for policy: UnicodeTextInput.ControlPolicy in [.singleLine, .figmaText, .literalLines] {
            for control in ["\t", "\r", "\r\n", "\0", "\u{7F}", "\u{85}", "\u{2029}"] {
                XCTAssertNil(UnicodeTextInput(text: "prefix" + control + "suffix", controlPolicy: policy))
            }
        }
    }

    func testFigmaLineFeedAndLineSeparatorHaveDifferentKeyboardActions() throws {
        let input = try XCTUnwrap(UnicodeTextInput(text: "first\nsecond\u{2028}", controlPolicy: .figmaText))
        XCTAssertEqual(input.actions, [.text("first"), .lineFeed, .text("second"), .lineSeparator])
        let events = try XCTUnwrap(input.makeEvents())
        XCTAssertEqual(events[2].getIntegerValueField(.keyboardEventKeycode), 36)
        XCTAssertEqual(events[2].flags, [])
        XCTAssertEqual(events[6].getIntegerValueField(.keyboardEventKeycode), 36)
        XCTAssertEqual(events[6].flags, .maskShift)
        for index in stride(from: 1, to: events.count, by: 2) { XCTAssertEqual(events[index].flags, []) }
        for event in events {
            XCTAssertEqual(try XCTUnwrap(CGEventSource(event: event)).userData, KeyboardEventDelivery.sourceMarker)
            XCTAssertFalse(event.getIntegerValueField(.keyboardEventKeycode) == 9 && event.flags.contains(.maskCommand))
        }
    }

    func testWordDeletionAndFirstTextAreOnePrebuiltBatchWithNoPaste() throws {
        let text = String(repeating: "ж", count: 41)
        let input = try XCTUnwrap(UnicodeTextInput(text: text))
        let batches = try XCTUnwrap(input.makeEventBatches(deletingCharacters: 6))
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches[0].count, 14)
        XCTAssertEqual(batches[1].count, 2)
        XCTAssertEqual(batches[2].count, 2)
        for event in batches[0].prefix(12) {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 51)
        }
        XCTAssertEqual(try unicodeText(in: batches[0][12]), String(repeating: "ж", count: 20))
        XCTAssertEqual(try unicodeText(in: batches[1][0]), String(repeating: "ж", count: 20))
        XCTAssertEqual(try unicodeText(in: batches[2][0]), "ж")
        for event in batches.flatMap({ $0 }) {
            XCTAssertEqual(try XCTUnwrap(CGEventSource(event: event)).userData, KeyboardEventDelivery.sourceMarker)
            XCTAssertFalse(event.getIntegerValueField(.keyboardEventKeycode) == 9 && event.flags.contains(.maskCommand))
        }
        XCTAssertNil(input.makeEventBatches(deletingCharacters: -1))
    }

    func testFinalReceiptSourceAndFlatteningPreserveUnicodePayload() throws {
        let input = try XCTUnwrap(UnicodeTextInput(text: "🙂éпривет"))
        let events = try XCTUnwrap(input.makeEvents())
        var delivery = KeyboardEventDelivery()
        let marker = try XCTUnwrap(delivery.begin())
        XCTAssertTrue(KeyboardEventDelivery.tagFinalPair(events, marker: marker))
        for event in events.suffix(2) {
            XCTAssertEqual(try unicodeText(in: event), "🙂éпривет")
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), marker)
            let flattened = try XCTUnwrap(CGEvent(withDataAllocator: nil, data: try XCTUnwrap(event.data)))
            XCTAssertEqual(try unicodeText(in: flattened), "🙂éпривет")
        }
    }

    private func unicodeText(in event: CGEvent) throws -> String {
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &count, unicodeString: nil)
        var units = [UniChar](repeating: 0, count: count)
        units.withUnsafeMutableBufferPointer {
            event.keyboardGetUnicodeString(maxStringLength: $0.count, actualStringLength: &count, unicodeString: $0.baseAddress)
        }
        XCTAssertEqual(units.count, count)
        return String(decoding: units, as: UTF16.self)
    }
}
