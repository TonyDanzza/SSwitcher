import XCTest
@testable import SwitcherCore

final class TextReplacementBackendTests: XCTestCase {
    func testSelectedTextBackendRequiresProvenNativeEditorAndSettableAttribute() {
        func backend(_ bundle: String, own: Bool = false, electron: Bool = false, role: String = "AXTextArea", selected: Bool = true, settable: Bool = true) -> TextReplacementBackend {
            .select(isSelected: selected, bundleID: bundle, isCurrentProcess: own, isElectron: electron, role: role, selectedTextSettable: settable)
        }
        XCTAssertEqual(backend("com.apple.TextEdit"), .accessibilitySelectedText)
        XCTAssertEqual(backend("com.tonydanzza.SSwitcher", own: true), .accessibilitySelectedText)
        for bundle in ["com.figma.Desktop", "com.apple.Notes", "unknown.native.editor"] {
            XCTAssertEqual(backend(bundle), .unicodeEvents)
        }
        XCTAssertEqual(backend("com.apple.TextEdit", selected: false), .unicodeEvents)
        XCTAssertEqual(backend("com.apple.TextEdit", settable: false), .unicodeEvents)
        XCTAssertEqual(backend("com.apple.TextEdit", electron: true), .unicodeEvents)
        XCTAssertEqual(backend("com.apple.TextEdit", role: "AXStaticText"), .unicodeEvents)
        XCTAssertEqual(backend("com.tonydanzza.SSwitcher", own: true, role: "AXTextField"), .unicodeEvents)
    }

    func testNativeLiteralLinesPreserveTextWithoutKeyboardGraphemeSizeLimit() {
        XCTAssertTrue(TextReplacementBackend.acceptsNativeText("ghbdtn\nvbh 🙂 e\u{301}\u{2028}ntcn"))
        XCTAssertTrue(TextReplacementBackend.acceptsNativeText("e" + String(repeating: "\u{301}", count: 25)))
        for control in ["", "\t", "\r", "\r\n", "\0", "\u{7F}", "\u{85}", "\u{2029}"] {
            XCTAssertFalse(TextReplacementBackend.acceptsNativeText(control))
        }
    }

    func testSetterSuccessWithUnchangedDocumentCannotAcknowledgeOrReserveFallback() throws {
        let original = "prefix ghbdtn suffix"
        let selection = try XCTUnwrap(AccessibilitySelectionPlan(document: original, range: NSRange(location: 7, length: 6), selectedText: "ghbdtn"))
        let replacement = try XCTUnwrap(selection.replacing(with: "привет"))
        var lifecycle = ConversionLifecycle()
        XCTAssertTrue(lifecycle.commitMutation())
        // A reported successful setter with unchanged actual AX evidence is
        // indistinguishable from a pending/false success: neither is proof.
        XCTAssertFalse(AccessibilitySelectionPlan.confirmsCaret(document: original, range: replacement.caret, selectedText: "",
                                                                expectedDocument: replacement.document, expectedCaret: replacement.caret))
        XCTAssertFalse(replacement.confirmsSelection(document: original, range: selection.range, selectedText: selection.text))
        XCTAssertFalse(lifecycle.commitMutation())
        XCTAssertTrue(lifecycle.hasMutated)
        XCTAssertTrue(lifecycle.finish())
        XCTAssertFalse(lifecycle.commitMutation())
    }
}
