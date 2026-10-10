import XCTest
@testable import SwitcherCore

final class NativeWordCandidatePlanTests: XCTestCase {
    func testNonemptyRightProbeProvesEOFOrOneWhitespaceGrapheme() {
        for boundary in ["", " ", "\t", "\n", "\r\n", "\u{00a0}"] {
            XCTAssertTrue(NativeWordCandidatePlan.acceptsRightProbe(prefix: "previous ghbdtn", expanded: "previous ghbdtn" + boundary))
        }
        for continuation in ["t", "!", "👩‍💻", "\u{fffc}", "  ", " \na"] {
            XCTAssertFalse(NativeWordCandidatePlan.acceptsRightProbe(prefix: "ghbdtn", expanded: "ghbdtn" + continuation))
        }
        XCTAssertFalse(NativeWordCandidatePlan.acceptsRightProbe(prefix: "", expanded: ""))
        XCTAssertFalse(NativeWordCandidatePlan.acceptsRightProbe(prefix: "ghbdtn", expanded: ""))
        XCTAssertFalse(NativeWordCandidatePlan.acceptsRightProbe(prefix: "ghbdtn", expanded: "ghbdt"))
        XCTAssertFalse(NativeWordCandidatePlan.acceptsRightProbe(prefix: "é", expanded: "e\u{301} "))
    }
    func testOnlyWhitespaceOrDocumentEndCanFollowTheCaret() {
        for boundary: String? in [nil, " ", "\t", "\n", "\r\n", "\u{00a0}"] {
            XCTAssertTrue(NativeWordCandidatePlan.isFollowingBoundary(boundary))
        }
        for continuation in ["", "t", "!", "👩‍💻", "\u{fffc}", "  ", " \na"] {
            XCTAssertFalse(NativeWordCandidatePlan.isFollowingBoundary(continuation))
        }
    }

    func testPrefixProvidesTheWholeLastTokenIncludingKeyboardPunctuation() {
        let plan = NativeWordCandidatePlan(prefix: "first\nsecond\tghbdtn;[!")
        XCTAssertEqual(plan?.text, "ghbdtn;[!")
        XCTAssertEqual(plan?.backwardGraphemes, 9)
        XCTAssertNil(NativeWordCandidatePlan(prefix: "ghbdtn "))
        XCTAssertNil(NativeWordCandidatePlan(prefix: ""))
    }

    func testNavigationCountsWholeGraphemesButMatchingUsesExactUTF16() {
        let plan = NativeWordCandidatePlan(prefix: "previous e\u{301}👩‍💻x")
        XCTAssertEqual(plan?.backwardGraphemes, 3)
        XCTAssertTrue(plan?.matches("e\u{301}👩‍💻x") == true)
        XCTAssertFalse(plan?.matches("é👩‍💻x") == true)
        XCTAssertFalse(plan?.matches("👩‍💻x") == true)
    }

    func testAttachmentOutsideTheWordDoesNotBecomeItsReplacementScope() {
        XCTAssertEqual(NativeWordCandidatePlan(prefix: "\u{fffc} preceding ghbdtn")?.text, "ghbdtn")
        XCTAssertNil(NativeWordCandidatePlan(prefix: "gh\u{fffc}bdtn"))
    }

    func testWorkAndNavigationAreBounded() {
        XCTAssertNotNil(NativeWordCandidatePlan(prefix: String(repeating: "a", count: 256)))
        XCTAssertNil(NativeWordCandidatePlan(prefix: String(repeating: "a", count: 257)))
        XCTAssertNil(NativeWordCandidatePlan(prefix: String(repeating: "x ", count: 32768) + "word"))
    }

    func testLeftProbeRequiresExactSuffixAndOneWholeGrapheme() {
        XCTAssertTrue(NativeWordCandidatePlan.acceptsLeftProbe(previous: "word", expanded: "word"))
        XCTAssertTrue(NativeWordCandidatePlan.acceptsLeftProbe(previous: "word", expanded: " word"))
        XCTAssertTrue(NativeWordCandidatePlan.acceptsLeftProbe(previous: "word", expanded: "👩‍💻word"))
        XCTAssertFalse(NativeWordCandidatePlan.acceptsLeftProbe(previous: "word", expanded: "two word"))
        XCTAssertFalse(NativeWordCandidatePlan.acceptsLeftProbe(previous: "word", expanded: " wordx"))
        XCTAssertFalse(NativeWordCandidatePlan.acceptsLeftProbe(previous: "é", expanded: " e\u{301}"))
        XCTAssertTrue(NativeWordCandidatePlan.containsDelimiter("\u{00a0}word"))
        XCTAssertFalse(NativeWordCandidatePlan.containsDelimiter("hello.world"))
    }
}
