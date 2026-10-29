import Foundation

/// A display override adds HiDPI ("looks like") sizes for one monitor model.
/// macOS reads it from `/Library/Displays/Contents/Resources/Overrides` at
/// boot and then renders those sizes itself, so nothing keeps running.
///
/// Each `scale-resolutions` entry is big-endian pixel width and height of the
/// 2x backing store followed by mode flags, written twice per size the way
/// one-key-hidpi does and the user's working LG override contains:
/// flags 0x1 (valid) and 0x1 + 0x200000 (valid, valid for mirroring).
public enum DisplayOverride {
    public static let directory = "/Library/Displays/Contents/Resources/Overrides"
    /// The value one-key-hidpi writes; the working LG override has it too.
    public static let targetDefaultPPMM = 10.0699301

    /// "DisplayVendorID-1e6d/DisplayProductID-5b96": lowercase hex, no padding.
    public static func relativePath(vendor: UInt32, model: UInt32) -> String {
        "DisplayVendorID-\(String(vendor, radix: 16))/DisplayProductID-\(String(model, radix: 16))"
    }

    static let candidateWidths = [3840, 3456, 3200, 3008, 2880, 2560, 2304, 2240, 2048, 1920, 1800, 1760,
                                  1680, 1600, 1504, 1440, 1360, 1280, 1152, 1024]

    /// "Looks like" sizes from the native panel size down to half of it, at
    /// the panel's aspect ratio. Larger than native is never offered: the
    /// backing store would exceed what Apple Silicon allows.
    public static func scaledSizes(nativeWidth: Int, nativeHeight: Int) -> [(width: Int, height: Int)] {
        guard nativeWidth > 0, nativeHeight > 0 else { return [] }
        let widths = Set(candidateWidths.filter { $0 <= nativeWidth && $0 * 2 >= nativeWidth } + [nativeWidth])
        return widths.sorted(by: >).map { width in
            (width, Int((Double(width) * Double(nativeHeight) / Double(nativeWidth)).rounded()))
        }
    }

    static func entry(width: Int, height: Int, flags: [UInt32]) -> Data {
        var data = Data()
        for value in [UInt32(width * 2), UInt32(height * 2)] + flags {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func plist(vendor: UInt32, model: UInt32, sizes: [(width: Int, height: Int)]) throws -> Data {
        var entries: [Data] = []
        for size in sizes {
            entries.append(entry(width: size.width, height: size.height, flags: [0x1]))
            entries.append(entry(width: size.width, height: size.height, flags: [0x1, 0x200000]))
        }
        let value: [String: Any] = [
            "DisplayVendorID": Int(vendor),
            "DisplayProductID": Int(model),
            "scale-resolutions": entries,
            "target-default-ppmm": targetDefaultPPMM
        ]
        return try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    /// Wraps a path for `/bin/sh` in single quotes.
    public static func shellQuoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
