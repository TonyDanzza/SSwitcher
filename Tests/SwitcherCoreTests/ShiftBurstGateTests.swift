import XCTest
@testable import SwitcherCore

final class ShiftBurstGateTests: XCTestCase {
    func testStormProducesOnlyOneConversionAfterLastRelease() {
        var gate = ShiftBurstGate()
        for n in 0..<40 {
            let time = Double(n) * 0.03
            gate.shiftChanged(down: true, at: time)
            gate.shiftChanged(down: false, at: time + 0.01)
            if n % 2 == 1 { gate.request() }
            XCTAssertFalse(gate.consume(at: time + 0.02))
        }
        XCTAssertTrue(gate.consume(at: 1.5))
        XCTAssertFalse(gate.consume(at: 2))
    }
    func testHeldShiftNeverStartsReplacement() {
        var gate = ShiftBurstGate()
        gate.request()
        gate.shiftChanged(down: true, at: 0)
        XCTAssertFalse(gate.consume(at: 10))
        gate.shiftChanged(down: false, at: 10)
        XCTAssertFalse(gate.consume(at: 10.05))
        XCTAssertTrue(gate.consume(at: 10.2))
    }
    func testRealTypingCancelsPendingCommand() {
        var gate = ShiftBurstGate()
        gate.shiftChanged(down: false, at: 0)
        gate.request()
        gate.cancel()
        XCTAssertFalse(gate.consume(at: 1))
    }
    func testSeparateGesturesRemainIndependent() {
        var gate = ShiftBurstGate()
        for time in [0.0, 1.0, 2.0] {
            gate.shiftChanged(down: false, at: time)
            gate.request()
            XCTAssertTrue(gate.consume(at: time + 0.2))
        }
    }

    func testStormCrossingRunningAndCompletionNeverQueuesAnotherReplacement() {
        var gate = ShiftBurstGate(quietInterval: 0.09)
        gate.shiftChanged(down: false, at: 0)
        gate.request()
        XCTAssertTrue(gate.consume(at: 0.1))
        XCTAssertTrue(gate.beginConversion())
        for n in 1...30 {
            let time = 0.1 + Double(n) * 0.03
            gate.shiftChanged(down: true, at: time)
            gate.request()
            gate.shiftChanged(down: false, at: time + 0.01)
            if n == 10 { gate.complete(at: time + 0.015, unverified: false) }
            XCTAssertFalse(gate.consume(at: time + 0.02))
            XCTAssertFalse(gate.beginConversion())
        }
        XCTAssertFalse(gate.consume(at: 2))
        gate.shiftChanged(down: true, at: 2)
        gate.shiftChanged(down: false, at: 2.01)
        gate.request()
        XCTAssertTrue(gate.consume(at: 2.11))
        XCTAssertTrue(gate.beginConversion())
    }

    func testUnverifiedReplacementBlocksAnyShiftBurstUntilRealInput() {
        var gate = ShiftBurstGate()
        XCTAssertTrue(gate.beginConversion())
        gate.complete(at: 1, unverified: true)
        for n in 0..<40 {
            gate.shiftChanged(down: false, at: 2 + Double(n))
            gate.request()
            XCTAssertFalse(gate.consume(at: 3 + Double(n)))
        }
        XCTAssertEqual(gate.state, .blocked)
        gate.realInput()
        gate.shiftChanged(down: false, at: 50)
        gate.request()
        XCTAssertTrue(gate.consume(at: 50.1))
    }

    func testInputDuringAnUnverifiedAttemptAllowsTheChangedContextToRecover() {
        var gate = ShiftBurstGate()
        XCTAssertTrue(gate.beginConversion())
        gate.realInput()
        gate.request()
        XCTAssertFalse(gate.pending)
        gate.complete(at: 1, unverified: true)
        XCTAssertEqual(gate.state, .draining)
        gate.shiftChanged(down: false, at: 2)
        gate.request()
        XCTAssertTrue(gate.consume(at: 2.1))
    }

    func testInputDoesNotAllowOverlapWithCancelledAttemptStillCleaningUp() {
        var gate = ShiftBurstGate()
        XCTAssertTrue(gate.beginConversion())
        gate.realInput()
        XCTAssertFalse(gate.beginConversion())
        gate.complete(at: 0, unverified: false)
        XCTAssertFalse(gate.beginConversion())
        gate.shiftChanged(down: false, at: 0.2)
        XCTAssertTrue(gate.beginConversion())
    }
}
