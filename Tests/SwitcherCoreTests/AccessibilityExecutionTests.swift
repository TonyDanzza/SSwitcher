import Foundation
import XCTest
@testable import SwitcherCore

final class AccessibilityExecutionTests: XCTestCase {
    func testOwnApplicationAXSetterSeamExecutesOnMain() {
        let done = expectation(description: "local AppKit AX callback")
        let executor = AccessibilityExecution(policy: .localApplication)
        // Start from a worker as the focused target discovery does in the app.
        DispatchQueue.global().async {
            executor.submit {
                executor.assertIsolated()
                XCTAssertTrue(Thread.isMainThread)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 2)
    }
    func testExternalAXMessagesAreOffMainAndRemainSerialized() {
        let done = expectation(description: "remote AX messages")
        let executor = AccessibilityExecution(policy: .remoteApplication)
        var sequence: [Int] = [] // read/write only on the tested serial queue
        for number in 0..<20 {
            executor.submit {
                executor.assertIsolated()
                XCTAssertFalse(Thread.isMainThread)
                sequence.append(number)
                if number == 19 {
                    XCTAssertEqual(sequence, Array(0..<20))
                    done.fulfill()
                }
            }
        }
        wait(for: [done], timeout: 2)
    }
    func testLocalAndRemoteExecutorsKeepTheirOwnStateDomains() {
        let localDone = expectation(description: "local domain")
        let remoteDone = expectation(description: "remote domain")
        let local = AccessibilityExecution(policy: .localApplication)
        let remote = AccessibilityExecution(policy: .remoteApplication)
        local.submit { local.assertIsolated(); XCTAssertTrue(Thread.isMainThread); localDone.fulfill() }
        remote.submit { remote.assertIsolated(); XCTAssertFalse(Thread.isMainThread); remoteDone.fulfill() }
        wait(for: [localDone, remoteDone], timeout: 2)
    }
}
