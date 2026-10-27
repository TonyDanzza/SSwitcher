import XCTest
@testable import SwitcherCore

final class DeletionProgressTests: XCTestCase {
    private let document = "a yjotn,l b"
    private let word = NSRange(location: 2, length: 7)

    func testCompleteAndPartialDeletion() {
        XCTAssertEqual(DeletionProgress.evaluate(document: document, wordRange: word, value: "a  b", caret: NSRange(location: 2, length: 0)), .done)
        // Measured on Yandex Market in Safari: 3 of 7 Backspaces arrived.
        XCTAssertEqual(DeletionProgress.evaluate(document: document, wordRange: word, value: "a yjot b", caret: NSRange(location: 6, length: 0)), .remaining(4))
        XCTAssertEqual(DeletionProgress.evaluate(document: document, wordRange: word, value: document, caret: NSRange(location: 9, length: 0)), .remaining(7))
    }

    func testAnythingElseIsUnknown() {
        XCTAssertEqual(DeletionProgress.evaluate(document: document, wordRange: word, value: "a yjo b", caret: NSRange(location: 5, length: 0)), .remaining(3))
        XCTAssertEqual(DeletionProgress.evaluate(document: document, wordRange: word, value: "a yxo b", caret: NSRange(location: 4, length: 0)), .unknown)
        XCTAssertEqual(DeletionProgress.evaluate(document: document, wordRange: word, value: "a  b", caret: NSRange(location: 3, length: 0)), .unknown)
        XCTAssertEqual(DeletionProgress.evaluate(document: document, wordRange: word, value: "a  b", caret: NSRange(location: 2, length: 1)), .unknown)
        XCTAssertEqual(DeletionProgress.evaluate(document: document, wordRange: word, value: nil, caret: nil), .unknown)
    }

    func testChromiumNoBreakSpaceAfterDeletionCountsAsDone() {
        // Measured in Chrome: "что-то ещё ghbdtn" → "что-то ещё\u{A0}" after the Backspaces.
        let document = "что-то ещё ghbdtn"
        XCTAssertEqual(DeletionProgress.evaluate(document: document, wordRange: NSRange(location: 11, length: 6),
                                                 value: "что-то ещё\u{00A0}", caret: NSRange(location: 11, length: 0)), .done)
    }
}
