import XCTest
@testable import SwitcherCore

final class ConversionLifecycleTests: XCTestCase {
    func testMutationAndCompletionAreExactlyOnceAcrossLateCallbacks() {
        var lifecycle = ConversionLifecycle()
        XCTAssertTrue(lifecycle.commitMutation())
        XCTAssertFalse(lifecycle.commitMutation())
        XCTAssertTrue(lifecycle.finish())
        XCTAssertFalse(lifecycle.cancel())
        XCTAssertFalse(lifecycle.commitMutation())
        XCTAssertFalse(lifecycle.finish())
    }
    func testCancellationBeforeMutationCannotBecomeUnverifiedMutation() {
        var lifecycle = ConversionLifecycle()
        XCTAssertTrue(lifecycle.cancel())
        XCTAssertFalse(lifecycle.hasMutated)
        XCTAssertFalse(lifecycle.commitMutation())
        XCTAssertTrue(lifecycle.finish())
    }
    func testCancellationAfterMutationKeepsUnverifiedHistory() {
        var lifecycle = ConversionLifecycle()
        XCTAssertTrue(lifecycle.commitMutation())
        XCTAssertTrue(lifecycle.cancel())
        XCTAssertTrue(lifecycle.hasMutated)
        XCTAssertFalse(lifecycle.canContinue)
        XCTAssertFalse(lifecycle.commitMutation())
    }
    func testCancelCaptureBeforeItsLateScreenshotCannotStartMutation() {
        var lifecycle = ConversionLifecycle()
        var mutations = 0
        var completions = 0
        let capture = PreparationDelivery<Int> { result in
            completions += 1
            switch result {
            case .cancelled: _ = lifecycle.cancel()
            case .ready, .skipped:
                if lifecycle.commitMutation() { mutations += 1 }
            }
        }
        capture.cancel()
        capture.complete(.ready(1))
        capture.complete(.skipped)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(mutations, 0)
        XCTAssertFalse(lifecycle.hasMutated)
    }
    func testTimeoutMayProceedButLateScreenshotCannotReplaceTwice() {
        var lifecycle = ConversionLifecycle()
        var mutations = 0
        let capture = PreparationDelivery<Int> { result in
            switch result {
            case .cancelled: _ = lifecycle.cancel()
            case .ready, .skipped:
                if lifecycle.commitMutation() { mutations += 1 }
            }
        }
        capture.complete(.skipped)
        capture.complete(.ready(1))
        capture.cancel()
        XCTAssertEqual(mutations, 1)
        XCTAssertEqual(lifecycle.phase, .mutated)
    }
    func testInputInvalidationPrecedesPendingCaptureUnavailableCallback() {
        var lifecycle = ConversionLifecycle()
        var mutations = 0
        let capture = PreparationDelivery<Int> { result in
            switch result {
            case .cancelled: break
            case .skipped, .ready:
                if lifecycle.canContinue && lifecycle.commitMutation() { mutations += 1 }
            }
        }
        _ = lifecycle.cancel() // immediate event-tap invalidation
        capture.complete(.skipped) // deferred timeout was already enqueued
        XCTAssertEqual(mutations, 0)
    }
}
