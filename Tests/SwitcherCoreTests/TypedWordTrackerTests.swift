import XCTest
@testable import SwitcherCore

final class TypedWordTrackerTests: XCTestCase {
    private func typing(_ text: String) -> TypedWordTracker {
        var tracker = TypedWordTracker()
        for character in text { tracker.typed(String(character)) }
        return tracker
    }

    func testFreshTrackerKnowsNothing() {
        XCTAssertEqual(TypedWordTracker().candidate, .unknown)
    }

    func testWordTypedAfterResetHasUnknownPrefix() {
        XCTAssertEqual(typing("ghbdtn").candidate, .word("ghbdtn", boundedStart: false))
    }

    func testWordAfterTypedSpaceIsBounded() {
        XCTAssertEqual(typing("привет ghbdtn").candidate, .word("ghbdtn", boundedStart: true))
        XCTAssertEqual(typing("привет ").candidate, .afterSpace)
    }

    func testPunctuationBelongsToTheWord() {
        XCTAssertEqual(typing("x j,thtv").candidate, .word("j,thtv", boundedStart: true))
    }

    func testBackspaceEditsTheCurrentWord() {
        var tracker = typing("ghbdtn ghbd")
        tracker.backspace()
        XCTAssertEqual(tracker.candidate, .word("ghb", boundedStart: true))
        for _ in 0..<3 { tracker.backspace() }
        XCTAssertEqual(tracker.candidate, .afterSpace)
    }

    func testBackspaceAcrossSpaceForgetsPossiblyAutocorrectedWord() {
        var tracker = typing("j,thtv ")
        tracker.backspace()
        XCTAssertEqual(tracker.candidate, .unknown)
        tracker.typed("x")
        XCTAssertEqual(tracker.candidate, .word("x", boundedStart: false))
    }

    func testNavigationAndControlCharactersForgetTheRun() {
        for key in ["\u{F702}", "\r", "\t", "\u{1B}", "\u{F728}", "\u{7F}", ""] {
            var tracker = typing("ghbdtn")
            tracker.typed(key)
            XCTAssertEqual(tracker.candidate, .unknown, "key \(key.unicodeScalars.map(\.value))")
        }
    }

    func testResetAfterClickForgetsTheRun() {
        var tracker = typing("ghbdtn")
        tracker.reset()
        XCTAssertEqual(tracker.candidate, .unknown)
        tracker.typed("a")
        XCTAssertEqual(tracker.candidate, .word("a", boundedStart: false))
    }

    func testOwnReplacementCanBeConvertedBack() {
        var tracker = typing("hi ghbdtn")
        tracker.replaceWord("ghbdtn", with: "привет")
        XCTAssertEqual(tracker.candidate, .word("привет", boundedStart: true))
        tracker.replaceWord("привет", with: "ghbdtn")
        XCTAssertEqual(tracker.candidate, .word("ghbdtn", boundedStart: true))
    }

    func testMismatchedReplacementForgetsTheRun() {
        var tracker = typing("ghbdtn")
        tracker.replaceWord("other", with: "x")
        XCTAssertEqual(tracker.candidate, .unknown)
    }

    func testOverlongWordStaysUnknownUntilSpace() {
        var tracker = typing(String(repeating: "a", count: TypedWordTracker.capacity + 1))
        XCTAssertEqual(tracker.candidate, .unknown)
        tracker.typed("b")
        tracker.backspace()
        XCTAssertEqual(tracker.candidate, .unknown)
        tracker.typed(" ")
        tracker.typed("c")
        XCTAssertEqual(tracker.candidate, .word("c", boundedStart: true))
    }

    func testLongRunKeepsTheLastWordBounded() {
        let tracker = typing(String(repeating: "ab ", count: 40) + "ghbdtn")
        XCTAssertEqual(tracker.candidate, .word("ghbdtn", boundedStart: true))
    }

    func testBackspaceCountRefusesComposedCharacters() {
        XCTAssertEqual(TypedWordTracker.backspaceCount(for: "j,thtv"), 6)
        XCTAssertNil(TypedWordTracker.backspaceCount(for: "e\u{301}"))
        XCTAssertNil(TypedWordTracker.backspaceCount(for: "🙂"))
        XCTAssertNil(TypedWordTracker.backspaceCount(for: ""))
    }

    func testOneWordDeletionNeedsBoundedLetters() {
        XCTAssertTrue(TypedWordTracker.deletesAsOneWord("ghbdtn", boundedStart: true))
        XCTAssertFalse(TypedWordTracker.deletesAsOneWord("ghbdtn", boundedStart: false))
        XCTAssertFalse(TypedWordTracker.deletesAsOneWord("j,thtv", boundedStart: true))
    }
}
