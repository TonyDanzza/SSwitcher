import XCTest
@testable import SwitcherCore

final class NativeServiceDispatchStateTests: XCTestCase {
    func testBothReceiptOrdersRequireActionAndPublication() {
        for publicationFirst in [false, true] {
            var state = NativeServiceDispatchState()
            if publicationFirst { state.published(true) } else { state.pressed(true) }
            XCTAssertNil(state.completed)
            if publicationFirst { state.pressed(true) } else { state.published(true) }
            XCTAssertEqual(state.completed, .submitted)
        }
    }
    func testFailedActionAfterPublicationRemainsUnverified() {
        var state = NativeServiceDispatchState()
        state.published(true)
        state.pressed(false)
        XCTAssertEqual(state.completed, .unverified)
        XCTAssertEqual(state.stopped(cancelled: true), .unverified)
    }
    func testMissingProviderCannotBecomeSuccessFromAcceptedAction() {
        var state = NativeServiceDispatchState()
        state.pressed(true)
        XCTAssertNil(state.completed)
        XCTAssertEqual(state.stopped(cancelled: false), .unavailable)
    }
    func testRefusalAndCancellationBeforePublicationDoNotClaimReplacement() {
        var state = NativeServiceDispatchState()
        XCTAssertEqual(state.stopped(cancelled: true), .cancelled)
        state.published(false)
        state.pressed(true)
        XCTAssertEqual(state.completed, .unavailable)
    }
    func testLateDuplicateReceiptsCannotRewriteAnUncertainOutcome() {
        var state = NativeServiceDispatchState()
        state.published(true)
        state.pressed(false)
        state.pressed(true)
        state.published(false)
        XCTAssertEqual(state.completed, .unverified)
    }
}
