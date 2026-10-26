import XCTest
@testable import SwitcherCore

final class KeyboardLockUnlockTests: XCTestCase {
    typealias D = KeyboardLockUnlock.Device

    func testHoldingBothOptionCommandPairsUnlocksAfterFiveSeconds() {
        var lock = KeyboardLockUnlock()
        lock.modifiersChanged(deviceFlags: D.leftOption | D.leftCommand, fnDown: false, at: 0)
        XCTAssertFalse(lock.isHoldingChord)
        lock.modifiersChanged(deviceFlags: KeyboardLockUnlock.chord | 0x180000, fnDown: false, at: 0.1)
        XCTAssertTrue(lock.isHoldingChord)
        XCTAssertEqual(lock.unlockTime ?? 0, 5.1, accuracy: 0.001)
        XCTAssertFalse(lock.shouldUnlock(at: 5))
        XCTAssertEqual(lock.progress(at: 2.6), 0.5, accuracy: 0.001)
        XCTAssertTrue(lock.shouldUnlock(at: 5.1))
    }

    func testAnyOtherKeyOrModifierCancelsTheHold() {
        var lock = KeyboardLockUnlock()
        lock.modifiersChanged(deviceFlags: KeyboardLockUnlock.chord, fnDown: false, at: 0)
        lock.keyChanged(code: 49, down: true, at: 0.5) // space: a cloth on the bottom row
        XCTAssertFalse(lock.shouldUnlock(at: 2))
        lock.keyChanged(code: 49, down: false, at: 2)
        XCTAssertFalse(lock.shouldUnlock(at: 6.9))
        XCTAssertTrue(lock.shouldUnlock(at: 7))
        lock.modifiersChanged(deviceFlags: KeyboardLockUnlock.chord | D.leftShift, fnDown: false, at: 7)
        XCTAssertFalse(lock.isHoldingChord)
        lock.modifiersChanged(deviceFlags: KeyboardLockUnlock.chord, fnDown: true, at: 8)
        XCTAssertFalse(lock.isHoldingChord)
    }

    func testOneSideIsNotEnough() {
        var lock = KeyboardLockUnlock()
        lock.modifiersChanged(deviceFlags: D.leftCommand | D.rightCommand | D.leftOption, fnDown: false, at: 0)
        XCTAssertFalse(lock.shouldUnlock(at: 5))
    }
}
