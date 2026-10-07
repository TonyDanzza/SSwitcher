import XCTest
@testable import SwitcherCore

final class SpotlightSearchScopeTests: XCTestCase {
    func testOnlyActualCampoSearchDialogProvidesOverlayAuthority() {
        func verified(bundle: String = "com.apple.campo", role: String? = "AXTextField", subrole: String? = "AXSearchField",
                      identifier: String? = "SpotlightSearchField", windowRole: String? = "AXWindow",
                      windowSubrole: String? = "AXSystemDialog", secure: Bool = false) -> Bool {
            SpotlightSearchScope.isVerified(bundleID: bundle, role: role, subrole: subrole, identifier: identifier,
                                            windowRole: windowRole, windowSubrole: windowSubrole, isSecure: secure)
        }
        XCTAssertTrue(verified())
        XCTAssertFalse(verified(bundle: "com.apple.Spotlight"))
        XCTAssertFalse(verified(bundle: "other.app"))
        XCTAssertFalse(verified(role: "AXTextArea"))
        XCTAssertFalse(verified(role: "AXStaticText"))
        XCTAssertFalse(verified(subrole: "AXSecureTextField"))
        XCTAssertFalse(verified(identifier: nil))
        XCTAssertFalse(verified(identifier: "SiriInputField"))
        XCTAssertFalse(verified(windowRole: "AXGroup"))
        XCTAssertFalse(verified(windowSubrole: "AXStandardWindow"))
        XCTAssertFalse(verified(secure: true))
    }

    func testOrdinaryTargetMismatchRemainsRejected() {
        XCTAssertTrue(SpotlightSearchScope.permitsTarget(foregroundPID: 1240, targetPID: 1240, verifiedOverlay: false))
        XCTAssertFalse(SpotlightSearchScope.permitsTarget(foregroundPID: 1240, targetPID: 1252, verifiedOverlay: false))
        XCTAssertTrue(SpotlightSearchScope.permitsTarget(foregroundPID: 1240, targetPID: 1252, verifiedOverlay: true))
        XCTAssertFalse(SpotlightSearchScope.permitsTarget(foregroundPID: 0, targetPID: 1252, verifiedOverlay: true))
        XCTAssertFalse(SpotlightSearchScope.permitsTarget(foregroundPID: 1240, targetPID: 0, verifiedOverlay: true))
    }

    func testSameBackgroundDoesNotAuthorizeLostOrRecreatedOverlayFocus() {
        func matches(pid: Int32 = 1252, field: Bool = true, window: Bool = true, identity: Bool = true) -> Bool {
            SpotlightSearchScope.matchesFocus(expectedPID: 1252, actualPID: pid, sameField: field,
                                              sameWindow: window, verifiedIdentity: identity)
        }
        XCTAssertTrue(matches())
        XCTAssertFalse(matches(pid: 1240))
        XCTAssertFalse(matches(field: false))
        XCTAssertFalse(matches(window: false))
        XCTAssertFalse(matches(identity: false))
    }

    func testSearchScopeRefusesLineBreaksControlsAttachmentsAndMissingText() {
        for value in ["", "ghbdtn ghbdtn", "привет", "🙂 e\u{301}"] { XCTAssertTrue(SpotlightSearchScope.acceptsDocument(value)) }
        for value in ["ghbdtn\n", "a\r", "a\t", "a\u{2028}", "a\u{2029}", "a\u{FFFC}"] {
            XCTAssertFalse(SpotlightSearchScope.acceptsDocument(value))
            XCTAssertFalse(TextReplacementBackend.acceptsNativeText(value, permitsLineBreaks: false))
        }
        XCTAssertFalse(SpotlightSearchScope.acceptsDocument(nil))
        XCTAssertFalse(TextReplacementBackend.acceptsNativeText("", permitsLineBreaks: false))
    }

    func testLateSuccessfulFocusValidationCannotResumeCancelledAttempt() {
        var lifecycle = ConversionLifecycle()
        var posts = 0
        let authorized = SpotlightSearchScope.matchesFocus(expectedPID: 1252, actualPID: 1252,
                                                           sameField: true, sameWindow: true, verifiedIdentity: true)
        let callback = {
            guard authorized, lifecycle.canContinue else { return }
            posts += 1
        }
        _ = lifecycle.cancel()
        callback()
        XCTAssertEqual(posts, 0)
        XCTAssertFalse(lifecycle.commitMutation())
    }

    func testOverlayRequiresNativeRangeCapabilityWhileOrdinaryEditorsRemainUnchanged() {
        XCTAssertTrue(SpotlightSearchScope.hasRequiredNativeRangeCapability(verifiedOverlay: true, nativeRangeSettable: true))
        XCTAssertFalse(SpotlightSearchScope.hasRequiredNativeRangeCapability(verifiedOverlay: true, nativeRangeSettable: false))
        XCTAssertTrue(SpotlightSearchScope.hasRequiredNativeRangeCapability(verifiedOverlay: false, nativeRangeSettable: false))
    }

    func testNativeQueryPlanReplacesOnlyTheWordEndingAtTheCaret() throws {
        let query = "ghbdtn ghbdtn"
        let first = try XCTUnwrap(SpotlightSearchScope.wordReplacement(document: query,
            caret: NSRange(location: 6, length: 0), replacement: "привет"))
        XCTAssertEqual(first.document, "привет ghbdtn")
        XCTAssertEqual(first.caret, NSRange(location: 6, length: 0))
        let last = try XCTUnwrap(SpotlightSearchScope.wordReplacement(document: query,
            caret: NSRange(location: 13, length: 0), replacement: "привет"))
        XCTAssertEqual(last.document, "ghbdtn привет")
        XCTAssertEqual(last.caret, NSRange(location: 13, length: 0))
        for caret in [NSRange(location: 0, length: 0), NSRange(location: 3, length: 0),
                      NSRange(location: 7, length: 0), NSRange(location: 6, length: 1), NSRange(location: 14, length: 0)] {
            XCTAssertNil(SpotlightSearchScope.wordReplacement(document: query, caret: caret, replacement: "привет"))
        }
        XCTAssertNil(SpotlightSearchScope.wordReplacement(document: "ghbdtn\n", caret: NSRange(location: 6, length: 0), replacement: "привет"))
        XCTAssertNil(SpotlightSearchScope.wordReplacement(document: query, caret: NSRange(location: 6, length: 0), replacement: "прив\nт"))
    }

    func testQueryCaretCorrectionRequiresExactResultAndEmptyValidCaret() throws {
        let result = try XCTUnwrap(SpotlightSearchScope.wordReplacement(document: "ghbdtn ghbdtn",
            caret: NSRange(location: 6, length: 0), replacement: "привет"))
        let relocated = NSRange(location: 13, length: 0)
        XCTAssertTrue(AccessibilitySelectionPlan.confirmsCaret(document: result.document, range: relocated, selectedText: "",
            expectedDocument: result.document, expectedCaret: relocated))
        XCTAssertFalse(AccessibilitySelectionPlan.confirmsCaret(document: result.document, range: relocated, selectedText: "",
            expectedDocument: result.document, expectedCaret: result.caret))
        for (document, range, selected) in [("gпривет ghbdtn", relocated, ""),
                                            (result.document, NSRange(location: 13, length: 1), "x"),
                                            (result.document, NSRange(location: 14, length: 0), "")] {
            XCTAssertFalse(AccessibilitySelectionPlan.confirmsCaret(document: document, range: range, selectedText: selected,
                expectedDocument: result.document, expectedCaret: range))
        }
    }
}
