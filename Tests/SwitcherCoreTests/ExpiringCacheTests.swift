import XCTest
@testable import SwitcherCore

final class ExpiringCacheTests: XCTestCase {
    func testTransientUnsupportedCapabilityExpiresAndCanRecover() {
        var cache = ExpiringCache<String, Bool>()
        cache.insert(false, for: "process-session:canvas-element", at: 0, lifetime: 3)
        XCTAssertEqual(cache.value(for: "process-session:canvas-element", at: 2), false)
        XCTAssertNil(cache.value(for: "process-session:canvas-element", at: 3))
        cache.insert(true, for: "process-session:canvas-element", at: 3, lifetime: 30)
        XCTAssertEqual(cache.value(for: "process-session:canvas-element", at: 4), true)
    }
    func testProcessVersionSessionAndFieldDoNotShareFailures() {
        var cache = ExpiringCache<String, Bool>()
        cache.insert(false, for: "pid1:session1:v1:canvas", at: 0, lifetime: 3)
        for key in ["pid2:session1:v1:canvas", "pid1:session2:v1:canvas", "pid1:session1:v2:canvas", "pid1:session1:v1:sidebar"] {
            XCTAssertNil(cache.value(for: key, at: 1))
        }
    }
    func testCacheIsBoundedAndInvalidationRecoversNewContextImmediately() {
        var cache = ExpiringCache<Int, Bool>(capacity: 2)
        for key in 0..<3 { cache.insert(false, for: key, at: Double(key), lifetime: 30) }
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(for: 0, at: 3))
        XCTAssertEqual(cache.value(for: 2, at: 3), false)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.value(for: 2, at: 3))
    }
}
