import ApplicationServices
import XCTest
@testable import SwitcherCore

final class AccessibilityValueTests: XCTestCase {
    func testApplicationRolePreparationAcceptsOnlyTypedApplicationRole() {
        XCTAssertTrue(AccessibilityValue.isApplicationRole(kAXApplicationRole as CFString, error: .success))
        let rejected: [CFTypeRef?] = [nil, kCFNull, kCFBooleanTrue, kAXWindowRole as CFString,
                                     kAXTextAreaRole as CFString, "AXApplication\n" as CFString,
                                     [kAXApplicationRole] as CFArray]
        for value in rejected {
            XCTAssertFalse(AccessibilityValue.isApplicationRole(value, error: .success))
        }
    }

    func testApplicationRoleCannotHideFailedOrEmbeddedAXReply() throws {
        for error in [AXError.attributeUnsupported, .cannotComplete, .invalidUIElement, .apiDisabled, .noValue] {
            XCTAssertFalse(AccessibilityValue.isApplicationRole(kAXApplicationRole as CFString, error: error))
            var error = error
            let embedded = try XCTUnwrap(AXValueCreate(.axError, &error))
            XCTAssertFalse(AccessibilityValue.isApplicationRole(embedded, error: .success))
        }
    }

    func testFocusedElementReplyRejectsMissingAndNonElementValues() {
        let candidates: [(CFTypeRef?, AccessibilityElementReply.Status)] = [
            (nil, .absent), (kCFNull, .absent),
            ("not an element" as CFString, .malformed), (kCFBooleanTrue, .malformed)
        ]
        for (value, expected) in candidates {
            let reply = AccessibilityElementReply(error: .success, value: value)
            XCTAssertNil(reply.element)
            XCTAssertEqual(reply.status, expected)
            XCTAssertNil(reply.error)
        }
        // Constructing a reference sends no query. A collection of references
        // cannot be substituted for the API's actual focused-element reply.
        let node = AXUIElementCreateSystemWide()
        let collection = AccessibilityElementReply(error: .success, value: [node] as CFArray)
        XCTAssertNil(collection.element)
        XCTAssertEqual(collection.status, .malformed)
    }

    func testFailedFocusedElementQueryCannotAuthorizeReturnedReference() {
        let node = AXUIElementCreateSystemWide()
        for error in [AXError.cannotComplete, .invalidUIElement, .attributeUnsupported, .noValue, .apiDisabled] {
            let reply = AccessibilityElementReply(error: error, value: node)
            XCTAssertNil(reply.element)
            XCTAssertEqual(reply.status, .failed)
            XCTAssertEqual(reply.error, error)
        }
    }

    func testFocusedElementReplyAcceptsOnlyTypedSuccessAndRejectsEmbeddedError() throws {
        let node = AXUIElementCreateSystemWide()
        let valid = AccessibilityElementReply(error: .success, value: node)
        XCTAssertTrue(CFEqual(try XCTUnwrap(valid.element), node))
        XCTAssertEqual(valid.status, .available)
        XCTAssertNil(valid.error)
        var error = AXError.cannotComplete
        let embedded = try XCTUnwrap(AXValueCreate(.axError, &error))
        let invalid = AccessibilityElementReply(error: .success, value: embedded)
        XCTAssertNil(invalid.element)
        XCTAssertEqual(invalid.status, .failed)
        XCTAssertEqual(invalid.error, error)
    }

    func testUnsupportedBatchSlotsDoNotHideUsableRangeOrValue() throws {
        var range = CFRange(location: 5, length: 0)
        var error = AXError.attributeUnsupported
        let slots: [CFTypeRef] = [kCFNull, try XCTUnwrap(AXValueCreate(.axError, &error)),
                                  try XCTUnwrap(AXValueCreate(.cfRange, &range)), "text" as CFString]
        XCTAssertNil(AccessibilityValue.usable(slots[0]))
        XCTAssertNil(AccessibilityValue.usable(slots[1]))
        XCTAssertEqual(AccessibilityValue.range(slots[2])?.location, 5)
        XCTAssertEqual(AccessibilityValue.usable(slots[3]) as? String, "text")
    }
    func testMalformedRangesAndWrongAXValueTypeFailClosed() throws {
        for candidate in [CFRange(location: -1, length: 2), CFRange(location: 0, length: -1)] {
            var candidate = candidate
            XCTAssertNil(AccessibilityValue.range(try XCTUnwrap(AXValueCreate(.cfRange, &candidate))))
        }
        var rectangle = CGRect.zero
        XCTAssertNil(AccessibilityValue.range(try XCTUnwrap(AXValueCreate(.cgRect, &rectangle))))
        XCTAssertNil(AccessibilityValue.range("not a range" as CFString))
    }
    func testRangeCollectionPreservesOffsetsAndRejectsMalformedMembers() throws {
        var first = CFRange(location: 5, length: 0)
        var second = CFRange(location: 9, length: 3)
        let a = try XCTUnwrap(AXValueCreate(.cfRange, &first))
        let b = try XCTUnwrap(AXValueCreate(.cfRange, &second))
        let decoded = try XCTUnwrap(AccessibilityValue.ranges([a, b] as CFArray))
        XCTAssertEqual(decoded.map { $0.location }, [5, 9])
        XCTAssertEqual(decoded.map { $0.length }, [0, 3])
        XCTAssertEqual(AccessibilityValue.ranges([] as CFArray)?.count, 0)
        XCTAssertNil(AccessibilityValue.ranges([a, kCFNull!] as CFArray))
        XCTAssertNil(AccessibilityValue.ranges([a, "wrong" as CFString] as CFArray))
        XCTAssertNil(AccessibilityValue.ranges(a))
    }

    func testBusyAndUnsupportedBatchErrorsRemainDistinct() throws {
        for candidate in [AXError.cannotComplete, AXError.attributeUnsupported, AXError.noValue, AXError.invalidUIElement] {
            var candidate = candidate
            let raw = try XCTUnwrap(AXValueCreate(.axError, &candidate))
            XCTAssertEqual(AccessibilityValue.error(raw), candidate)
            XCTAssertNil(AccessibilityValue.usable(raw))
        }
        XCTAssertNil(AccessibilityValue.error(kCFNull))
        XCTAssertNil(AccessibilityValue.error("not an error" as CFString))
    }

    func testOnlyOptionalDescriptionCanOmitGenericFailure() {
        XCTAssertTrue(AccessibilityValue.isAbsentAttributeError(.failure, attribute: kAXDescriptionAttribute))
        for name in [kAXValueAttribute, kAXSelectedTextRangeAttribute, kAXSelectedTextAttribute,
                     kAXSelectedTextRangesAttribute, kAXSubroleAttribute, kAXRoleAttribute, kAXParentAttribute] {
            XCTAssertFalse(AccessibilityValue.isAbsentAttributeError(.failure, attribute: name))
        }
        for error in [AXError.cannotComplete, .invalidUIElement, .notImplemented, .apiDisabled, .success] {
            XCTAssertFalse(AccessibilityValue.isAbsentAttributeError(error, attribute: kAXDescriptionAttribute))
        }
        XCTAssertTrue(AccessibilityValue.isAbsentAttributeError(.attributeUnsupported, attribute: kAXDescriptionAttribute))
        XCTAssertTrue(AccessibilityValue.isAbsentAttributeError(.noValue, attribute: kAXDescriptionAttribute))
    }

    func testFailedDescriptionDoesNotAuthorizeCanvasOrHideNativeSelection() throws {
        var failure = AXError.failure
        let raw = try XCTUnwrap(AXValueCreate(.axError, &failure))
        let error = try XCTUnwrap(AccessibilityValue.error(raw))
        XCTAssertTrue(AccessibilityValue.isAbsentAttributeError(error, attribute: kAXDescriptionAttribute))
        let description = AccessibilityValue.usable(raw) as? String
        XCTAssertNil(description)
        XCTAssertTrue(AccessibilityEditorPolicy.permitsEditing(isFigma: false, role: "AXTextArea", description: description))
        XCTAssertFalse(AccessibilityEditorPolicy.permitsEditing(isFigma: true, role: "AXTextArea", description: description))
        XCTAssertFalse(AccessibilityEditorPolicy.isFigmaCanvas(isFigma: true, role: "AXTextArea", description: description))
        XCTAssertNotNil(AccessibilitySelectionPlan(document: "ghbdtn", range: NSRange(location: 0, length: 6), selectedText: "ghbdtn"))
    }

}
