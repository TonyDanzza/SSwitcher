import XCTest
@testable import SwitcherCore

final class WordCursorPlanTests: XCTestCase {
    func testOnlyEndOfWordIsEligible() throws {
        let text = "до ghbdtn после"
        for caret in 3..<9 { XCTAssertNil(WordCursorPlan(value: text, caret: caret)) }
        let plan = try XCTUnwrap(WordCursorPlan(value: text, caret: 9))
        XCTAssertEqual(plan.text, "ghbdtn")
        XCTAssertEqual(plan.deletingCharacters, 6)
        XCTAssertNil(WordCursorPlan(value: text, caret: 10))
    }

    func testKeyboardPunctuationIsPartOfWord() throws {
        XCTAssertNil(WordCursorPlan(value: "rf;ljuj", caret: 3))
        XCTAssertEqual(try XCTUnwrap(WordCursorPlan(value: "rf;ljuj", caret: 7)).text, "rf;ljuj")
    }

    func testUTF16PrefixDoesNotAffectDeletionCount() throws {
        let plan = try XCTUnwrap(WordCursorPlan(value: "😀 ghbdtn", caret: 9))
        XCTAssertEqual(plan.deletingCharacters, 6)
        XCTAssertNil(WordCursorPlan(value: "e\u{301}word", caret: 6))
        XCTAssertNil(WordCursorPlan(value: "😀word", caret: 6))
    }

    func testInvalidEmptyAndWhitespacePositionsAreIgnored() {
        for caret in [-1, 0, 1, 2, 5] { XCTAssertNil(WordCursorPlan(value: "  ", caret: caret)) }
        XCTAssertNil(WordCursorPlan(value: "word ", caret: 5))
        XCTAssertNil(WordCursorPlan(value: String(repeating: "a", count: 257), caret: 257))
        XCTAssertNotNil(WordCursorPlan(value: "g", caret: 1))
        XCTAssertNotNil(WordCursorPlan(value: "ghbdtn\n", caret: 6))
    }

    func testNeutralTrailingPunctuationDoesNotBlockTheWord() throws {
        let neutral: (Character) -> Bool = { $0 == ")" || $0 == "!" }
        let text = "МП Учитель (Hfcgbcfybt)"
        let caret = (text as NSString).length - 1
        XCTAssertNil(WordCursorPlan(value: text, caret: caret))
        let plan = try XCTUnwrap(WordCursorPlan(value: text, caret: caret, ignoringTrailing: neutral))
        XCTAssertEqual(plan.text, "(Hfcgbcfybt")
        XCTAssertEqual(try XCTUnwrap(WordCursorPlan(value: "ghbdtn)!", caret: 6, ignoringTrailing: neutral)).text, "ghbdtn")
        XCTAssertNil(WordCursorPlan(value: "ghbdtn]", caret: 6, ignoringTrailing: neutral))
        XCTAssertNil(WordCursorPlan(value: "ghb)dtn", caret: 3, ignoringTrailing: neutral))
        XCTAssertNil(WordCursorPlan(value: "(ghbdtn)", caret: 0, ignoringTrailing: neutral))
    }
}
