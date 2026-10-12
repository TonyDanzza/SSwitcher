import Foundation

public enum WindowMoveDirection: UInt32, CaseIterable { case left = 1, right, up, down }

/// All rectangles use Accessibility's global top-left coordinates, in points.
public struct WindowDisplay: Equatable {
    public let id: UInt32
    public let frame: CGRect
    public let visibleFrame: CGRect
    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect) {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame
    }
}

public struct WindowTransferPlan: Equatable {
    public enum Decision: Equatable { case move(WindowTransferPlan), noNeighbor, invalidGeometry, resizeUnavailable }
    public let sourceID: UInt32
    public let destinationID: UInt32
    public let frame: CGRect
    public let needsResize: Bool

    /// macOS's own tiles differ from exact fractions of the visible frame by
    /// 1-2 pt (overlap rounding). Every edge must still be this close.
    public static let tileTolerance: CGFloat = 4

    public static func accessibilityRect(fromAppKit rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }

    public static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        valid(a) && valid(b) && abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    public static func decide(window: CGRect, displays: [WindowDisplay], direction: WindowMoveDirection, canResize: Bool) -> Decision {
        guard valid(window), !displays.isEmpty, Set(displays.map(\.id)).count == displays.count,
              displays.allSatisfy({ valid($0.frame) && valid($0.visibleFrame) && $0.frame.insetBy(dx: -0.01, dy: -0.01).contains($0.visibleFrame) }) else { return .invalidGeometry }
        // Stable IDs settle equal intersection, independently of NSScreen order.
        let ranked = displays.sorted {
            let a = area(window.intersection($0.frame)), b = area(window.intersection($1.frame))
            return a == b ? $0.id < $1.id : a > b
        }
        guard let source = ranked.first, area(window.intersection(source.frame)) > 0 else { return .invalidGeometry }
        let candidates = displays.filter { $0.id != source.id }.compactMap { destination -> (WindowDisplay, Bool, CGFloat, CGFloat, CGFloat)? in
            let edgeGap = Self.edgeGap(from: source.frame, to: destination.frame, direction: direction)
            let overlap: CGFloat, perpendicularGap: CGFloat, centerOffset: CGFloat
            switch direction {
            case .left, .right:
                overlap = min(source.frame.maxY, destination.frame.maxY) - max(source.frame.minY, destination.frame.minY)
                perpendicularGap = max(0, -overlap)
                centerOffset = abs(source.frame.midY - destination.frame.midY)
            case .up, .down:
                overlap = min(source.frame.maxX, destination.frame.maxX) - max(source.frame.minX, destination.frame.minX)
                perpendicularGap = max(0, -overlap)
                centerOffset = abs(source.frame.midX - destination.frame.midX)
            }
            // Centers alone would wrongly make the narrow display below a
            // possible left/right target. Require the requested physical edge.
            guard Self.isBeyondEdge(edgeGap) else { return nil }
            return (destination, overlap > 0, max(0, edgeGap), perpendicularGap, centerOffset)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 }
            if !$0.1 {
                let a = hypot($0.2, $0.3), b = hypot($1.2, $1.3)
                if a != b { return a < b }
            }
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            if $0.3 != $1.3 { return $0.3 < $1.3 }
            if $0.4 != $1.4 { return $0.4 < $1.4 }
            return $0.0.id < $1.0.id
        }
        guard let destination = candidates.first?.0 else { return .noNeighbor }
        let oldWork = source.visibleFrame, newWork = destination.visibleFrame
        // AppKit floors fractional window origins, which made repeated moves
        // creep. Request whole points: tiles round each edge so neighbours
        // stay adjacent; other windows keep their exact size.
        let result: CGRect
        if let fraction = tiledFraction(window: window, work: oldWork) {
            let minX = (newWork.minX + fraction.minX * newWork.width).rounded()
            let minY = (newWork.minY + fraction.minY * newWork.height).rounded()
            let maxX = (newWork.minX + fraction.maxX * newWork.width).rounded()
            let maxY = (newWork.minY + fraction.maxY * newWork.height).rounded()
            result = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        } else {
            let width = min(window.width, newWork.width), height = min(window.height, newWork.height)
            let x = relative(window.minX - oldWork.minX, available: oldWork.width - window.width)
            let y = relative(window.minY - oldWork.minY, available: oldWork.height - window.height)
            result = CGRect(x: (newWork.minX + x * (newWork.width - width)).rounded(),
                            y: (newWork.minY + y * (newWork.height - height)).rounded(), width: width, height: height)
        }
        let resize = abs(result.width - window.width) > 0.01 || abs(result.height - window.height) > 0.01
        guard !resize || canResize else { return .resizeUnavailable }
        guard valid(result), newWork.insetBy(dx: -0.5, dy: -0.5).contains(result) else { return .invalidGeometry }
        return .move(Self(sourceID: source.id, destinationID: destination.id, frame: result, needsResize: resize))
    }

    /// Distance from the source's edge in `direction` to the destination's
    /// facing edge; negative when the destination does not lie beyond it.
    public static func edgeGap(from source: CGRect, to destination: CGRect, direction: WindowMoveDirection) -> CGFloat {
        switch direction {
        case .left: return source.minX - destination.maxX
        case .right: return destination.minX - source.maxX
        case .up: return source.minY - destination.maxY
        case .down: return destination.minY - source.maxY
        }
    }
    static func isBeyondEdge(_ gap: CGFloat) -> Bool { gap >= -0.01 }

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height }
    private static func relative(_ offset: CGFloat, available: CGFloat) -> CGFloat {
        available > 0 ? min(1, max(0, offset / available)) : 0.5
    }
    private static func tiledFraction(window: CGRect, work: CGRect) -> CGRect? {
        var fractions: [CGRect] = [CGRect(x: 0, y: 0, width: 1, height: 1),
                         CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                         CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]
        for x: CGFloat in [0, 0.5] {
            for y: CGFloat in [0, 0.5] { fractions.append(CGRect(x: x, y: y, width: 0.5, height: 0.5)) }
        }
        return fractions.first { fraction in
            let expected = CGRect(x: work.minX + fraction.minX * work.width, y: work.minY + fraction.minY * work.height,
                                  width: fraction.width * work.width, height: fraction.height * work.height)
            return edgesMatch(window, expected, tolerance: tileTolerance)
        }
    }

    /// All four edges within `tolerance` points.
    public static func edgesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        valid(a) && valid(b) && abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    /// The display holding the largest part of `frame`, or nil off screen.
    public static func mainDisplay(of frame: CGRect, in displays: [WindowDisplay]) -> WindowDisplay? {
        let ranked = displays.map { ($0, area(frame.intersection($0.frame))) }.filter { $0.1 > 0 }
        return ranked.max { $0.1 == $1.1 ? $0.0.id > $1.0.id : $0.1 < $1.1 }?.0
    }
}

/// The verified result of a whole transfer.
public enum WindowTransferOutcome: Equatable {
    /// Every edge is within `WindowTransferPlan.tileTolerance` of the plan.
    case moved
    /// The window is on the destination display, but macOS or the application
    /// changed its size or position (minimum size, display constraints).
    case adjusted
    case unconfirmed

    public static func classify(final: CGRect, plan: WindowTransferPlan, displays: [WindowDisplay]) -> Self {
        if WindowTransferPlan.edgesMatch(final, plan.frame, tolerance: WindowTransferPlan.tileTolerance) { return .moved }
        return WindowTransferPlan.mainDisplay(of: final, in: displays)?.id == plan.destinationID ? .adjusted : .unconfirmed
    }
}

/// Carbon can repeat a pressed hotkey. Each press/release cycle dispatches once;
/// stopping registration resets the gate so later presses cannot stay blocked.
public struct WindowShortcutPressGate {
    private var held: Set<UInt32> = []
    public init() {}
    public mutating func press(_ id: UInt32) -> Bool { held.insert(id).inserted }
    public mutating func release(_ id: UInt32) { held.remove(id) }
    public mutating func reset() { held.removeAll() }
}

/// Shrink on the source screen, move, then grow on the destination. AppKit
/// may change an anchor during growth; one final position step can correct it.
/// A step already satisfied by the acknowledged frame needs no setter.
///
/// Right after a window changes displays, its application still constrains
/// resizing to the previous display for 10-20 ms (measured with TextEdit and
/// Finder), so growth waits for a short settle; see the controller.
public enum WindowFrameOperation: Equatable {
    case size(CGSize), position(CGPoint)

    public static func sequence(from source: CGRect, to target: CGRect) -> [Self] {
        let intermediate = CGSize(width: min(source.width, target.width), height: min(source.height, target.height))
        var steps: [Self] = []
        if intermediate != source.size { steps.append(.size(intermediate)) }
        steps.append(.position(target.origin))
        if intermediate != target.size {
            steps.append(.size(target.size))
            steps.append(.position(target.origin))
        }
        return steps
    }

    public func matches(_ frame: CGRect) -> Bool {
        switch self {
        case .size(let size): return abs(frame.width - size.width) <= 1 && abs(frame.height - size.height) <= 1
        case .position(let point): return abs(frame.minX - point.x) <= 1 && abs(frame.minY - point.y) <= 1
        }
    }

    public func acknowledges(_ frame: CGRect, previous: CGRect) -> Bool {
        guard WindowTransferPlan.valid(frame), matches(frame) else { return false }
        switch self {
        case .size: return true // A size setter can change the window's anchor.
        case .position: return abs(frame.width - previous.width) <= 1 && abs(frame.height - previous.height) <= 1
        }
    }

    /// Already satisfied, including a later position step whose origin macOS
    /// already adjusted for an earlier one (for example a display constraint).
    public func isSatisfied(by frame: CGRect, acceptedOrigin: CGPoint?) -> Bool {
        if matches(frame) { return true }
        guard case .position = self, let acceptedOrigin else { return false }
        return abs(frame.minX - acceptedOrigin.x) <= 1 && abs(frame.minY - acceptedOrigin.y) <= 1
    }

    /// A size step that makes the window larger in either dimension.
    public func grows(_ frame: CGRect) -> Bool {
        guard case .size(let size) = self else { return false }
        return size.width > frame.width + 1 || size.height > frame.height + 1
    }

    /// A size step whose result stayed smaller than requested.
    public func fallsShort(_ frame: CGRect) -> Bool {
        guard case .size(let size) = self else { return false }
        return frame.width < size.width - 1 || frame.height < size.height - 1
    }
}

/// Polled frames after one issued step. AppKit and the application may apply
/// the step exactly, adjust it (display constraints, minimum sizes, size
/// increments) or ignore it; a frame that stays the same decides which.
public struct WindowStepProgress {
    public enum State: Equatable { case waiting, applied(CGRect), adjusted(CGRect), unchanged(CGRect) }
    /// A changed frame that holds this long is the application's answer.
    public static let adjustedStability = 0.04
    /// A step with no visible effect is accepted only after a longer quiet time.
    public static let unchangedStability = 0.2
    public let operation: WindowFrameOperation
    public let before: CGRect
    private var last: CGRect?
    private var stableSince = 0.0

    public init(operation: WindowFrameOperation, before: CGRect) {
        self.operation = operation; self.before = before
    }

    public mutating func observe(_ frame: CGRect, at time: Double) -> State {
        if last.map({ WindowTransferPlan.edgesMatch($0, frame, tolerance: 0.5) }) != true {
            last = frame; stableSince = time
        }
        if operation.acknowledges(frame, previous: before) { return .applied(frame) }
        let stable = time - stableSince
        let changed: Bool
        switch operation {
        case .size: changed = abs(frame.width - before.width) > 0.5 || abs(frame.height - before.height) > 0.5
        case .position: changed = abs(frame.minX - before.minX) > 0.5 || abs(frame.minY - before.minY) > 0.5
        }
        if changed, stable >= Self.adjustedStability { return .adjusted(frame) }
        if !changed, stable >= Self.unchangedStability { return .unchanged(frame) }
        return .waiting
    }
}

/// Chord releases are legitimate while a transfer finishes. Pointer activity,
/// typing and a newly pressed modifier invalidate the pending window instead.
public enum WindowShortcutInteraction {
    case keyDown, keyUp, modifierChanged, pointer, listenerUnavailable

    public func cancelsMove(key: UInt16 = 0, option: Bool = false, shift: Bool = false,
                            command: Bool = false, control: Bool = false) -> Bool {
        switch self {
        case .keyUp: return false
        case .pointer, .listenerUnavailable: return true
        case .modifierChanged:
            if (key == 56 || key == 60) && !shift { return false }
            if (key == 58 || key == 61) && !option { return false }
            return true
        case .keyDown:
            return !((123...126).contains(key) && option && shift && !command && !control)
        }
    }
}
