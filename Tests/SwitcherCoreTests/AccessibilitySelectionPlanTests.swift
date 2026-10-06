import XCTest
@testable import SwitcherCore

final class AccessibilitySelectionPlanTests: XCTestCase {
    func testSelectionRequiresDocumentAndExactRangeEvidence() {
        let document = "ghbdtn ghbdtn"
        let range = NSRange(location: 7, length: 6)
        let plan = AccessibilitySelectionPlan(document: document, range: range, selectedText: "ghbdtn")
        XCTAssertEqual(plan?.text, "ghbdtn")
        XCTAssertFalse(plan?.isEntireDocument ?? true)
        XCTAssertNil(AccessibilitySelectionPlan(document: nil, range: range, selectedText: "ghbdtn"))
        XCTAssertNil(AccessibilitySelectionPlan(document: document, range: nil, selectedText: "ghbdtn"))
        XCTAssertNil(AccessibilitySelectionPlan(document: document, range: NSRange(location: 7, length: 0), selectedText: "ghbdtn"))
        XCTAssertNil(AccessibilitySelectionPlan(document: document, range: range, selectedText: "привет"))
        XCTAssertNil(AccessibilitySelectionPlan(document: document, range: range, selectedText: ""))
        XCTAssertNotNil(AccessibilitySelectionPlan(document: document, range: range, selectedText: nil))
    }

    func testOutOfBoundsAndOverflowOffsetsAreRejected() {
        for range in [NSRange(location: -1, length: 1), NSRange(location: 0, length: -1),
                      NSRange(location: 4, length: 1), NSRange(location: 2, length: 2),
                      NSRange(location: Int.max, length: Int.max), NSRange(location: 1, length: Int.max)] {
            XCTAssertNil(AccessibilitySelectionPlan(document: "abc", range: range, selectedText: nil))
        }
    }

    func testSurrogateAndComposedGraphemeBoundariesAreRequired() {
        let document = "🙂 e\u{301} 👨‍👩‍👧‍👦"
        XCTAssertNotNil(AccessibilitySelectionPlan(document: document, range: NSRange(location: 0, length: document.utf16.count), selectedText: document))
        for range in [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1),
                      NSRange(location: 3, length: 1), NSRange(location: 4, length: 1),
                      NSRange(location: 6, length: 2)] {
            XCTAssertNil(AccessibilitySelectionPlan(document: document, range: range, selectedText: nil))
        }
    }

    func testCanonicalEqualityIsInsufficientForAXOffsets() {
        let decomposed = "e\u{301}"
        let composed = "é"
        XCTAssertEqual(decomposed, composed)
        XCTAssertNil(AccessibilitySelectionPlan(document: decomposed, range: NSRange(location: 0, length: 2), selectedText: composed))
        let plan = AccessibilitySelectionPlan(document: decomposed, range: NSRange(location: 0, length: 2), selectedText: decomposed)!
        XCTAssertFalse(plan.matches(document: composed, range: NSRange(location: 0, length: 1), selectedText: composed))
    }

    func testFreshSnapshotMustKeepWholeDocumentAndRepeatedTextScope() {
        let plan = AccessibilitySelectionPlan(document: "ghbdtn ghbdtn", range: NSRange(location: 7, length: 6), selectedText: "ghbdtn")!
        XCTAssertTrue(plan.matches(document: "ghbdtn ghbdtn", range: plan.range, selectedText: "ghbdtn"))
        XCTAssertFalse(plan.matches(document: "ghbdtn ghbdtn", range: NSRange(location: 0, length: 6), selectedText: "ghbdtn"))
        XCTAssertFalse(plan.matches(document: "PREFIX ghbdtn", range: plan.range, selectedText: "ghbdtn"))
        XCTAssertFalse(plan.matches(document: plan.document, range: NSRange(location: 13, length: 0), selectedText: ""))
    }

    func testMultilineReplacementKeepsUTF16ScopeAndUntouchedNeighbors() {
        let text = "ghbdtn\nvbh 🙂 e\u{301}"
        let original = "prefix " + text + " suffix"
        let plan = AccessibilitySelectionPlan(document: original, range: NSRange(location: 7, length: text.utf16.count), selectedText: text)!
        let converted = "привет\nмир 🙂 e\u{301}"
        let result = plan.replacing(with: converted)!
        XCTAssertEqual(result.document, "prefix " + converted + " suffix")
        XCTAssertEqual(result.range, NSRange(location: 7, length: converted.utf16.count))
        XCTAssertEqual(result.caret, NSRange(location: 7 + converted.utf16.count, length: 0))
        XCTAssertTrue(result.confirmsSelection(document: result.document, range: result.range, selectedText: converted))
        XCTAssertFalse(result.confirmsSelection(document: result.document, range: result.caret, selectedText: ""))
        XCTAssertFalse(result.confirmsSelection(document: result.document, range: NSRange(location: 0, length: result.document.utf16.count), selectedText: result.document))
        XCTAssertFalse(result.documentMatches("changed " + result.document))
    }

    func testEntireDocumentProofRequiresExactCompleteSelection() {
        let text = "ghbdtn\n🙂"
        let plan = AccessibilitySelectionPlan(document: text, range: NSRange(location: 0, length: text.utf16.count), selectedText: text)!
        XCTAssertTrue(plan.isEntireDocument)
        XCTAssertTrue(plan.replacing(with: "привет\n🙂")!.isEntireDocument)
    }

    func testReplacementCannotCreatePartialNeighborGraphemeSelection() {
        let plan = AccessibilitySelectionPlan(document: "x a", range: NSRange(location: 2, length: 1), selectedText: "a")!
        XCTAssertNil(plan.replacing(with: "\u{301}"))
        XCTAssertNil(plan.replacing(with: ""))
    }

    func testMultipleSelectionsAndContradictingCollectionAreRejected() {
        let document = "ghbdtn ghbdtn"
        let range = NSRange(location: 7, length: 6)
        XCTAssertNotNil(AccessibilitySelectionPlan(document: document, range: range, selectedText: "ghbdtn", selectedRanges: [range]))
        for collection in [[], [NSRange(location: 0, length: 6)], [range, NSRange(location: 0, length: 6)]] {
            XCTAssertNil(AccessibilitySelectionPlan(document: document, range: range, selectedText: "ghbdtn", selectedRanges: collection))
        }
    }

    func testCaretAcknowledgementRequiresExactDocumentOffsetAndEmptySelection() {
        let document = "prefix привет 🙂 e\u{301} suffix"
        let caret = NSRange(location: 13, length: 0)
        func confirms(_ value: String?, _ range: NSRange?, _ text: String?, _ ranges: [NSRange]? = nil) -> Bool {
            AccessibilitySelectionPlan.confirmsCaret(document: value, range: range, selectedText: text, selectedRanges: ranges,
                                                    expectedDocument: document, expectedCaret: caret)
        }
        XCTAssertTrue(confirms(document, caret, "", [caret]))
        XCTAssertTrue(confirms(document, caret, nil))
        XCTAssertFalse(confirms(document, NSRange(location: 7, length: 0), ""))
        XCTAssertFalse(confirms(document, NSRange(location: 7, length: 6), "привет"))
        XCTAssertFalse(confirms(document, caret, "привет"))
        XCTAssertFalse(confirms(document, caret, "", [caret, NSRange(location: 0, length: 0)]))
        XCTAssertFalse(confirms(document + "!", caret, ""))
        XCTAssertFalse(confirms(nil, caret, ""))
    }

    func testCanvasObjectMarkerAndParagraphNormalizationCannotGuessSelection() {
        let original = "ghbdtn vbh"
        let value = "\n\n" + original
        let selected = "\u{FFFC}" + value
        XCTAssertNil(AccessibilitySelectionPlan(document: value, range: NSRange(location: 0, length: selected.utf16.count), selectedText: selected))
        XCTAssertNil(AccessibilitySelectionPlan(document: value, range: NSRange(location: 0, length: value.utf16.count), selectedText: "\n" + original))
    }

}
