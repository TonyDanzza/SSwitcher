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
}
