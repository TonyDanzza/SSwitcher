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
}
