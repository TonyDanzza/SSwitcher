import XCTest
@testable import SwitcherCore

final class NativeWordBoundaryPlanTests: XCTestCase {
    func testRequiresTheWholeNativeSelectionToBeOneWord() throws {
        let plan = try XCTUnwrap(NativeWordBoundaryPlan(selection: "ghbdtn"))
        XCTAssertEqual(plan.word, "ghbdtn")
        XCTAssertTrue(plan.matches("ghbdtn"))
        XCTAssertFalse(plan.matches(" ghbdtn"))
        for text in ["", "word ", "one two", "\u{fffc}word", String(repeating: "x", count: 257)] {
            XCTAssertNil(NativeWordBoundaryPlan(selection: text), text)
        }
    }
    func testOnlyOneExplicitWhitespaceGraphemeProvesRightBoundary() throws {
        let plan = try XCTUnwrap(NativeWordBoundaryPlan(selection: "ghbdtn"))
        for delimiter in [" ", "\n", "\r\n", "\t", "\u{00a0}"] {
            XCTAssertTrue(plan.acceptsFollowingSelection(delimiter), delimiter)
        }
        for invalid in ["", "d", "  ", " word", "ghbdtn", "👩‍💻", "!"] {
            XCTAssertFalse(plan.acceptsFollowingSelection(invalid), invalid)
        }
    }
    func testExactCommitPreservesUnicodeNormalizationAndRejectsNeighbors() throws {
        let plan = try XCTUnwrap(NativeWordBoundaryPlan(selection: "e\u{301}"))
        XCTAssertTrue(plan.matches("e\u{301}"))
        XCTAssertFalse(plan.matches("é"))
        XCTAssertFalse(plan.matches("e\u{301} next"))
    }
    func testDirectSelectionKeepsTrailingWhitespace() throws {
        let plain = try XCTUnwrap(NativeWordBoundaryPlan(directSelection: "ghbdtn"))
        XCTAssertEqual(plain.word, "ghbdtn")
        XCTAssertEqual(plain.trailing, "")
        let spaced = try XCTUnwrap(NativeWordBoundaryPlan(directSelection: "j,thtv \n"))
        XCTAssertEqual(spaced.word, "j,thtv")
        XCTAssertEqual(spaced.trailing, " \n")
        XCTAssertTrue(spaced.matches("j,thtv \n"))
        XCTAssertFalse(spaced.matches("j,thtv"))
        for invalid in ["", "   ", "two words", " lead"] {
            XCTAssertNil(NativeWordBoundaryPlan(directSelection: invalid), invalid)
        }
    }
}
