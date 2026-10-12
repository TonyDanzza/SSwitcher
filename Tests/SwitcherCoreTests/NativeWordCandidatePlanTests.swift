import XCTest
@testable import SwitcherCore

final class NativeWordCandidatePlanTests: XCTestCase {
    func testPrefixProvidesTheWholeLastTokenIncludingKeyboardPunctuation() {
        let plan = NativeWordCandidatePlan(prefix: "first\nsecond\tghbdtn;[!")
        XCTAssertEqual(plan?.text, "ghbdtn;[!")
        XCTAssertNil(NativeWordCandidatePlan(prefix: "ghbdtn "))
        XCTAssertNil(NativeWordCandidatePlan(prefix: ""))
    }

    func testMatchingUsesExactUTF16() {
        let plan = NativeWordCandidatePlan(prefix: "previous e\u{301}👩‍💻x")
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
}
