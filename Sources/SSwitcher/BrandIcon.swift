import AppKit

/// Two opposing, rounded strokes: one compact mark shared by the app and menu.
enum BrandIcon {
    static func paths(in rect: NSRect) -> [NSBezierPath] {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * rect.width / 100, y: rect.minY + y * rect.height / 100)
        }
        let upper = NSBezierPath()
        upper.move(to: point(28, 46))
        upper.line(to: point(28, 57))
        upper.curve(to: point(41, 70), controlPoint1: point(28, 65), controlPoint2: point(33, 70))
        upper.line(to: point(72, 70))
        upper.move(to: point(60, 82))
        upper.line(to: point(72, 70))
        upper.line(to: point(60, 58))
        let lower = NSBezierPath()
        lower.move(to: point(72, 54))
        lower.line(to: point(72, 43))
        lower.curve(to: point(59, 30), controlPoint1: point(72, 35), controlPoint2: point(67, 30))
        lower.line(to: point(28, 30))
        lower.move(to: point(40, 42))
        lower.line(to: point(28, 30))
        lower.line(to: point(40, 18))
        for path in [upper, lower] {
            path.lineWidth = rect.width * 0.085
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
        }
        return [upper, lower]
    }

    /// A small filled dot in the free top-right corner marks "keep awake".
    static func menuImage(keepingAwake: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 20), flipped: false) { rect in
            NSColor.black.setStroke()
            for path in paths(in: rect) { path.stroke() }
            if keepingAwake {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 4.5, y: rect.maxY - 4.5, width: 3.5, height: 3.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = keepingAwake ? "SSwitcher, не засыпать" : "SSwitcher"
        return image
    }
}
