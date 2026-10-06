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
}
