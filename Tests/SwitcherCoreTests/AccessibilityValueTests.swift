import ApplicationServices
import XCTest
@testable import SwitcherCore

final class AccessibilityValueTests: XCTestCase {
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
}
