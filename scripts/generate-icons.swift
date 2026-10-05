import AppKit

@main
struct GenerateIcons {
    static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }
    static func render(size: Int, to url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(0x071126, alpha: 0.30)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -15)
        shadow.set()
        color(0x16213B).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [color(0x10182C), color(0x233B68), color(0x425B8D)])!.draw(in: tile, angle: 72)
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        NSGradient(starting: color(0xA8B9DA, alpha: 0.18), ending: color(0xA8B9DA, alpha: 0))!
            .draw(fromCenter: NSPoint(x: 250, y: 970), radius: 10, toCenter: NSPoint(x: 250, y: 970), radius: 880, options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        NSGraphicsContext.restoreGraphicsState()
        let rim = NSBezierPath(roundedRect: NSRect(x: 102, y: 102, width: 820, height: 820), xRadius: 184, yRadius: 184)
        color(0xD7E2F5, alpha: 0.22).setStroke()
        rim.lineWidth = 2
        rim.stroke()
        let markRect = NSRect(x: 112, y: 112, width: 800, height: 800)
        NSGraphicsContext.saveGraphicsState()
        let markShadow = NSShadow()
        markShadow.shadowColor = color(0x030B1B, alpha: 0.28)
        markShadow.shadowBlurRadius = 14
        markShadow.shadowOffset = NSSize(width: 0, height: -6)
        markShadow.set()
        color(0xF3F0E8).setStroke()
        for path in BrandIcon.paths(in: markRect) { path.stroke() }
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
    static func main() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources", isDirectory: true)
        let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
                try render(size: base * scale, to: iconset.appendingPathComponent(name))
            }
        }
        try render(size: 1024, to: resources.appendingPathComponent("AppIcon.png"))
    }
}
