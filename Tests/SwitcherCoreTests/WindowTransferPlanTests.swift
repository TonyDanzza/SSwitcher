import Foundation
import XCTest
@testable import SwitcherCore

final class WindowTransferPlanTests: XCTestCase {
    private func display(_ id: UInt32, _ frame: CGRect, work: CGRect? = nil) -> WindowDisplay {
        WindowDisplay(id: id, frame: frame, visibleFrame: work ?? frame)
    }
    private func move(_ window: CGRect, _ screens: [WindowDisplay], _ direction: WindowMoveDirection, resize: Bool = true) throws -> WindowTransferPlan {
        guard case .move(let plan) = WindowTransferPlan.decide(window: window, displays: screens, direction: direction, canResize: resize) else {
            XCTFail("Expected a move"); throw NSError(domain: "WindowTransferPlanTests", code: 1)
        }
        return plan
    }

    func testActualVerticalLayoutHasUpDownButNoLeftRightNeighbors() throws {
        let monitor = display(2, CGRect(x: 0, y: 0, width: 2560, height: 1440), work: CGRect(x: 0, y: 31, width: 2560, height: 1409))
        let laptop = display(1, CGRect(x: 579, y: 1440, width: 1470, height: 956), work: CGRect(x: 579, y: 1474, width: 1470, height: 922))
        let original = CGRect(x: 700, y: 300, width: 700, height: 730)
        let down = try move(original, [laptop, monitor], .down)
        XCTAssertEqual(down.sourceID, 2); XCTAssertEqual(down.destinationID, 1)
        XCTAssertEqual(down.frame.size, original.size)
        XCTAssertTrue(laptop.visibleFrame.contains(down.frame))
        let up = try move(down.frame, [monitor, laptop], .up)
        // Whole-point targets: a round trip may differ by the rounding point.
        XCTAssertTrue(WindowTransferPlan.approximatelyEqual(up.frame, original, tolerance: 1))
        for direction in [WindowMoveDirection.left, .right] {
            XCTAssertEqual(WindowTransferPlan.decide(window: original, displays: [monitor, laptop], direction: direction, canResize: true), .noNeighbor)
            XCTAssertEqual(WindowTransferPlan.decide(window: down.frame, displays: [monitor, laptop], direction: direction, canResize: true), .noNeighbor)
        }
    }

    func testAppKitTransformUsesPrimaryTopAndPreservesNegativeScreenCoordinates() {
        XCTAssertEqual(WindowTransferPlan.accessibilityRect(fromAppKit: CGRect(x: -1000, y: 1440, width: 1000, height: 800), primaryTop: 1440),
                       CGRect(x: -1000, y: -800, width: 1000, height: 800))
        XCTAssertEqual(WindowTransferPlan.accessibilityRect(fromAppKit: CGRect(x: 579, y: -956, width: 1470, height: 956), primaryTop: 1440),
                       CGRect(x: 579, y: 1440, width: 1470, height: 956))
    }

    func testRelativePlacementPreservesPointSizeAcrossDifferentWorkAreas() throws {
        let a = display(1, CGRect(x: 0, y: 0, width: 1000, height: 800), work: CGRect(x: 30, y: 40, width: 970, height: 760))
        let b = display(2, CGRect(x: 1000, y: -200, width: 1600, height: 1200), work: CGRect(x: 1000, y: -170, width: 1550, height: 1150))
        let old = CGRect(x: 365, y: 270, width: 300, height: 300)
        let plan = try move(old, [a, b], .right, resize: false)
        XCTAssertEqual(plan.frame, CGRect(x: 1625, y: 255, width: 300, height: 300))
        XCTAssertFalse(plan.needsResize)
    }

    func testSmallerDestinationShrinksOnlyWhenSizeIsSettable() throws {
        let screens = [display(1, CGRect(x: 0, y: 0, width: 2000, height: 1500)), display(2, CGRect(x: 2000, y: 0, width: 800, height: 600))]
        let old = CGRect(x: 100, y: 80, width: 1200, height: 900)
        let plan = try move(old, screens, .right)
        XCTAssertEqual(plan.frame, CGRect(x: 2000, y: 0, width: 800, height: 600))
        XCTAssertTrue(plan.needsResize)
        XCTAssertEqual(WindowTransferPlan.decide(window: old, displays: screens, direction: .right, canResize: false), .resizeUnavailable)
    }

    func testFullHalfAndQuarterGeometryMapsToDestinationFractions() throws {
        let a = display(1, CGRect(x: 0, y: 0, width: 1000, height: 800), work: CGRect(x: 0, y: 30, width: 1000, height: 770))
        let b = display(2, CGRect(x: -1600, y: 0, width: 1600, height: 1000), work: CGRect(x: -1600, y: 30, width: 1600, height: 970))
        for fraction in [CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                         CGRect(x: 0, y: 0.5, width: 1, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)] {
            let old = CGRect(x: a.visibleFrame.minX + fraction.minX * a.visibleFrame.width,
                             y: a.visibleFrame.minY + fraction.minY * a.visibleFrame.height,
                             width: fraction.width * a.visibleFrame.width, height: fraction.height * a.visibleFrame.height)
            let expected = CGRect(x: b.visibleFrame.minX + fraction.minX * b.visibleFrame.width,
                                  y: b.visibleFrame.minY + fraction.minY * b.visibleFrame.height,
                                  width: fraction.width * b.visibleFrame.width, height: fraction.height * b.visibleFrame.height)
            XCTAssertEqual(try move(old, [a, b], .left).frame, expected)
            XCTAssertEqual(WindowTransferPlan.decide(window: old, displays: [a, b], direction: .left, canResize: false), .resizeUnavailable)
        }
    }

    func testAlmostTiledWindowOutsideToleranceKeepsItsPointSize() throws {
        let a = display(1, CGRect(x: 0, y: 0, width: 1000, height: 800))
        let b = display(2, CGRect(x: 1000, y: 0, width: 2000, height: 1600))
        for old in [CGRect(x: 6, y: 0, width: 494, height: 800), CGRect(x: 0, y: 0, width: 506, height: 800),
                    CGRect(x: 0, y: 0, width: 500, height: 794)] {
            XCTAssertEqual(try move(old, [a, b], .right).frame.size, old.size)
        }
        // Within the tolerance on every edge it is the left half.
        XCTAssertEqual(try move(CGRect(x: 3, y: 0, width: 497, height: 800), [a, b], .right).frame.size, CGSize(width: 1000, height: 1600))
    }

    func testDirectNeighborIsPreferredOverDiagonalAndNearestDiagonalIsGeometric() throws {
        let source = display(1, CGRect(x: 0, y: 0, width: 1000, height: 800))
        let direct = display(2, CGRect(x: 2200, y: 200, width: 1000, height: 800))
        let diagonal = display(3, CGRect(x: 1000, y: 900, width: 1000, height: 800))
        let distant = display(4, CGRect(x: 1000, y: 4000, width: 1000, height: 800))
        let old = CGRect(x: 100, y: 100, width: 300, height: 300)
        XCTAssertEqual(try move(old, [source, diagonal, direct], .right).destinationID, 2)
        XCTAssertEqual(try move(old, [source, distant, diagonal], .right).destinationID, 3)
    }

    func testEqualSourceIntersectionAndNeighborTiesUseStableIDs() throws {
        let screens = [display(2, CGRect(x: 1000, y: 0, width: 1000, height: 800)), display(1, CGRect(x: 0, y: 0, width: 1000, height: 800)),
                       display(3, CGRect(x: -1000, y: 0, width: 1000, height: 800))]
        let plan = try move(CGRect(x: 900, y: 100, width: 200, height: 300), screens, .left)
        XCTAssertEqual(plan.sourceID, 1); XCTAssertEqual(plan.destinationID, 3)
        XCTAssertEqual(try move(CGRect(x: 900, y: 100, width: 200, height: 300), Array(screens.reversed()), .left), plan)
    }

    func testInvalidAndOffscreenGeometryIsRefusedAndSingleDisplayDoesNotWrap() {
        let screen = display(1, CGRect(x: 0, y: 0, width: 1000, height: 800))
        for frame in [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 200, height: 100), CGRect(x: 5000, y: 0, width: 200, height: 100)] {
            XCTAssertEqual(WindowTransferPlan.decide(window: frame, displays: [screen], direction: .right, canResize: true), .invalidGeometry)
        }
        let frame = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(WindowTransferPlan.decide(window: frame, displays: [screen, screen], direction: .right, canResize: true), .invalidGeometry)
        for direction in WindowMoveDirection.allCases {
            XCTAssertEqual(WindowTransferPlan.decide(window: frame, displays: [screen], direction: direction, canResize: true), .noNeighbor)
        }
    }

    func testPressReleaseAndDisableLifecycleDoesNotQueueOrRepeat() {
        var gate = WindowShortcutPressGate()
        XCTAssertTrue(gate.press(1)); XCTAssertFalse(gate.press(1)); XCTAssertFalse(gate.press(1))
        gate.release(1)
        XCTAssertTrue(gate.press(1))
        gate.reset()
        XCTAssertTrue(gate.press(1))
        XCTAssertTrue(gate.press(2)); XCTAssertFalse(gate.press(2))
    }

    func testMutationOrderShrinksBeforeMovingAndGrowsOnlyAfterMoving() {
        let old = CGRect(x: 100, y: 100, width: 900, height: 700)
        let same = CGRect(x: 2000, y: 50, width: 900, height: 700)
        XCTAssertEqual(WindowFrameOperation.sequence(from: old, to: same), [.position(same.origin)])
        let smaller = CGRect(x: 2000, y: 50, width: 600, height: 500)
        XCTAssertEqual(WindowFrameOperation.sequence(from: old, to: smaller), [.size(smaller.size), .position(smaller.origin)])
        let larger = CGRect(x: -2000, y: 50, width: 1500, height: 1000)
        XCTAssertEqual(WindowFrameOperation.sequence(from: old, to: larger), [.position(larger.origin), .size(larger.size), .position(larger.origin)])
        let mixed = CGRect(x: -2000, y: 50, width: 600, height: 1000)
        XCTAssertEqual(WindowFrameOperation.sequence(from: old, to: mixed), [.size(CGSize(width: 600, height: 700)),
                                                                          .position(mixed.origin), .size(mixed.size), .position(mixed.origin)])
    }

    func testPositionAcknowledgementRejectsConcurrentResizeAndGrowthAllowsAnchorAdjustment() {
        let before = CGRect(x: 100, y: 100, width: 900, height: 700)
        let moved = CGRect(x: 2000, y: 50, width: 900, height: 700)
        let position = WindowFrameOperation.position(moved.origin)
        XCTAssertTrue(position.acknowledges(moved, previous: before))
        XCTAssertFalse(position.acknowledges(CGRect(x: 2000, y: 50, width: 800, height: 700), previous: before))
        let growth = WindowFrameOperation.size(CGSize(width: 1500, height: 1000))
        let shiftedAnchor = CGRect(x: 1900, y: 30, width: 1500, height: 1000)
        XCTAssertTrue(growth.acknowledges(shiftedAnchor, previous: moved))
        XCTAssertFalse(position.matches(shiftedAnchor)) // One planned correction remains necessary.
    }

    func testRealInteractionCancelsButChordRepeatAndReleaseDoNot() {
        XCTAssertTrue(WindowShortcutInteraction.pointer.cancelsMove())
        XCTAssertTrue(WindowShortcutInteraction.listenerUnavailable.cancelsMove())
        XCTAssertTrue(WindowShortcutInteraction.keyDown.cancelsMove(key: 0, option: true, shift: true))
        XCTAssertTrue(WindowShortcutInteraction.keyDown.cancelsMove(key: 125))
        XCTAssertTrue(WindowShortcutInteraction.keyDown.cancelsMove(key: 125, option: true, shift: true, command: true))
        for key: UInt16 in [123, 124, 125, 126] {
            XCTAssertFalse(WindowShortcutInteraction.keyDown.cancelsMove(key: key, option: true, shift: true))
            XCTAssertFalse(WindowShortcutInteraction.keyUp.cancelsMove(key: key))
        }
        for key: UInt16 in [56, 60] {
            XCTAssertFalse(WindowShortcutInteraction.modifierChanged.cancelsMove(key: key, option: true, shift: false))
            XCTAssertTrue(WindowShortcutInteraction.modifierChanged.cancelsMove(key: key, shift: true))
        }
        for key: UInt16 in [58, 61] {
            XCTAssertFalse(WindowShortcutInteraction.modifierChanged.cancelsMove(key: key, option: false, shift: true))
            XCTAssertTrue(WindowShortcutInteraction.modifierChanged.cancelsMove(key: key, option: true))
        }
    }

    // Measured on this Mac by the menu bar app (NSScreen, AX coordinates):
    // LG main display on top, notched MacBook below.
    private let lg = WindowDisplay(id: 3, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                   visibleFrame: CGRect(x: 0, y: 31, width: 2560, height: 1409))
    private let macBook = WindowDisplay(id: 1, frame: CGRect(x: 579, y: 1440, width: 1470, height: 956),
                                        visibleFrame: CGRect(x: 579, y: 1474, width: 1470, height: 922))

    func testMeasuredMacOSTilesAreRecognizedOnBothDisplays() throws {
        // Window menu > Move & Resize frames read back through AX on this Mac.
        let lgTiles: [(CGRect, CGRect)] = [
            (CGRect(x: 0, y: 31, width: 2560, height: 1410), CGRect(x: 579, y: 1474, width: 1470, height: 922)),
            (CGRect(x: 0, y: 31, width: 1281, height: 1410), CGRect(x: 579, y: 1474, width: 735, height: 922)),
            (CGRect(x: 1280, y: 31, width: 1280, height: 1410), CGRect(x: 1314, y: 1474, width: 735, height: 922)),
            (CGRect(x: 0, y: 31, width: 1280, height: 706), CGRect(x: 579, y: 1474, width: 735, height: 461)),
            (CGRect(x: 1279, y: 734, width: 1280, height: 706), CGRect(x: 1314, y: 1935, width: 735, height: 461))
        ]
        for (tile, expected) in lgTiles { XCTAssertEqual(try move(tile, [lg, macBook], .down).frame, expected, "\(tile)") }
        let macTiles: [(CGRect, CGRect)] = [
            (CGRect(x: 579, y: 1474, width: 1470, height: 923), CGRect(x: 0, y: 31, width: 2560, height: 1409)),
            (CGRect(x: 579, y: 1474, width: 736, height: 923), CGRect(x: 0, y: 31, width: 1280, height: 1409)),
            (CGRect(x: 1315, y: 1474, width: 734, height: 923), CGRect(x: 1280, y: 31, width: 1280, height: 1409)),
            (CGRect(x: 579, y: 1474, width: 735, height: 462), CGRect(x: 0, y: 31, width: 1280, height: 705)),
            (CGRect(x: 1314, y: 1934, width: 735, height: 462), CGRect(x: 1280, y: 736, width: 1280, height: 704)),
            // A right half placed by our own earlier move.
            (CGRect(x: 1314, y: 1474, width: 735, height: 922), CGRect(x: 1280, y: 31, width: 1280, height: 1409))
        ]
        for (tile, expected) in macTiles { XCTAssertEqual(try move(tile, [lg, macBook], .up).frame, expected, "\(tile)") }
    }

    func testWindowLargerThanLaptopShrinksToItsWorkAreaAndKeepsSizeGoingBack() throws {
        let large = CGRect(x: 300, y: 150, width: 1749, height: 1200)
        let down = try move(large, [lg, macBook], .down)
        XCTAssertEqual(down.frame, macBook.visibleFrame)
        XCTAssertTrue(down.needsResize)
        XCTAssertEqual(WindowTransferPlan.decide(window: large, displays: [lg, macBook], direction: .down, canResize: false), .resizeUnavailable)
        // The shrunken window fills the laptop, so it returns as a full tile.
        XCTAssertEqual(try move(CGRect(x: 579, y: 1474, width: 1470, height: 922), [lg, macBook], .up).frame, lg.visibleFrame)
    }

    func testWindowAtEdgesKeepsItsEdgeAndWholePointOrigin() throws {
        let topLeft = try move(CGRect(x: 0, y: 31, width: 600, height: 400), [lg, macBook], .down)
        XCTAssertEqual(topLeft.frame, CGRect(x: 579, y: 1474, width: 600, height: 400))
        let bottomRight = try move(CGRect(x: 1960, y: 1040, width: 600, height: 400), [lg, macBook], .down)
        XCTAssertEqual(bottomRight.frame, CGRect(x: 1449, y: 1996, width: 600, height: 400))
        // Hanging below the monitor clamps to the laptop's bottom edge.
        XCTAssertEqual(try move(CGRect(x: 700, y: 1100, width: 600, height: 400), [lg, macBook], .down).frame,
                       CGRect(x: 890, y: 1996, width: 600, height: 400))
        // Fractional relative positions (759.66) are rounded, never floored,
        // so round trips settle instead of creeping by a point each time.
        let middle = try move(CGRect(x: 407, y: 192, width: 600, height: 340), [lg, macBook], .down).frame
        XCTAssertEqual(middle, CGRect(x: 760, y: 1562, width: 600, height: 340))
        let back = try move(middle, [lg, macBook], .up).frame
        XCTAssertEqual(back.origin, CGPoint(x: 408, y: 193))
        XCTAssertEqual(try move(back, [lg, macBook], .down).frame, middle)
        XCTAssertEqual(try move(middle, [lg, macBook], .up).frame, back)
    }

    func testLaptopLeftMonitorRightWithDifferentHeights() throws {
        // MacBook main display on the left, a taller monitor to its right,
        // aligned 200 pt higher. AX origin is the MacBook's top-left.
        let laptop = WindowDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                   visibleFrame: CGRect(x: 0, y: 32, width: 1470, height: 924))
        let monitor = WindowDisplay(id: 2, frame: CGRect(x: 1470, y: -200, width: 2560, height: 1440),
                                    visibleFrame: CGRect(x: 1470, y: -200, width: 2560, height: 1440))
        let window = CGRect(x: 100, y: 300, width: 800, height: 500)
        let right = try move(window, [laptop, monitor], .right)
        XCTAssertEqual(right.destinationID, 2)
        XCTAssertEqual(right.frame, CGRect(x: 1733, y: 394, width: 800, height: 500))
        XCTAssertEqual(try move(right.frame, [laptop, monitor], .left).frame, CGRect(x: 100, y: 300, width: 800, height: 500))
        XCTAssertEqual(WindowTransferPlan.decide(window: window, displays: [laptop, monitor], direction: .left, canResize: true), .noNeighbor)
        for direction in [WindowMoveDirection.up, .down] {
            XCTAssertEqual(WindowTransferPlan.decide(window: window, displays: [laptop, monitor], direction: direction, canResize: true), .noNeighbor)
        }
        // Right half of the monitor becomes the right half of the laptop.
        XCTAssertEqual(try move(CGRect(x: 2750, y: -200, width: 1280, height: 1440), [laptop, monitor], .left).frame,
                       CGRect(x: 735, y: 32, width: 735, height: 924))
        // A window taller than the laptop shrinks only in height.
        XCTAssertEqual(try move(CGRect(x: 1600, y: -100, width: 900, height: 1200), [laptop, monitor], .left).frame.size,
                       CGSize(width: 900, height: 924))
    }

    func testStepProgressAcceptsSystemAdjustmentsOnlyOnceStable() {
        // A display constraint keeps the window 2 pt lower and 2 pt shorter.
        var progress = WindowStepProgress(operation: .position(CGPoint(x: 579, y: 1472)), before: CGRect(x: 0, y: 31, width: 1470, height: 924))
        let adjusted = CGRect(x: 579, y: 1474, width: 1470, height: 922)
        XCTAssertEqual(progress.observe(adjusted, at: 0), .waiting)
        XCTAssertEqual(progress.observe(adjusted, at: 0.02), .waiting)
        XCTAssertEqual(progress.observe(adjusted, at: 0.04), .adjusted(adjusted))
        // An exact frame is applied at once.
        var exact = WindowStepProgress(operation: .size(CGSize(width: 735, height: 924)), before: CGRect(x: 0, y: 31, width: 1280, height: 1409))
        XCTAssertEqual(exact.observe(CGRect(x: 0, y: 31, width: 735, height: 924), at: 0), .applied(CGRect(x: 0, y: 31, width: 735, height: 924)))
        // A step with no visible effect needs a longer quiet time; a change restarts it.
        let before = CGRect(x: 100, y: 100, width: 484, height: 280)
        var minimum = WindowStepProgress(operation: .size(CGSize(width: 400, height: 200)), before: before)
        XCTAssertEqual(minimum.observe(before, at: 0), .waiting)
        XCTAssertEqual(minimum.observe(before, at: 0.1), .waiting)
        XCTAssertEqual(minimum.observe(before, at: 0.2), .unchanged(before))
        var moving = WindowStepProgress(operation: .size(CGSize(width: 2560, height: 1409)), before: CGRect(x: 0, y: 31, width: 1470, height: 922))
        XCTAssertEqual(moving.observe(CGRect(x: 0, y: 31, width: 1800, height: 1200), at: 0), .waiting)
        XCTAssertEqual(moving.observe(CGRect(x: 0, y: 31, width: 2049, height: 1409), at: 0.03), .waiting)
        XCTAssertEqual(moving.observe(CGRect(x: 0, y: 31, width: 2049, height: 1409), at: 0.05), .waiting)
        XCTAssertEqual(moving.observe(CGRect(x: 0, y: 31, width: 2049, height: 1409), at: 0.07), .adjusted(CGRect(x: 0, y: 31, width: 2049, height: 1409)))
    }

    func testGrowthAndShortfallAndAdjustedOriginSkipping() {
        let size = WindowFrameOperation.size(CGSize(width: 1280, height: 1409))
        let afterMove = CGRect(x: 1280, y: 31, width: 735, height: 922)
        XCTAssertTrue(size.grows(afterMove))
        XCTAssertFalse(size.grows(CGRect(x: 0, y: 0, width: 1280, height: 1409)))
        XCTAssertTrue(size.fallsShort(CGRect(x: 1280, y: 31, width: 769, height: 1409)))
        XCTAssertFalse(size.fallsShort(CGRect(x: 1280, y: 31, width: 1280, height: 1409)))
        XCTAssertFalse(WindowFrameOperation.position(.zero).grows(afterMove))
        let correction = WindowFrameOperation.position(CGPoint(x: 579, y: 1472))
        let adjusted = CGRect(x: 579, y: 1474, width: 1470, height: 922)
        XCTAssertFalse(correction.isSatisfied(by: adjusted, acceptedOrigin: nil))
        XCTAssertTrue(correction.isSatisfied(by: adjusted, acceptedOrigin: CGPoint(x: 579, y: 1474)))
        XCTAssertFalse(correction.isSatisfied(by: CGRect(x: 600, y: 1474, width: 1470, height: 922), acceptedOrigin: CGPoint(x: 579, y: 1474)))
    }

    func testOutcomeIsMovedAdjustedOrUnconfirmed() throws {
        let plan = try move(CGRect(x: 0, y: 31, width: 2560, height: 1409), [lg, macBook], .down)
        XCTAssertEqual(WindowTransferOutcome.classify(final: CGRect(x: 579, y: 1474, width: 1470, height: 922), plan: plan,
                                                      displays: [lg, macBook]), .moved)
        XCTAssertEqual(WindowTransferOutcome.classify(final: CGRect(x: 579, y: 1474, width: 1600, height: 922), plan: plan,
                                                      displays: [lg, macBook]), .adjusted)
        XCTAssertEqual(WindowTransferOutcome.classify(final: CGRect(x: 0, y: 31, width: 1470, height: 922), plan: plan,
                                                      displays: [lg, macBook]), .unconfirmed)
        XCTAssertEqual(WindowTransferPlan.mainDisplay(of: CGRect(x: 700, y: 1100, width: 600, height: 400), in: [lg, macBook])?.id, 3)
        XCTAssertNil(WindowTransferPlan.mainDisplay(of: CGRect(x: 5000, y: 0, width: 10, height: 10), in: [lg, macBook]))
    }
}
