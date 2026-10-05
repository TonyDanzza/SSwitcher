import XCTest
@testable import SwitcherCore

final class DoubleShiftDetectorTests: XCTestCase {
    private var detector = DoubleShiftDetector()

    private func press(_ time: Double, key: UInt16 = 56, other: Bool = false) {
        XCTAssertFalse(detector.shiftChanged(key: key, anyShiftDown: true, otherModifierDown: other, time: time))
    }

    private func release(_ time: Double, key: UInt16 = 56, other: Bool = false) -> Bool {
        detector.shiftChanged(key: key, anyShiftDown: false, otherModifierDown: other, time: time)
    }

    func testLeftDoubleTap() {
        press(0); XCTAssertFalse(release(0.05))
        press(0.12); XCTAssertTrue(release(0.18))
    }

    func testRightDoubleTap() {
        press(0, key: 60); XCTAssertFalse(release(0.05, key: 60))
        press(0.12, key: 60); XCTAssertTrue(release(0.18, key: 60))
    }

    func testSlowTapsDoNotSwitch() {
        press(0); XCTAssertFalse(release(0.05))
        press(0.5); XCTAssertFalse(release(0.55))
    }

    func testHeldShiftDoesNotCount() {
        press(0); XCTAssertFalse(release(1))
        press(1.05); XCTAssertFalse(release(1.1))
    }

    func testTypingWithShiftCancels() {
        press(0); detector.cancelGesture(); XCTAssertFalse(release(0.05))
        press(0.1); XCTAssertFalse(release(0.15))
    }

    func testInterveningKeyOrClickCancels() {
        press(0); XCTAssertFalse(release(0.05)); detector.cancelGesture()
        press(0.1); XCTAssertFalse(release(0.15))
    }

    func testShortcutModifierCancels() {
        press(0, other: true); XCTAssertFalse(release(0.05, other: true))
        press(0.1); XCTAssertFalse(release(0.15))
    }

    func testDifferentShiftKeysDoNotPair() {
        press(0); XCTAssertFalse(release(0.05))
        press(0.1, key: 60); XCTAssertFalse(release(0.15, key: 60))
    }

    func testBothShiftsHeldDoNotCount() {
        press(0); press(0.02, key: 60)
        press(0.04) // left release while right remains down
        XCTAssertFalse(release(0.06, key: 60))
        press(0.1); XCTAssertFalse(release(0.15))
    }

    func testTripleTapSwitchesOnlyOnce() {
        press(0); XCTAssertFalse(release(0.03))
        press(0.06); XCTAssertTrue(release(0.09))
        press(0.12); XCTAssertFalse(release(0.15))
    }

    func testResetDiscardsPendingTap() {
        press(0); XCTAssertFalse(release(0.05)); detector.reset()
        press(0.1); XCTAssertFalse(release(0.15))
    }

    func testUnmatchedReleaseDoesNotCount() {
        XCTAssertFalse(release(0))
        press(0.05); XCTAssertFalse(release(0.1))
    }
}
