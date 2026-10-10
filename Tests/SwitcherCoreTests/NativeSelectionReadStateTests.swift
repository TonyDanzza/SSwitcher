import XCTest
@testable import SwitcherCore

final class NativeSelectionReadStateTests: XCTestCase {
    func testActualTextDoesNotWaitForAnotherServiceThatMayBeDropped() {
        for textFirst in [false, true] {
            var state = NativeSelectionReadState()
            if textFirst { XCTAssertTrue(state.receive("т")) } else { state.delivery(true) }
            XCTAssertNil(state.result)
            if textFirst { state.delivery(true) } else { XCTAssertTrue(state.receive("т")) }
            XCTAssertEqual(state.result, .selection("т"))
        }
    }
    func testNoReplyNeverBecomesAnEmptyBoundaryFromDeliveryAlone() {
        var state = NativeSelectionReadState()
        state.delivery(true)
        XCTAssertNil(state.result)
        state.receiveBarrier()
        XCTAssertEqual(state.result, .emptyNeedsVerification)
    }
    func testBarrierWithoutDeliveryCannotStartNavigation() {
        var state = NativeSelectionReadState()
        state.receiveBarrier()
        XCTAssertNil(state.result)
        state.delivery(true)
        XCTAssertEqual(state.result, .emptyNeedsVerification)
    }
    func testInvalidTextAndFailedDeliveryCannotBecomeEmptyBoundary() {
        var invalid = NativeSelectionReadState()
        XCTAssertFalse(invalid.receive(""))
        invalid.delivery(true)
        invalid.receiveBarrier()
        XCTAssertEqual(invalid.result, .rejected)
        var failed = NativeSelectionReadState()
        failed.delivery(false)
        failed.receiveBarrier()
        failed.delivery(true)
        XCTAssertEqual(failed.result, .rejected)
    }
    func testDuplicatePacketCannotReplaceTheBoundaryBeingChecked() {
        var state = NativeSelectionReadState()
        XCTAssertTrue(state.receive(" "))
        XCTAssertFalse(state.receive("x"))
        state.delivery(true)
        XCTAssertEqual(state.result, .selection(" "))
    }
}
