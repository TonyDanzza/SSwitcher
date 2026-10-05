import XCTest
@testable import SwitcherCore

final class WordCursorPlanTests: XCTestCase {
    func testStartMiddleEndAndReverseConversionKeepCaret() throws {
        for (caret, steps) in [(3, 6), (6, 3), (9, 0)] {
            let plan = try XCTUnwrap(WordCursorPlan(value: "до ghbdtn после", caret: caret))
            XCTAssertEqual(plan.text, "ghbdtn")
            XCTAssertEqual(plan.stepsToEnd, steps)
            XCTAssertEqual(plan.selectionSteps, 6)
            let reverse = try XCTUnwrap(plan.replacingText(with: "привет"))
            XCTAssertEqual(reverse.stepsToEnd, steps)
            XCTAssertEqual(reverse.selectionSteps, 6)
            XCTAssertNil(plan.replacingText(with: "short"))
        }
    }

    func testKeyboardPunctuationIsPartOfWord() throws {
        let plan = try XCTUnwrap(WordCursorPlan(value: "rf;ljuj", caret: 3))
        XCTAssertEqual(plan.text, "rf;ljuj")
        XCTAssertEqual(plan.stepsToEnd, 4)
    }

    func testUnicodeOffsetsAndGraphemeSteps() throws {
        let plan = try XCTUnwrap(WordCursorPlan(value: "😀 ghbdtn", caret: 5))
        XCTAssertEqual(plan.stepsToEnd, 4)
        XCTAssertNil(WordCursorPlan(value: "e\u{301}word", caret: 1))
        XCTAssertNil(WordCursorPlan(value: "😀word", caret: 1))
    }

    func testInvalidOrEmptyPositionDoesNotMoveCursor() {
        for caret in [-1, 1, 2, 5] {
            XCTAssertNil(WordCursorPlan(value: "  ", caret: caret))
        }
        XCTAssertNil(WordCursorPlan(value: "word ", caret: 5))
        XCTAssertNil(WordCursorPlan(value: String(repeating: "a", count: 257), caret: 3))
    }
}
