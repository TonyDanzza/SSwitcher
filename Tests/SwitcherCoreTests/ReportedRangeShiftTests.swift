import XCTest
@testable import SwitcherCore

final class ReportedRangeShiftTests: XCTestCase {
    // Measured in Chrome: offsets counted 7 fewer characters than AXValue.
    private let value = "a\n\n\nb\n\n## Usage\n\nxnj tckb hjktq"

    func testMatchingOffsetsNeedNoShift() {
        let range = (value as NSString).range(of: "hjktq")
        XCTAssertEqual(ReportedRangeShift.resolve(value: value, range: range, selectedText: "hjktq", textBefore: nil), 0)
        let caret = NSRange(location: NSMaxRange(range), length: 0)
        XCTAssertEqual(ReportedRangeShift.resolve(value: value, range: caret, selectedText: "", textBefore: "tckb hjktq"), 0)
        XCTAssertEqual(ReportedRangeShift.resolve(value: value, range: caret, selectedText: "", textBefore: nil), 0)
    }

    func testUniqueSelectedTextFixesTheShift() {
        let actual = (value as NSString).range(of: "xnj tckb hjktq")
        let reported = NSRange(location: actual.location - 3, length: actual.length)
        XCTAssertEqual(ReportedRangeShift.resolve(value: value, range: reported, selectedText: "xnj tckb hjktq", textBefore: nil), 3)
    }

    func testRepeatedOrMissingTextIsRefused() {
        XCTAssertNil(ReportedRangeShift.resolve(value: "ab ab\n\nab", range: NSRange(location: 0, length: 2), selectedText: "ba", textBefore: nil))
        XCTAssertNil(ReportedRangeShift.resolve(value: "x ab\n\nab", range: NSRange(location: 0, length: 2), selectedText: "ab", textBefore: nil))
        XCTAssertNil(ReportedRangeShift.resolve(value: value, range: NSRange(location: 5, length: 0), selectedText: "", textBefore: "zzz"))
    }

    func testCaretShiftUsesTextBeforeTheCaret() {
        let end = (value as NSString).length
        let reported = NSRange(location: end - 3, length: 0)
        XCTAssertEqual(ReportedRangeShift.resolve(value: value, range: reported, selectedText: "", textBefore: "\n\n\nxnj tckb hjktq"), 3)
        XCTAssertEqual(ReportedRangeShift.resolve(value: value, range: reported, selectedText: "", textBefore: "tckb hjktq"), 3)
    }

    func testRangeTextWithoutParagraphBreaksStillLocatesTheCaret() {
        // Measured in Chrome: AXStringForRange joined paragraphs without "\n".
        let value = "<BentoGrid>\n</BentoGrid>\n```\nxnj tckb hjktq"
        let end = (value as NSString).length
        let reported = NSRange(location: end - 3, length: 0)
        XCTAssertEqual(ReportedRangeShift.resolve(value: value, range: reported, selectedText: "", textBefore: "</BentoGrid>```xnj tckb hjktq"), 3)
        // A located suffix that starts inside the caret's word is not proof.
        XCTAssertNil(ReportedRangeShift.resolve(value: "x\n\nabcdef", range: NSRange(location: 5, length: 0), selectedText: "", textBefore: "zzdef"))
    }
}
