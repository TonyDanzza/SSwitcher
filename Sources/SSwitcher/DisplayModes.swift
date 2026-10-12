import CoreGraphics
import Foundation

/// One selectable display mode. `index` is SkyLight's mode number when the
/// full list was read; otherwise `mode` is the public CoreGraphics mode.
struct DisplayModeEntry {
    let width: Int, height: Int
    let hiDPI: Bool
    let refreshRate: Double
    let index: Int32?
    let mode: CGDisplayMode?
}

/// The public `CGDisplayCopyAllDisplayModes` hides the HiDPI mode that looks
/// like the panel's own resolution (2560 × 1440 drawn at 5120 × 2880): on the
/// user's LG it returned 110 of 126 modes. System Settings and displayplacer
/// read SkyLight's full list; SSwitcher does the same, read-only, and falls
/// back to the public list when the private symbols are missing.
enum DisplayModes {
    private typealias CountFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Void
    private typealias DescribeFunction = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> Void
    private typealias ConfigureFunction = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> CGError

    /// displayplacer's `modes_D4`: 0xDC bytes; width and height at 8 and 12,
    /// refresh rate (UInt16) at 190, scale (Float) at 208.
    private static let descriptionSize = 0xDC

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let count: CountFunction? = symbol("CGSGetNumberOfDisplayModes")
    private static let describe: DescribeFunction? = symbol("CGSGetDisplayModeDescriptionOfLength")
    private static let configure: ConfigureFunction? = symbol("CGSConfigureDisplayMode")

    private static func symbol<T>(_ name: String) -> T? {
        guard let skyLight, let pointer = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static func all(_ display: CGDirectDisplayID) -> [DisplayModeEntry] {
        if let count, let describe, configure != nil {
            var total: Int32 = 0
            count(display, &total)
            if total > 0 && total < 10_000 {
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: descriptionSize, alignment: 8)
                defer { buffer.deallocate() }
                let entries = (0..<total).compactMap { index -> DisplayModeEntry? in
                    memset(buffer, 0, descriptionSize)
                    describe(display, index, buffer, Int32(descriptionSize))
                    let width = Int(buffer.load(fromByteOffset: 8, as: UInt32.self))
                    let height = Int(buffer.load(fromByteOffset: 12, as: UInt32.self))
                    let rate = Double(buffer.load(fromByteOffset: 190, as: UInt16.self))
                    let scale = buffer.load(fromByteOffset: 208, as: Float.self)
                    guard width >= 640, height >= 400, width <= 16_384, scale >= 1, scale <= 4 else { return nil }
                    return DisplayModeEntry(width: width, height: height, hiDPI: scale > 1, refreshRate: rate, index: index, mode: nil)
                }
                if !entries.isEmpty { return entries }
            }
        }
        return (CGDisplayCopyAllDisplayModes(display, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary)
                as? [CGDisplayMode] ?? []).filter { $0.isUsableForDesktopGUI() }.map {
            DisplayModeEntry(width: $0.width, height: $0.height, hiDPI: $0.pixelWidth > $0.width,
                             refreshRate: $0.refreshRate, index: nil, mode: $0)
        }
    }

    /// Applies `entry` as the display's saved mode.
    static func apply(_ entry: DisplayModeEntry, to display: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        let result: CGError
        if let index = entry.index, let configure { result = configure(config, display, index) }
        else if let mode = entry.mode { result = CGConfigureDisplayWithDisplayMode(config, display, mode, nil) }
        else { result = .illegalArgument }
        guard result == .success else { CGCancelDisplayConfiguration(config); return false }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }
}
