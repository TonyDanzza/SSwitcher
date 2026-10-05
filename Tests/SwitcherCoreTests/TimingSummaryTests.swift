import XCTest
@testable import SwitcherCore

final class TimingSummaryTests: XCTestCase {
    func testSmallSampleDoesNotPresentPercentilesAsABenchmark() {
        var summary = TimingSummary()
        for value in 1...19 { summary.record(Double(value)) }
        XCTAssertEqual(summary.count, 19)
        XCTAssertNil(summary.percentiles)
        summary.record(20)
        XCTAssertEqual(summary.percentiles?.median, 10.5)
        XCTAssertEqual(summary.percentiles?.p95, 19)
    }
    func testMemoryBoundRetainsNewestSamplesAndRejectsInvalidNumbers() {
        var summary = TimingSummary(capacity: 20)
        summary.record(.nan); summary.record(.infinity); summary.record(-1)
        for value in 1...100 { summary.record(Double(value)) }
        XCTAssertEqual(summary.count, 20)
        XCTAssertEqual(summary.percentiles?.median, 90.5)
        XCTAssertEqual(summary.percentiles?.p95, 99)
    }
}
