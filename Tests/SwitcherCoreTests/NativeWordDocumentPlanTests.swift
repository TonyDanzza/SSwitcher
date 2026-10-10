import XCTest
@testable import SwitcherCore

final class NativeWordDocumentPlanTests: XCTestCase {
    func testWordIsTheOnlyPermittedCommitScope() throws {
        let prefix = "first e\u{301} 👩‍💻\nsecond ghbdtn"
        let plan = try XCTUnwrap(NativeWordDocumentPlan(prefix: prefix, document: prefix + " after"))
        XCTAssertEqual(plan.word, "ghbdtn")
        XCTAssertTrue(plan.matches("ghbdtn"))
        XCTAssertFalse(plan.matches(prefix))
        XCTAssertFalse(plan.matches(" ghbdtn"))
        XCTAssertTrue(plan.caret.fromEnd)
        XCTAssertEqual(plan.caret.offsetGraphemes, 6)
    }

    func testDocumentEndAndWhitespaceBoundaryRequireExactNonemptyPackets() {
        XCTAssertNotNil(NativeWordDocumentPlan(prefix: "ghbdtn", document: "ghbdtn"))
        XCTAssertNotNil(NativeWordDocumentPlan(prefix: "ghbdtn", document: "ghbdtn after"))
        XCTAssertNil(NativeWordDocumentPlan(prefix: "", document: ""))
        XCTAssertNil(NativeWordDocumentPlan(prefix: "ghbdtn", document: ""))
        XCTAssertNil(NativeWordDocumentPlan(prefix: "ghb", document: "ghbdtn"))
        XCTAssertNil(NativeWordDocumentPlan(prefix: "ghbdtn ", document: "ghbdtn after"))
        XCTAssertNil(NativeWordDocumentPlan(prefix: "e", document: "e\u{301} after"))
    }

    func testRestorationSurvivesMidwordRefusalAndChoosesTheNearerEdge() throws {
        let middle = try XCTUnwrap(NativeDocumentCaretPlan(prefix: "ghb", document: "ghbdtn"))
        XCTAssertTrue(middle.fromEnd)
        XCTAssertEqual(middle.offsetGraphemes, 3)
        let longSuffix = try XCTUnwrap(NativeDocumentCaretPlan(prefix: "word", document: "word " + String(repeating: "x", count: 300)))
        XCTAssertFalse(longSuffix.fromEnd)
        XCTAssertEqual(longSuffix.offsetGraphemes, 4)
        let longPrefix = String(repeating: "word ", count: 100) + "word"
        XCTAssertNotNil(NativeWordDocumentPlan(prefix: longPrefix, document: longPrefix))
        XCTAssertNil(NativeDocumentCaretPlan(prefix: longPrefix, document: longPrefix + String(repeating: "x", count: 257)))
    }

    func testNormalizationGraphemeSplitsAttachmentsAndOversizedWordsAreRefused() {
        XCTAssertNil(NativeDocumentCaretPlan(prefix: "é", document: "e\u{301}"))
        XCTAssertNil(NativeDocumentCaretPlan(prefix: "e", document: "e\u{301}"))
        XCTAssertNil(NativeWordDocumentPlan(prefix: "word", document: "else word"))
        XCTAssertNil(NativeWordDocumentPlan(prefix: "\u{fffc} word", document: "\u{fffc} word"))
        XCTAssertNil(NativeWordDocumentPlan(prefix: String(repeating: "x", count: 257), document: String(repeating: "x", count: 257)))
    }
}
