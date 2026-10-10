import XCTest
@testable import SwitcherCore

final class InputSourceObservationTests: XCTestCase {
    func testDelayedOwnNoticeDoesNotCancelTheNextDoubleShift() {
        var observation = InputSourceObservation(sourceID: "ABC")
        observation.confirmedSelection(requestedID: "Russian", actualID: "Russian", succeeded: true)
        var detector = DoubleShiftDetector()
        XCTAssertFalse(detector.shiftChanged(key: 56, anyShiftDown: true, otherModifierDown: false, time: 1))
        XCTAssertFalse(detector.shiftChanged(key: 56, anyShiftDown: false, otherModifierDown: false, time: 1.04))
        if observation.observe("Russian") { detector.cancelGesture() }
        XCTAssertFalse(detector.shiftChanged(key: 56, anyShiftDown: true, otherModifierDown: false, time: 1.14))
        XCTAssertTrue(detector.shiftChanged(key: 56, anyShiftDown: false, otherModifierDown: false, time: 1.18))
    }

    func testActualExternalSwitchStillCancelsTheGesture() {
        var observation = InputSourceObservation(sourceID: "ABC")
        observation.confirmedSelection(requestedID: "Russian", actualID: "Russian", succeeded: true)
        var detector = DoubleShiftDetector()
        _ = detector.shiftChanged(key: 56, anyShiftDown: true, otherModifierDown: false, time: 1)
        _ = detector.shiftChanged(key: 56, anyShiftDown: false, otherModifierDown: false, time: 1.04)
        if observation.observe("ABC") { detector.cancelGesture() }
        _ = detector.shiftChanged(key: 56, anyShiftDown: true, otherModifierDown: false, time: 1.14)
        XCTAssertFalse(detector.shiftChanged(key: 56, anyShiftDown: false, otherModifierDown: false, time: 1.18))
    }

    func testRepeatedNoticeDoesNotResetBurstProtection() {
        var observation = InputSourceObservation(sourceID: "ABC")
        XCTAssertTrue(observation.observe("Russian"))
        XCTAssertFalse(observation.observe("Russian"))
        var burst = ShiftBurstGate()
        XCTAssertTrue(burst.beginConversion())
        burst.complete(at: 1, unverified: false)
        if observation.observe("Russian") { burst.realInput() }
        XCTAssertFalse(burst.beginConversion())
    }

    func testFailedOrUnconfirmedSelectionCannotHideAnExternalChange() {
        for (succeeded, actual) in [(false, "Russian"), (true, "Other"), (true, nil)] {
            var observation = InputSourceObservation(sourceID: "ABC")
            observation.confirmedSelection(requestedID: "Russian", actualID: actual, succeeded: succeeded)
            XCTAssertTrue(observation.observe("Russian"))
        }
    }

    func testUnknownSourceFailsClosedAndDoesNotKeepAnOldIdentity() {
        var observation = InputSourceObservation(sourceID: "ABC")
        XCTAssertTrue(observation.observe(nil))
        XCTAssertTrue(observation.observe(""))
        XCTAssertTrue(observation.observe("ABC"))
        XCTAssertFalse(observation.observe("ABC"))
    }
}
