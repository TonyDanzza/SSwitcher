import Foundation
import XCTest
@testable import SwitcherCore

final class NativeTextReplacementPlanTests: XCTestCase {
    private func snapshot(_ text: String, _ range: NSRange, marked: NSRange = NSRange(location: NSNotFound, length: 0)) throws -> NativeTextSnapshot {
        try XCTUnwrap(NativeTextSnapshot(document: text, length: text.utf16.count,
            actualRange: NSRange(location: 0, length: text.utf16.count), selection: range, marked: marked))
    }

    func testPartialSelectionPreservesRepeatedPrefixSuffixAndCollapsesCaret() throws {
        let original = "ghbdtn ghbdtn ghbdtn"
        let plan = try XCTUnwrap(NativeTextReplacementPlan(snapshot: snapshot(original, NSRange(location: 7, length: 6))))
        let result = try XCTUnwrap(plan.replacing(with: "привет"))
        XCTAssertEqual(result.document, "ghbdtn привет ghbdtn")
        XCTAssertEqual(result.caret, NSRange(location: 13, length: 0))
        XCTAssertTrue(plan.confirms(result, snapshot: try snapshot(result.document, result.caret)))
        XCTAssertFalse(plan.confirms(result, snapshot: try snapshot(result.document, result.range)))
        XCTAssertFalse(plan.confirms(result, snapshot: try snapshot("ghbdtn привет changed", result.caret)))
        XCTAssertFalse(plan.matches(try snapshot(original, NSRange(location: 0, length: 6))))
        XCTAssertFalse(plan.matches(try snapshot("CHANGE ghbdtn ghbdtn", NSRange(location: 7, length: 6))))
    }

    func testWholeSelectionNextGestureReadsActualLastWord() throws {
        let original = "ghbdtn vbh"
        let first = try XCTUnwrap(NativeTextReplacementPlan(snapshot: snapshot(original, NSRange(location: 0, length: original.utf16.count))))
        let converted = try XCTUnwrap(first.replacing(with: "привет мир"))
        let next = try XCTUnwrap(NativeTextReplacementPlan(snapshot: snapshot(converted.document, converted.caret)))
        XCTAssertFalse(next.isSelection)
        XCTAssertEqual(next.scope.text, "мир")
        XCTAssertEqual(next.scope.range, NSRange(location: 7, length: 3))
        let reverse = try XCTUnwrap(next.replacing(with: "vbh"))
        XCTAssertEqual(reverse.document, "привет vbh")
        XCTAssertTrue(next.confirms(reverse, snapshot: try snapshot(reverse.document, reverse.caret)))
    }

    func testMultilineEmojiAndDecomposedSelectedTextRetainsExactContext() throws {
        let selected = "🙂 ghbdtn\nvbh e\u{301}\u{2028}ntcn 👨‍👩‍👧‍👦"
        let converted = "🙂 привет\nмир e\u{301}\u{2028}тест 👨‍👩‍👧‍👦"
        let prefix = "left 😀 ", suffix = " right e\u{301}"
        let document = prefix + selected + suffix
        let plan = try XCTUnwrap(NativeTextReplacementPlan(snapshot: snapshot(document,
            NSRange(location: prefix.utf16.count, length: selected.utf16.count))))
        let result = try XCTUnwrap(plan.replacing(with: converted))
        XCTAssertTrue(AccessibilitySelectionPlan.exactlyEqual(result.document, prefix + converted + suffix))
        XCTAssertTrue(plan.confirms(result, snapshot: try snapshot(result.document, result.caret)))
        XCTAssertFalse(plan.confirms(result, snapshot: try snapshot(result.document.precomposedStringWithCanonicalMapping, result.caret)))
        XCTAssertFalse(plan.matches(try snapshot(document.precomposedStringWithCanonicalMapping,
            NSRange(location: prefix.utf16.count, length: selected.precomposedStringWithCanonicalMapping.utf16.count))))
    }

    func testNativeWordScopeAllowsUnicodeAndLongWordsWithoutChangingLegacyDeletionPolicy() throws {
        for word in ["🙂ghbdtn", "e\u{301}ghbdtn", String(repeating: "g", count: 300)] {
            let document = "prefix " + word + " suffix"
            let caret = 7 + word.utf16.count
            let plan = try XCTUnwrap(NativeTextReplacementPlan(snapshot: snapshot(document, NSRange(location: caret, length: 0))))
            XCTAssertEqual(plan.scope.text, word)
            XCTAssertEqual(plan.scope.range, NSRange(location: 7, length: word.utf16.count))
            XCTAssertNil(WordCursorPlan(value: document, caret: caret))
            XCTAssertNotNil(WordScopePlan(value: document, caret: caret))
        }
        XCTAssertNotNil(WordCursorPlan(value: "ghbdtn", caret: 6))
    }

    func testLongSelectionWithinDocumentBoundPreservesSuffix() throws {
        let selected = String(repeating: "ghbdtn\n", count: 400)
        let converted = String(repeating: "привет\n", count: 400)
        let document = "prefix " + selected + "suffix"
        let plan = try XCTUnwrap(NativeTextReplacementPlan(snapshot: snapshot(document, NSRange(location: 7, length: selected.utf16.count))))
        let result = try XCTUnwrap(plan.replacing(with: converted))
        XCTAssertTrue(plan.isSelection)
        XCTAssertEqual(result.document, "prefix " + converted + "suffix")
        XCTAssertEqual(result.caret, NSRange(location: 7 + converted.utf16.count, length: 0))
        XCTAssertTrue(plan.confirms(result, snapshot: try snapshot(result.document, result.caret)))
    }

    func testEndOfWordOnlyRejectsInsideAndAfterWhitespaceOrSplitGrapheme() throws {
        let document = "😀 ghbdtn suffix"
        for caret in 4..<9 {
            XCTAssertNil(NativeTextReplacementPlan(snapshot: try snapshot(document, NSRange(location: caret, length: 0))))
        }
        XCTAssertNotNil(NativeTextReplacementPlan(snapshot: try snapshot(document, NSRange(location: 9, length: 0))))
        XCTAssertNil(NativeTextReplacementPlan(snapshot: try snapshot(document, NSRange(location: 10, length: 0))))
        XCTAssertNil(NativeTextSnapshot(document: document, length: document.utf16.count,
            actualRange: NSRange(location: 0, length: document.utf16.count), selection: NSRange(location: 1, length: 0), marked: NSRange(location: NSNotFound, length: 0)))
    }

    func testFullEvidenceRejectsClippingWrongLengthOversizeUnavailableMarkAndAttachments() {
        let text = "prefix ghbdtn suffix"
        let selection = NSRange(location: 7, length: 6), unmarked = NSRange(location: NSNotFound, length: 0)
        XCTAssertNil(NativeTextSnapshot(document: text, length: text.utf16.count, actualRange: selection, selection: selection, marked: unmarked))
        XCTAssertNil(NativeTextSnapshot(document: "ghbdtn", length: text.utf16.count, actualRange: NSRange(location: 0, length: text.utf16.count), selection: selection, marked: unmarked))
        XCTAssertNil(NativeTextSnapshot(document: text, length: NSNotFound, actualRange: NSRange(location: 0, length: NSNotFound), selection: selection, marked: unmarked))
        let oversized = String(repeating: "a", count: NativeTextSnapshot.documentLimit + 1)
        XCTAssertNil(NativeTextSnapshot(document: oversized, length: oversized.utf16.count, actualRange: NSRange(location: 0, length: oversized.utf16.count), selection: NSRange(location: 1, length: 0), marked: unmarked))
        for marked in [NSRange(location: NSNotFound, length: NSNotFound), NSRange(location: 7, length: 1), NSRange(location: 99, length: 0)] {
            XCTAssertNil(NativeTextSnapshot(document: text, length: text.utf16.count, actualRange: NSRange(location: 0, length: text.utf16.count), selection: selection, marked: marked))
        }
        XCTAssertNil(NativeTextSnapshot(document: "a\u{FFFC}", length: 2, actualRange: NSRange(location: 0, length: 2), selection: NSRange(location: 0, length: 1), marked: unmarked))
    }

    func testResultBoundAndNeighborGraphemeMergeRejectBeforeWriting() throws {
        let large = String(repeating: "a", count: NativeTextSnapshot.documentLimit)
        let plan = try XCTUnwrap(NativeTextReplacementPlan(snapshot: snapshot(large, NSRange(location: 0, length: 1))))
        XCTAssertNil(plan.replacing(with: "aa"))
        let combining = try XCTUnwrap(NativeTextReplacementPlan(snapshot: snapshot("xq", NSRange(location: 1, length: 1))))
        XCTAssertNil(combining.replacing(with: "\u{301}"))
    }
}
