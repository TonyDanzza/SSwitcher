import XCTest
@testable import SwitcherCore

final class TextReplacementBackendTests: XCTestCase {
    func testQueryValueBackendIsExclusiveToVerifiedSpotlightWordWithBothCapabilities() {
        func backend(selected: Bool = false, bundle: String = "com.apple.campo", role: String = "AXTextField",
                     verified: Bool = true, value: Bool = true, range: Bool = true, electron: Bool = false) -> TextReplacementBackend {
            .select(isSelected: selected, bundleID: bundle, isCurrentProcess: false, isElectron: electron,
                    role: role, selectedTextSettable: false, verifiedSpotlightSearch: verified,
                    queryValueSettable: value, queryRangeSettable: range)
        }
        XCTAssertEqual(backend(), .accessibilitySpotlightQuery)
        XCTAssertEqual(backend(selected: true), .unicodeEvents)
        XCTAssertEqual(backend(bundle: "com.apple.TextEdit"), .unicodeEvents)
        XCTAssertEqual(backend(role: "AXTextArea"), .unicodeEvents)
        XCTAssertEqual(backend(verified: false), .unicodeEvents)
        XCTAssertEqual(backend(value: false), .unicodeEvents)
        XCTAssertEqual(backend(range: false), .unicodeEvents)
        XCTAssertEqual(backend(electron: true), .unicodeEvents)
    }
    func testSpotlightSetterRequiresFreshCapabilityAndVerifiedSearchScope() {
        func backend(selected: Bool = true, bundle: String = "com.apple.campo", role: String = "AXTextField",
                     settable: Bool = true, verified: Bool = true) -> TextReplacementBackend {
            .select(isSelected: selected, bundleID: bundle, isCurrentProcess: false, isElectron: false,
                    role: role, selectedTextSettable: settable, verifiedSpotlightSearch: verified)
        }
        XCTAssertEqual(backend(), .accessibilitySelectedText)
        XCTAssertEqual(backend(selected: false), .unicodeEvents)
        XCTAssertEqual(backend(verified: false), .unicodeEvents)
        XCTAssertEqual(backend(settable: false), .unicodeEvents)
        XCTAssertEqual(backend(role: "AXTextArea"), .unicodeEvents)
        XCTAssertEqual(backend(bundle: "other.app"), .unicodeEvents)
    }
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

    func testGenericNativeSelectedFragmentIsOnlyForAnOtherwiseUnsupportedSafePayload() {
        func backend(_ text: String, selected: Bool = true, settable: Bool = true,
                     electron: Bool = false, figma: Bool = false, role: String = "AXTextArea") -> TextReplacementBackend {
            let needsNative = UnicodeTextInput(text: text, controlPolicy: .singleLine) == nil &&
                TextReplacementBackend.acceptsNativeText(text)
            return .select(isSelected: selected, bundleID: "ordinary.native.editor", isCurrentProcess: false,
                           isElectron: electron, role: role, selectedTextSettable: settable,
                           requiresNativePayload: needsNative, isFigma: figma)
        }
        XCTAssertEqual(backend("ghbdtn"), .unicodeEvents)
        XCTAssertEqual(backend(String(repeating: "ghbdtn", count: 100)), .unicodeEvents)
        let oversizedGrapheme = "e" + String(repeating: "\u{301}", count: 25)
        for text in ["ghbdtn\nvbh", "ghbdtn\u{2028}vbh", oversizedGrapheme] {
            XCTAssertEqual(backend(text), .accessibilitySelectedText)
            XCTAssertEqual(backend(text, selected: false), .unicodeEvents)
            XCTAssertEqual(backend(text, settable: false), .unicodeEvents)
            XCTAssertEqual(backend(text, electron: true), .unicodeEvents)
            XCTAssertEqual(backend(text, figma: true), .unicodeEvents)
            XCTAssertEqual(backend(text, role: "AXTextField"), .unicodeEvents)
        }
        for text in ["ghbdtn\rvbh", "ghbdtn\tvbh", "ghbdtn\u{2029}vbh", "ghbdtn\u{FFFC}", ""] {
            XCTAssertEqual(backend(text), .unicodeEvents)
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
        XCTAssertFalse(replacement.confirmsCaret(document: original, range: selection.range, selectedText: selection.text))
        XCTAssertFalse(lifecycle.commitMutation())
        XCTAssertTrue(lifecycle.hasMutated)
        XCTAssertTrue(lifecycle.finish())
        XCTAssertFalse(lifecycle.commitMutation())
    }
}
