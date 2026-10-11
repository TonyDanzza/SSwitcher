import XCTest
@testable import SwitcherCore

final class AccessibilityEditorPolicyTests: XCTestCase {
    func testFigmaOutsideEditingMirrorIsRejectedEvenWithTextAreaRole() {
        for description in [nil, ""] {
            XCTAssertFalse(AccessibilityEditorPolicy.permitsEditing(isFigma: true, role: "AXTextArea", description: description))
            XCTAssertFalse(AccessibilityEditorPolicy.isFigmaCanvas(isFigma: true, role: "AXTextArea", description: description))
        }
    }

    func testOnlyActualCanvasEditorUsesKeyboardSelectionPolicy() {
        XCTAssertTrue(AccessibilityEditorPolicy.permitsEditing(isFigma: true, role: "AXTextArea", description: "Text"))
        XCTAssertTrue(AccessibilityEditorPolicy.isFigmaCanvas(isFigma: true, role: "AXTextArea", description: "Text"))
        for (role, description) in [("AXTextArea", "Comment"), ("AXTextField", "Text"), ("AXComboBox", "Search")] {
            XCTAssertTrue(AccessibilityEditorPolicy.permitsEditing(isFigma: true, role: role, description: description))
            XCTAssertFalse(AccessibilityEditorPolicy.isFigmaCanvas(isFigma: true, role: role, description: description))
        }
        XCTAssertFalse(AccessibilityEditorPolicy.isFigmaCanvas(isFigma: false, role: "AXTextArea", description: "Text"))
    }

    func testReadOnlyRolesCannotBecomeEditorsFromSelectionEvidenceAlone() {
        for role in [nil, "AXStaticText", "AXCell", "AXDocument", "AXGroup"] {
            XCTAssertFalse(AccessibilityEditorPolicy.permitsEditing(isFigma: false, role: role, description: "Text"))
        }
        XCTAssertTrue(AccessibilityEditorPolicy.permitsEditing(isFigma: false, role: "AXTextArea", description: nil))
    }

    func testCanvasFocusPreparationOnlyForContainerFocusWithoutText() {
        // Measured in Pages 15.4: focus AXScrollArea > AXSplitGroup > AXWindow > AXApplication.
        XCTAssertTrue(AccessibilityEditorPolicy.needsCanvasFocusPreparation(focusRole: "AXScrollArea", textRangeFound: false))
        XCTAssertTrue(AccessibilityEditorPolicy.needsCanvasFocusPreparation(focusRole: "AXLayoutArea", textRangeFound: false))
        XCTAssertFalse(AccessibilityEditorPolicy.needsCanvasFocusPreparation(focusRole: "AXScrollArea", textRangeFound: true))
        for role in [nil, "AXButton", "AXWindow", "AXApplication", "AXGroup", "AXTextArea", "AXWebArea"] {
            XCTAssertFalse(AccessibilityEditorPolicy.needsCanvasFocusPreparation(focusRole: role, textRangeFound: false))
        }
    }

    func testOnlyFocusedTextElementsWithRangeAreCanvasCandidates() {
        XCTAssertTrue(AccessibilityEditorPolicy.isFocusedTextCandidate(role: "AXTextArea", focused: true, hasRange: true))
        XCTAssertTrue(AccessibilityEditorPolicy.isFocusedTextCandidate(role: "AXTextField", focused: true, hasRange: true))
        XCTAssertFalse(AccessibilityEditorPolicy.isFocusedTextCandidate(role: "AXTextArea", focused: false, hasRange: true))
        XCTAssertFalse(AccessibilityEditorPolicy.isFocusedTextCandidate(role: "AXTextArea", focused: true, hasRange: false))
        for role in [nil, "AXStaticText", "AXScrollArea", "AXComboBox"] {
            XCTAssertFalse(AccessibilityEditorPolicy.isFocusedTextCandidate(role: role, focused: true, hasRange: true))
        }
    }
}
