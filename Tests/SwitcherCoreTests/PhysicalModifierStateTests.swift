import XCTest
@testable import SwitcherCore

final class PhysicalModifierStateTests: XCTestCase {
    func testActualCommandTransitionBlocksEvenIfHardwareSnapshotIsLate() {
        var state = PhysicalModifierState()
        state.changed(key: 55, groupDown: true)
        XCTAssertFalse(state.permitsMutation(hardwareKeysDown: []))
        state.changed(key: 55, groupDown: false)
        XCTAssertTrue(state.permitsMutation(hardwareKeysDown: []))
    }
    func testHeldModifierAtMonitorStartupBlocksWithoutObservedTransition() {
        let state = PhysicalModifierState()
        for key in PhysicalModifierState.unsafeKeys { XCTAssertFalse(state.permitsMutation(hardwareKeysDown: [key])) }
    }
    func testBothShiftReleaseInterleavingDoesNotLoseTheRemainingHeldKey() {
        var state = PhysicalModifierState()
        state.changed(key: 56, groupDown: true)
        state.changed(key: 60, groupDown: true)
        state.changed(key: 56, groupDown: true) // left up, right still held
        XCTAssertTrue(state.holds(any: [56, 60]))
        XCTAssertFalse(state.permitsMutation(hardwareKeysDown: []))
        state.changed(key: 60, groupDown: false)
        XCTAssertFalse(state.holds(any: [56, 60]))
        XCTAssertTrue(state.permitsMutation(hardwareKeysDown: []))
    }
    func testStickyAggregateShiftFlagDoesNotTurnReleaseIntoNewPress() {
        var state = PhysicalModifierState()
        state.changed(key: 56, groupDown: true)
        state.changed(key: 56, groupDown: true) // aggregate flag still set on key-up
        XCTAssertFalse(state.holds(any: [56, 60]))
        XCTAssertTrue(state.permitsMutation(hardwareKeysDown: []))
    }
    func testSyntheticEventsStillInHardwareQueueDoNotCancelGuardedContinuation() {
        let state = PhysicalModifierState()
        XCTAssertTrue(state.permitsMutation(hardwareKeysDown: [])) // initial guard
        // Once our arrow batch is posted, its pending Shift may be reflected
        // by Quartz. It must still reject a NEW mutation, but an unchanged
        // attempt can continue based on unmarked physical transitions.
        XCTAssertFalse(state.permitsMutation(hardwareKeysDown: [56]))
        XCTAssertTrue(state.observedModifiersClear)
    }
    func testRealModifierTransitionDuringSyntheticRestoreBlocksContinuation() {
        for key in PhysicalModifierState.unsafeKeys {
            var state = PhysicalModifierState()
            XCTAssertTrue(state.permitsMutation(hardwareKeysDown: []))
            state.changed(key: key, groupDown: true)
            XCTAssertFalse(state.observedModifiersClear)
            XCTAssertFalse(state.permitsMutation(hardwareKeysDown: []))
            state.changed(key: key, groupDown: false)
            XCTAssertTrue(state.observedModifiersClear)
        }
    }
    func testReleaseOfKeyPressedUnseenDoesNotStickWhileOtherSideIsHeld() {
        // Both Options held through the cleaning lock; it ends, then the left
        // one is released while the right one is still down.
        var state = PhysicalModifierState()
        state.changed(key: 58, groupDown: true, deviceFlags: 0x80000 | 0x40)
        XCTAssertFalse(state.holds(any: [58]))
        state.changed(key: 61, groupDown: false, deviceFlags: 0)
        XCTAssertTrue(state.observedModifiersClear)
    }
    func testPressWithOtherSideHeldIsStillSeen() {
        var state = PhysicalModifierState()
        state.changed(key: 55, groupDown: true, deviceFlags: 0x100000 | 0x08)
        state.changed(key: 54, groupDown: true, deviceFlags: 0x100000 | 0x08 | 0x10)
        XCTAssertTrue(state.holds(any: [54]) && state.holds(any: [55]))
    }
    func testKeyboardWithoutDeviceBitsKeepsAggregateBehaviour() {
        var state = PhysicalModifierState()
        state.changed(key: 58, groupDown: true, deviceFlags: 0x80000)
        XCTAssertTrue(state.holds(any: [58]))
    }
    func testKeyPressWithoutTheGroupFlagClearsAStuckModifier() {
        var state = PhysicalModifierState()
        state.changed(key: 55, groupDown: true)
        state.released(key: 55)
        XCTAssertTrue(state.observedModifiersClear)
    }
}
