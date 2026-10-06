import XCTest
@testable import SwitcherCore

final class CanvasSelectionPlanTests: XCTestCase {
    func testWholeDocumentRequiresCoherentEntireSelection() throws {
        let text = "ghbdtn\n🙂 e\u{301}\u{00A0}vbh"
        let selection = try XCTUnwrap(AccessibilitySelectionPlan(document: text, range: NSRange(location: 0, length: text.utf16.count), selectedText: text))
        XCTAssertEqual(CanvasSelectionPlan(selection: selection, replacementText: "привет\n🙂 e\u{301}\u{00A0}мир"), .entireDocument)
    }

    func testPartialRepeatedTextNeverSelectsAll() throws {
        let selection = try XCTUnwrap(AccessibilitySelectionPlan(document: "ghbdtn ghbdtn", range: NSRange(location: 7, length: 6), selectedText: "ghbdtn"))
        XCTAssertEqual(CanvasSelectionPlan(selection: selection, replacementText: "привет"), .characters(6))
    }

    func testPartialSelectionCountsGraphemesRatherThanAXUnits() throws {
        let text = "🙂 e\u{301}"
        let selection = try XCTUnwrap(AccessibilitySelectionPlan(document: "prefix " + text, range: NSRange(location: 7, length: text.utf16.count), selectedText: text))
        XCTAssertEqual(CanvasSelectionPlan(selection: selection, replacementText: text), .characters(3))
    }

    func testPartialRestorationCountsInsertedTextWhenMappingExpandsCharacters() throws {
        let selection = try XCTUnwrap(AccessibilitySelectionPlan(document: "prefix x", range: NSRange(location: 7, length: 1), selectedText: "x"))
        XCTAssertEqual(CanvasSelectionPlan(selection: selection, replacementText: "ab"), .characters(2))
    }
}
