import XCTest
@testable import SwitcherCore

final class ReadinessDeadlineTests: XCTestCase {
    func testReadinessPollingStopsAtOriginalDeadline() {
        var deadline = ReadinessDeadline(start: 10, timeout: 0.5, pollInterval: 0.02)
        XCTAssertTrue(deadline.shouldRead(at: 10))
        XCTAssertFalse(deadline.shouldRead(at: 10.005))
        XCTAssertTrue(deadline.shouldRead(at: 10.025))
        XCTAssertFalse(deadline.shouldRead(at: 10.5))
        XCTAssertTrue(deadline.expired(at: 10.5))
    }
    func testRepeatedPollsCannotExtendDeadline() {
        var deadline = ReadinessDeadline(start: 0, timeout: 0.5, pollInterval: 0.05)
        XCTAssertTrue(deadline.shouldRead(at: 0))
        XCTAssertFalse(deadline.shouldRead(at: 0.01))
        for n in 2..<50 { _ = deadline.shouldRead(at: Double(n) * 0.01) }
        XCTAssertEqual(deadline.expiresAt, 0.5)
        XCTAssertFalse(deadline.shouldRead(at: 0.5))
    }
    func testAReadTakingLongerThanDeadlineDoesNotScheduleAnotherRead() {
        var deadline = ReadinessDeadline(start: 0, timeout: 0.1)
        XCTAssertTrue(deadline.shouldRead(at: 0))
        XCTAssertTrue(deadline.expired(at: 0.15))
        XCTAssertFalse(deadline.shouldRead(at: 0.15))
        XCTAssertEqual(deadline.delay(at: 0.15), 0)
    }
}
