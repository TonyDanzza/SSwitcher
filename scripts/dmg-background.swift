import AppKit

// Retina artwork in points, matching dmg-settings.py's Finder window.
let size = NSSize(width: 640, height: 380)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 760,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedWhite: 0.965, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

func text(_ value: String, y: CGFloat, font: NSFont, color: NSColor) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    (value as NSString).draw(in: NSRect(x: 24, y: y, width: 592, height: 36),
        withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
}
text("SSwitcher", y: 294, font: .systemFont(ofSize: 29, weight: .semibold),
     color: NSColor(calibratedWhite: 0.14, alpha: 1))
text("Перетащите приложение в «Программы»", y: 257,
     font: .systemFont(ofSize: 15), color: NSColor(calibratedWhite: 0.42, alpha: 1))

let arrow = NSBezierPath()
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 291, y: 190))
arrow.line(to: NSPoint(x: 349, y: 190))
arrow.move(to: NSPoint(x: 338, y: 201))
arrow.line(to: NSPoint(x: 349, y: 190))
arrow.line(to: NSPoint(x: 338, y: 179))
NSColor(calibratedWhite: 0.58, alpha: 1).setStroke()
arrow.stroke()
text("Затем откройте SSwitcher из папки «Программы»", y: 48,
     font: .systemFont(ofSize: 13), color: NSColor(calibratedWhite: 0.46, alpha: 1))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .tiff, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
