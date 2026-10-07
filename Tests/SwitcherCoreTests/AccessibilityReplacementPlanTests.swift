import Foundation
import XCTest
@testable import SwitcherCore

final class AccessibilityReplacementPlanTests: XCTestCase {
    private func replacement(_ document: String, range: NSRange, text: String) throws -> AccessibilityReplacementPlan {
        let selection = try XCTUnwrap(AccessibilitySelectionPlan(document: document, range: range, selectedText: nil))
        return try XCTUnwrap(selection.replacing(with: text))
    }

    func testFullReplacementLeavesAnEmptyEndCaretReadyForTypingAndNextWordGesture() throws {
        let result = try replacement("ghbdtn vbh", range: NSRange(location: 0, length: 10), text: "привет мир")
        XCTAssertEqual(result.document, "привет мир")
        XCTAssertEqual(result.caret, NSRange(location: 10, length: 0))
        XCTAssertTrue(result.confirmsCaret(document: result.document, range: result.caret, selectedText: "", selectedRanges: [result.caret]))
        let continued = (result.document as NSString).replacingCharacters(in: result.caret, with: "!")
        XCTAssertEqual(continued, "привет мир!")
        let nextWord = try XCTUnwrap(WordCursorPlan(value: result.document, caret: result.caret.location))
        XCTAssertEqual(nextWord.text, "мир")
        XCTAssertEqual(nextWord.deletingCharacters, 3)
    }

    func testPartialReplacementKeepsRepeatedNeighborsAndCaretAtFragmentEnd() throws {
        let result = try replacement("ghbdtn ghbdtn ghbdtn", range: NSRange(location: 7, length: 6), text: "привет")
        XCTAssertEqual(result.document, "ghbdtn привет ghbdtn")
        XCTAssertEqual(result.caret, NSRange(location: 13, length: 0))
        XCTAssertTrue(result.confirmsCaret(document: result.document, range: result.caret, selectedText: nil))
        XCTAssertEqual((result.document as NSString).replacingCharacters(in: result.caret, with: "!"), "ghbdtn привет! ghbdtn")
        XCTAssertFalse(result.confirmsCaret(document: result.document, range: NSRange(location: result.document.utf16.count, length: 0), selectedText: ""))
        XCTAssertFalse(result.confirmsCaret(document: "ghbdtn привет CHANGED", range: result.caret, selectedText: ""))
    }

    func testMultilineEmojiAndDecomposedUnicodeUseExactUTF16EmptyEndCaret() throws {
        let original = "🙂 ghbdtn\nvbh e\u{301}\u{2028}ntcn 👨‍👩‍👧‍👦"
        let converted = "🙂 привет\nмир e\u{301}\u{2028}тест 👨‍👩‍👧‍👦"
        for prefix in ["", "untouched 🙂 "] {
            let suffix = prefix.isEmpty ? "" : " suffix e\u{301}"
            let result = try replacement(prefix + original + suffix,
                range: NSRange(location: prefix.utf16.count, length: original.utf16.count), text: converted)
            XCTAssertTrue(AccessibilitySelectionPlan.exactlyEqual(result.document, prefix + converted + suffix))
            XCTAssertEqual(result.caret, NSRange(location: prefix.utf16.count + converted.utf16.count, length: 0))
            XCTAssertTrue(result.confirmsCaret(document: result.document, range: result.caret, selectedText: "", selectedRanges: [result.caret]))
            let normalized = result.document.precomposedStringWithCanonicalMapping
            XCTAssertEqual(result.document, normalized) // Swift canonical equality is insufficient for AX offsets.
            XCTAssertFalse(result.confirmsCaret(document: normalized, range: result.caret, selectedText: ""))
        }
    }

    func testRetainedHighlightOrContradictingCaretEvidenceCannotConfirm() throws {
        let result = try replacement("prefix ghbdtn suffix", range: NSRange(location: 7, length: 6), text: "привет")
        XCTAssertFalse(result.confirmsCaret(document: result.document, range: result.range, selectedText: result.text, selectedRanges: [result.range]))
        XCTAssertFalse(result.confirmsCaret(document: result.document, range: result.caret, selectedText: result.text))
        XCTAssertFalse(result.confirmsCaret(document: result.document, range: result.caret, selectedText: "", selectedRanges: [result.range]))
        XCTAssertFalse(result.confirmsCaret(document: result.document, range: result.caret, selectedText: "", selectedRanges: [result.caret, NSRange(location: 0, length: 0)]))
        XCTAssertFalse(result.confirmsCaret(document: "prefix ghbdtn suffix", range: result.caret, selectedText: ""))
        XCTAssertFalse(result.confirmsCaret(document: result.document, range: NSRange(location: 7, length: 0), selectedText: ""))
    }

    func testCaretOffsetsInsideAnEmojiOrCombiningSequenceCannotConfirm() throws {
        let result = try replacement("x", range: NSRange(location: 0, length: 1), text: "🙂 e\u{301}")
        XCTAssertEqual(result.caret, NSRange(location: 5, length: 0))
        XCTAssertTrue(result.confirmsCaret(document: result.document, range: result.caret, selectedText: ""))
        for offset in [1, 3, 4, 6] {
            XCTAssertFalse(result.confirmsCaret(document: result.document, range: NSRange(location: offset, length: 0), selectedText: ""))
        }
    }
}
