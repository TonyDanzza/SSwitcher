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
        XCTAssertTrue(WindowTransferPlan.approximatelyEqual(up.frame, original, tolerance: 0.001))
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
        let old = CGRect(x: 3, y: 0, width: 497, height: 800)
        XCTAssertEqual(try move(old, [a, b], .right).frame.size, old.size)
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
}
