import XCTest
@testable import SwitcherCore

final class TextConversionTests: XCTestCase {
    private let mapping: [Character: String] = ["g": "п", "h": "р", "b": "и", "d": "в", "t": "е", "n": "т", "G": "П"]

    func testConvertsWordAndPreservesCase() {
        XCTAssertEqual(TextConversion.convert("Ghbdtn", mapping: mapping), "Привет")
    }

    func testSelectionKeepsWhitespaceEmojiAndUnknownCharacters() {
        XCTAssertEqual(TextConversion.convert("ghbdtn\n\tghbdtn 👩🏽‍💻 123", mapping: mapping), "привет\n\tпривет 👩🏽‍💻 123")
    }

    func testDirectionUsesTextInsteadOfActiveLayout() {
        XCTAssertEqual(TextConversion.direction(for: "ghbdtn", fallback: .toEnglish), .toRussian)
        XCTAssertEqual(TextConversion.direction(for: "Привет Ёж", fallback: .toRussian), .toEnglish)
        XCTAssertEqual(TextConversion.direction(for: "123", fallback: .toRussian), .toRussian)
    }

    func testCaretInsideAtStartAndAtEndOfWord() {
        for caret in [4, 6, 10] {
            XCTAssertEqual(TextConversion.tokenRange(in: "one ghbdtn two", caret: caret), NSRange(location: 4, length: 6))
        }
    }

    func testSingleCharacter() {
        XCTAssertEqual(TextConversion.tokenRange(in: "g", caret: 1), NSRange(location: 0, length: 1))
    }

    func testEndOfDocumentAndKeyboardPunctuation() {
        XCTAssertEqual(TextConversion.tokenRange(in: "abc [;", caret: 6), NSRange(location: 4, length: 2))
    }

    func testWhitespaceAndInvalidOffsets() {
        XCTAssertNil(TextConversion.tokenRange(in: "", caret: 0))
        XCTAssertNil(TextConversion.tokenRange(in: "  ", caret: 1))
        XCTAssertNil(TextConversion.tokenRange(in: "abc", caret: -1))
        XCTAssertNil(TextConversion.tokenRange(in: "abc", caret: 4))
    }

    func testUTF16OffsetsAfterEmoji() {
        let prefix = "👩🏽‍💻 "
        let start = (prefix as NSString).length
        XCTAssertEqual(TextConversion.tokenRange(in: prefix + "ghbdtn", caret: start + 3), NSRange(location: start, length: 6))
    }

    func testComposedCharacterIsNotSplit() {
        let text = "e\u{301}"
        XCTAssertEqual(TextConversion.tokenRange(in: text, caret: 1), NSRange(location: 0, length: 2))
    }
}
