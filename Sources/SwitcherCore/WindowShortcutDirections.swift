import Foundation

/// Which arrow shortcuts move windows. Automatic registers only directions in
/// which some display has a neighbor, so the other arrows keep their usual
/// text-selection meaning.
public enum WindowDirectionChoice: Equatable {
    case automatic
    case manual(Set<WindowMoveDirection>)
}

public enum WindowShortcutDirections {
    /// Directions in which at least one display has another display beyond
    /// the facing edge, the same test the transfer plan uses. Mirrored
    /// displays (equal frames) count once.
    public static func available(in displays: [WindowDisplay]) -> Set<WindowMoveDirection> {
        let frames = displays.map(\.frame).reduce(into: [CGRect]()) { unique, frame in
            if !unique.contains(frame) { unique.append(frame) }
        }
        var result: Set<WindowMoveDirection> = []
        for source in frames {
            for destination in frames where destination != source {
                for direction in WindowMoveDirection.allCases
                where WindowTransferPlan.isBeyondEdge(WindowTransferPlan.edgeGap(from: source, to: destination, direction: direction)) {
                    result.insert(direction)
                }
            }
        }
        return result
    }

    public static func resolve(_ choice: WindowDirectionChoice, displays: [WindowDisplay]) -> Set<WindowMoveDirection> {
        switch choice {
        case .automatic: return available(in: displays)
        case .manual(let directions): return directions
        }
    }

    /// "↑↓", "←→↑↓": a stable order for menus and labels.
    public static func arrows(_ directions: Set<WindowMoveDirection>) -> String {
        WindowMoveDirection.allCases.filter(directions.contains).map(arrow).joined()
    }

    public static func arrow(_ direction: WindowMoveDirection) -> String {
        switch direction {
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        }
    }
}
