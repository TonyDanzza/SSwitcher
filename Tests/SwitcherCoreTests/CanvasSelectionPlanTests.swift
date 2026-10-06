import XCTest
@testable import SwitcherCore

final class CanvasSelectionPlanTests: XCTestCase {
    func testWholeDocumentRequiresActualCopyAndCoherentEntireRange() {
        let text = "ghbdtn\n🙂 e\u{301}\u{00A0}vbh"
        XCTAssertEqual(CanvasSelectionPlan(copiedText: text, document: text,
                                           range: NSRange(location: 0, length: text.utf16.count)), .entireDocument)
        for range in [nil, NSRange(location: 1, length: text.utf16.count - 1),
                      NSRange(location: 0, length: text.count)] {
            XCTAssertEqual(CanvasSelectionPlan(copiedText: text, document: text, range: range), .characters(text.count))
        }
        XCTAssertEqual(CanvasSelectionPlan(copiedText: "vbh", document: text,
                                           range: NSRange(location: 0, length: text.utf16.count)), .characters(3))
    }

    func testPartialRepeatedTextAndStaleMirrorNeverSelectAll() {
        XCTAssertEqual(CanvasSelectionPlan(copiedText: "ghbdtn", document: "ghbdtn ghbdtn",
                                           range: NSRange(location: 7, length: 6)), .characters(6))
        XCTAssertEqual(CanvasSelectionPlan(copiedText: "привет", document: "ghbdtn",
                                           range: NSRange(location: 0, length: 6)), .characters(6))
        XCTAssertEqual(CanvasSelectionPlan(copiedText: "", document: "", range: NSRange(location: 0, length: 0)), .characters(0))
    }

    func testPartialSelectionCountsGraphemesRatherThanAXUnits() {
        let text = "🙂 e\u{301}"
        XCTAssertEqual(CanvasSelectionPlan(copiedText: text, document: "prefix " + text,
                                           range: NSRange(location: 7, length: text.utf16.count)), .characters(3))
    }

    func testPartialRestorationCountsInsertedTextWhenMappingExpandsCharacters() {
        XCTAssertEqual(CanvasSelectionPlan(copiedText: "x", replacementText: "ab", document: "prefix x",
                                           range: NSRange(location: 7, length: 1)), .characters(2))
    }

    func testLateOriginalCopyAndIncompleteSuffixNeverConfirmButCanRetry() {
        var verification = CanvasSelectionVerification(expected: "привет мир", previouslyCopied: "ghbdtn vbh", start: 0, timeout: 0.5)
        XCTAssertTrue(verification.beginCopy(at: 0))
        XCTAssertEqual(verification.decision(copied: "ghbdtn vbh", at: 0.1), .retry)
        XCTAssertTrue(verification.beginCopy(at: 0.12))
        XCTAssertEqual(verification.decision(copied: "мир", at: 0.2), .retry)
        XCTAssertTrue(verification.beginCopy(at: 0.22))
        XCTAssertEqual(verification.decision(copied: "привет мир", at: 0.3), .confirmed)
        XCTAssertEqual(verification.copies, 3)
        XCTAssertFalse(verification.beginCopy(at: 0.32))
    }

    func testUnrelatedCopyAndSelectionWiderThanReplacementCannotRetry() {
        var verification = CanvasSelectionVerification(expected: "привет", previouslyCopied: "ghbdtn", start: 10, timeout: 0.5)
        XCTAssertTrue(verification.beginCopy(at: 10))
        for copied in ["", "прив", "prefix привет", "new user copy"] {
            XCTAssertEqual(verification.decision(copied: copied, at: 10.1), .unverified)
        }
        XCTAssertEqual(verification.decision(copied: "вет", at: 10.5), .unverified)
        XCTAssertFalse(verification.beginCopy(at: 10.5))
        XCTAssertEqual(verification.expiresAt, 10.5)
    }

    func testRepeatedTransientCopiesAreBoundedWithoutExtendingDeadline() {
        var verification = CanvasSelectionVerification(expected: "привет", previouslyCopied: "ghbdtn", start: 0, timeout: 0.5)
        for n in 0..<3 {
            XCTAssertTrue(verification.beginCopy(at: Double(n) * 0.1))
            XCTAssertEqual(verification.decision(copied: "вет", at: Double(n) * 0.1), n == 2 ? .unverified : .retry)
        }
        XCTAssertFalse(verification.beginCopy(at: 0.3))
        XCTAssertEqual(verification.expiresAt, 0.5)
    }
}
