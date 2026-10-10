import XCTest
@testable import SwitcherCore

final class NativeServicePayloadTests: XCTestCase {
    func testLiteralLineEndingsAndUnicodeSurviveSelectedConversion() {
        let input = "ghbdtn\r\nvbh\t🙂\n e\u{301}\u{2028}👩‍💻"
        let mapping: [Character: String] = ["g": "п", "h": "р", "b": "и", "d": "в", "t": "е", "n": "т", "v": "м"]
        let response = TextConversion.convert(input, mapping: mapping)
        XCTAssertTrue(NativeServicePayload.accepts(input))
        XCTAssertTrue(NativeServicePayload.accepts(response))
        XCTAssertEqual(Array(response.utf16), Array("привет\r\nмир\t🙂\n e\u{301}\u{2028}👩‍💻".utf16))
    }

    func testAttachmentsAndUnsafeControlPacketsAreRefused() {
        for text in ["", "plain\u{FFFC}text", "plain\0text", "plain\u{1B}text",
                     "plain\u{7F}text", "plain\rtext", "plain\r", "plain\r\r\n"] {
            XCTAssertFalse(NativeServicePayload.accepts(text))
        }
        XCTAssertTrue(NativeServicePayload.accepts("plain\r\ntext"))
    }

    func testBoundIsUTF16AndAppliesToResponseAsWellAsInput() {
        let exact = String(repeating: "🙂", count: NativeServicePayload.utf16Limit / 2)
        XCTAssertTrue(NativeServicePayload.accepts(exact))
        XCTAssertFalse(NativeServicePayload.accepts(exact + "x"))
        let input = String(repeating: "x", count: NativeServicePayload.utf16Limit)
        XCTAssertTrue(NativeServicePayload.accepts(input))
        XCTAssertFalse(NativeServicePayload.accepts(TextConversion.convert(input, mapping: ["x": "🙂"])))
    }
}
