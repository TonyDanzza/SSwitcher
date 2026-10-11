import XCTest
@testable import SwitcherCore

final class MaxConversionRouteTests: XCTestCase {
    func testTypedWordIsRetypedRegardlessOfSelectionState() {
        for empty in [false, true] {
            XCTAssertEqual(MaxConversionRoute.decide(candidate: .word("ghbdtn", boundedStart: true), selectionKnownEmpty: empty),
                           .retype(word: "ghbdtn", boundedStart: true))
            XCTAssertEqual(MaxConversionRoute.decide(candidate: .word("ntcn", boundedStart: false), selectionKnownEmpty: empty),
                           .retype(word: "ntcn", boundedStart: false))
        }
    }

    func testUnknownWordUsesDirectServiceOnlyWithoutPossibleSelection() {
        for candidate in [TypedWordTracker.Candidate.unknown, .afterSpace] {
            XCTAssertEqual(MaxConversionRoute.decide(candidate: candidate, selectionKnownEmpty: true), .directService)
            XCTAssertEqual(MaxConversionRoute.decide(candidate: candidate, selectionKnownEmpty: false), .fullService)
        }
    }

    func testRetypeFallbackFollowsSelectionState() {
        XCTAssertEqual(MaxConversionRoute.service(selectionKnownEmpty: true), .directService)
        XCTAssertEqual(MaxConversionRoute.service(selectionKnownEmpty: false), .fullService)
    }

    func testEarlyShieldOnlyForDirectRequest() {
        XCTAssertTrue(MaxConversionRoute.directService.startsEarlyShield)
        XCTAssertFalse(MaxConversionRoute.fullService.startsEarlyShield)
        XCTAssertFalse(MaxConversionRoute.retype(word: "a", boundedStart: false).startsEarlyShield)
    }

    func testTrackerStateMapsToRoutes() {
        var tracker = TypedWordTracker()
        XCTAssertEqual(MaxConversionRoute.decide(candidate: tracker.candidate, selectionKnownEmpty: true), .directService)
        tracker.typed("ghbdtn")
        XCTAssertEqual(MaxConversionRoute.decide(candidate: tracker.candidate, selectionKnownEmpty: true),
                       .retype(word: "ghbdtn", boundedStart: false))
        tracker.typed(" ")
        XCTAssertEqual(MaxConversionRoute.decide(candidate: tracker.candidate, selectionKnownEmpty: false), .fullService)
    }
}
