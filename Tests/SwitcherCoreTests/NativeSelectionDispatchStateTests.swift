import XCTest
@testable import SwitcherCore

final class NativeSelectionDispatchStateTests: XCTestCase {
    func testNoCallbackAndDeliveryAloneNeverAuthorizeWordNavigation() {
        var state = NativeSelectionDispatchState()
        state.delivery(true)
        XCTAssertNil(state.result)
        state.receiveBarrier()
        XCTAssertEqual(state.result, .empty)
    }
    func testConvertedSelectionDoesNotWaitForAnotherServiceAfterCommit() {
        for publicationFirst in [false, true] {
            var state = NativeSelectionDispatchState()
            if publicationFirst { state.published(true) } else { state.delivery(true) }
            XCTAssertNil(state.result)
            if publicationFirst { state.delivery(true) } else { state.published(true) }
            XCTAssertEqual(state.result, .submitted)
            state.receiveBarrier()
            XCTAssertEqual(state.result, .submitted)
        }
    }
    func testBarrierAloneDoesNotAuthorizeWordNavigation() {
        var state = NativeSelectionDispatchState()
        state.receiveBarrier()
        XCTAssertNil(state.result)
    }
    func testRefusedSelectionCannotFallThroughAndModifyAnotherScope() {
        var state = NativeSelectionDispatchState()
        state.published(false)
        state.delivery(true)
        state.receiveBarrier()
        state.published(true)
        XCTAssertEqual(state.result, .rejected)
    }
    func testFailedDeliveryCannotFallThroughEvenAfterBarrier() {
        var state = NativeSelectionDispatchState()
        state.delivery(false)
        state.receiveBarrier()
        state.delivery(true)
        XCTAssertEqual(state.result, .rejected)
    }
}
