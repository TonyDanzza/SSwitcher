import XCTest
@testable import SwitcherCore

final class ModifierReleaseReadinessTests: XCTestCase {
    func testRapidSecondShiftWaitsThenContinuesWithoutQueuingMutation() {
        var gate = ShiftBurstGate()
        var lifecycle = ConversionLifecycle()
        var modifiers = PhysicalModifierState()
        XCTAssertTrue(gate.beginConversion())
        XCTAssertTrue(lifecycle.commitMutation())
        modifiers.changed(key: 56, groupDown: true)
        gate.shiftChanged(down: true, at: 0.12)
        gate.request()
        let readiness = ModifierReleaseReadiness(start: 0.2, timeout: 1)
        XCTAssertEqual(readiness.decision(at: 0.3, inputUnchanged: true, modifiersClear: modifiers.observedModifiersClear), .wait(0.02))
        XCTAssertEqual(gate.state, .running)
        XCTAssertFalse(gate.pending)
        modifiers.changed(key: 56, groupDown: false)
        gate.shiftChanged(down: false, at: 0.72)
        XCTAssertEqual(readiness.decision(at: 0.72, inputUnchanged: true, modifiersClear: modifiers.observedModifiersClear), .ready)
        XCTAssertFalse(lifecycle.commitMutation())
        gate.complete(at: 0.8, unverified: false)
        XCTAssertEqual(gate.state, .draining)
        XCTAssertFalse(gate.consume(at: 2))
    }

    func testChangedInputStopsImmediatelyEvenWhenModifierIsReleased() {
        let readiness = ModifierReleaseReadiness(start: 0, timeout: 1)
        for clear in [false, true] {
            XCTAssertEqual(readiness.decision(at: 0.1, inputUnchanged: false, modifiersClear: clear), .cancelled)
        }
    }

    func testPollingCannotExtendHeldShiftDeadlineOrAuthorizeLateRelease() {
        let readiness = ModifierReleaseReadiness(start: 10, timeout: 1)
        for n in 0..<50 {
            guard case .wait(let delay) = readiness.decision(at: 10 + Double(n) * 0.02, inputUnchanged: true, modifiersClear: false) else {
                XCTFail("A held modifier must wait inside the original deadline"); return
            }
            XCTAssertGreaterThan(delay, 0)
            XCTAssertLessThanOrEqual(delay, 0.02)
        }
        XCTAssertEqual(readiness.decision(at: 11, inputUnchanged: true, modifiersClear: false), .timedOut)
        XCTAssertEqual(readiness.decision(at: 11.1, inputUnchanged: true, modifiersClear: true), .timedOut)
        XCTAssertEqual(readiness.expiresAt, 11)
    }
}
