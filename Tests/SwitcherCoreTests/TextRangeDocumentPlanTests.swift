import XCTest
@testable import SwitcherCore

final class TextRangeDocumentPlanTests: XCTestCase {
    private func reply(_ request: NSRange, document: String) -> TextRangeDocumentPlan.Reply {
        let units = Array(document.utf16)
        guard request.location <= units.count, request.length <= units.count - request.location else { return .outOfBounds }
        return .text(String(decoding: units[request.location..<(request.location + request.length)], as: UTF16.self))
    }

    func testCanonicalMultilineDocumentUsesPublicCharactersWithoutNormalization() throws {
        let physical = "ghbdtn\nvbh\n\nntcn\u{2028}njym"
        let raw = "ghbdtn\n\nvbh\n\n\nntcn\u{2028}njym"
        var requests: [NSRange] = []
        let plan = try XCTUnwrap(TextRangeDocumentPlan(upperBound: raw.utf16.count, lowerCandidate: physical.utf16.count) {
            requests.append($0)
            return self.reply($0, document: physical)
        })
        XCTAssertEqual(plan.document.utf16.map { $0 }, physical.utf16.map { $0 })
        XCTAssertEqual(plan.length, 21)
        XCTAssertTrue(requests.contains(NSRange(location: 21, length: 0)))
        XCTAssertTrue(requests.contains(NSRange(location: 21, length: 1)))
        let word = try XCTUnwrap(AccessibilitySelectionPlan(document: plan.document, range: NSRange(location: 7, length: 3), selectedText: "vbh"))
        XCTAssertEqual(word.replacing(with: "мир")?.document, "ghbdtn\nмир\n\nntcn\u{2028}njym")
    }

    func testPartialSelectionAndEndCaretFindSameEmojiAndComposedDocument() throws {
        let physical = "🙂 e\u{301}\nghbdtn\n\nvbh\u{2028}ntcn"
        let upper = physical.utf16.count + 4
        for candidate in [0, 6, 12, physical.utf16.count] {
            let plan = try XCTUnwrap(TextRangeDocumentPlan(upperBound: upper, lowerCandidate: candidate) {
                self.reply($0, document: physical)
            })
            XCTAssertTrue(AccessibilitySelectionPlan.exactlyEqual(plan.document, physical))
            XCTAssertTrue(AccessibilitySelectionPlan.confirmsCaret(document: plan.document, range: NSRange(location: plan.length, length: 0), selectedText: "",
                                                                  expectedDocument: physical, expectedCaret: NSRange(location: physical.utf16.count, length: 0)))
        }
    }

    func testCachedLengthStillRequiresFullTextAndBothEndpointProofs() throws {
        let physical = "one\ntwo"
        var requests: [NSRange] = []
        let plan = try XCTUnwrap(TextRangeDocumentPlan(upperBound: 8, lowerCandidate: 3, cachedLength: 7) {
            requests.append($0)
            return self.reply($0, document: physical)
        })
        XCTAssertEqual(plan.document, physical)
        XCTAssertEqual(requests, [NSRange(location: 0, length: 7), NSRange(location: 7, length: 0),
                                  NSRange(location: 7, length: 1), NSRange(location: 0, length: 7)])
        XCTAssertNil(TextRangeDocumentPlan(upperBound: 8, lowerCandidate: 3, cachedLength: 6) {
            self.reply($0, document: physical)
        })
    }

    func testUnavailableClampedAndContradictingRepliesAreNeverBounds() {
        XCTAssertNil(TextRangeDocumentPlan(upperBound: 10, lowerCandidate: 0) { _ in .unavailable })
        XCTAssertNil(TextRangeDocumentPlan(upperBound: 10, lowerCandidate: 0) { _ in .text("short") })
        XCTAssertNil(TextRangeDocumentPlan(upperBound: 4, lowerCandidate: 0) { request in
            if request == NSRange(location: 4, length: 0) { return .text("x") }
            return self.reply(request, document: "text")
        })
        var wholeReads = 0
        XCTAssertNil(TextRangeDocumentPlan(upperBound: 4, lowerCandidate: 0) { request in
            if request == NSRange(location: 0, length: 4) {
                wholeReads += 1
                return .text(wholeReads == 1 ? "text" : "DIFF")
            }
            return self.reply(request, document: "text")
        })
    }

    func testMissingValueInsideAProvenSelectionCannotShrinkIt() {
        XCTAssertNil(TextRangeDocumentPlan(upperBound: 23, lowerCandidate: 21) { request in
            if request.length >= 21 { return .outOfBounds }
            return .text(String(repeating: "x", count: request.length))
        })
        XCTAssertNil(TextRangeDocumentPlan(upperBound: 4, lowerCandidate: 0) { request in
            if request == NSRange(location: 4, length: 1) { return .unavailable }
            return self.reply(request, document: "text")
        })
    }

    func testProbeAndLengthBudgetsBoundMalformedEditors() {
        var requests = 0
        XCTAssertNil(TextRangeDocumentPlan(upperBound: 1000, lowerCandidate: 0, maximumProbes: 3) {
            requests += 1
            return self.reply($0, document: "text")
        })
        XCTAssertEqual(requests, 3)
        for (upper, lower) in [(Int.max, 0), (-1, 0), (1, -1), (1, 2)] {
            XCTAssertNil(TextRangeDocumentPlan(upperBound: upper, lowerCandidate: lower) { _ in XCTFail("invalid bounds must not issue a read"); return .unavailable })
        }
    }

    func testEmbeddedAttachmentsCannotBecomePlainTextPayloads() {
        let document = "before \u{FFFC} after"
        XCTAssertNil(TextRangeDocumentPlan(upperBound: document.utf16.count, lowerCandidate: 0) {
            self.reply($0, document: document)
        })
        let plain = AccessibilitySelectionPlan(document: document, range: NSRange(location: 0, length: 6), selectedText: "before")
        XCTAssertNotNil(plain)
        XCTAssertTrue(AccessibilitySelectionPlan.confirmsCaret(document: document, range: NSRange(location: 6, length: 0), selectedText: "",
                                                              expectedDocument: document, expectedCaret: NSRange(location: 6, length: 0)))
        XCTAssertNil(AccessibilitySelectionPlan(document: document, range: NSRange(location: 0, length: 8), selectedText: "before \u{FFFC}"))
        XCTAssertNil(plain?.replacing(with: "after \u{FFFC}"))
        XCTAssertFalse(TextReplacementBackend.acceptsNativeText(document))
        XCTAssertNil(UnicodeTextInput(text: document))
    }
}
