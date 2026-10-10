import XCTest
@testable import SwitcherCore

final class NativeMutationGateTests: XCTestCase {
    func testUnknownWriteBlocksAnotherGestureUntilRealIntervention() {
        var gate = NativeMutationGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        gate.willWrite()
        gate.finish(confirmed: false)
        XCTAssertEqual(gate.state, .blocked)
        XCTAssertFalse(gate.begin()) // repeated bare Shift/source reconciliation
        gate.realIntervention()
        XCTAssertTrue(gate.begin())
    }

    func testRefusalBeforeWriteAndConfirmedWriteDoNotLeaveBarrier() {
        var gate = NativeMutationGate()
        XCTAssertTrue(gate.begin())
        gate.finish(confirmed: false)
        XCTAssertEqual(gate.state, .idle)
        XCTAssertTrue(gate.begin())
        gate.willWrite()
        gate.finish(confirmed: true)
        XCTAssertEqual(gate.state, .idle)
    }

    func testRealInputDuringIssuedAttemptStillCancelsButAllowsFreshGesture() {
        var gate = NativeMutationGate()
        XCTAssertTrue(gate.begin())
        gate.willWrite()
        gate.realIntervention()
        XCTAssertFalse(gate.begin()) // busy through completion/acknowledgement
        gate.finish(confirmed: false)
        XCTAssertEqual(gate.state, .idle)
        XCTAssertTrue(gate.begin())
    }
}
