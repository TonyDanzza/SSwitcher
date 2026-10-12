import Foundation

/// Steam's "Add to Applications" shortcut is a bundle without an identifier
/// whose executable runs `open steam://run/<appid>`. The game itself lives in
/// a library's `steamapps/common/<installdir>`. These text parsers find it.
public enum SteamShortcut {
    /// The app id in `steam://run/570` or `steam://rungameid/570`.
    public static func appID(fromScript script: String) -> String? {
        for marker in ["steam://run/", "steam://rungameid/"] {
            guard let range = script.range(of: marker) else { continue }
            let digits = script[range.upperBound...].prefix(while: { $0.isASCII && $0.isNumber })
            if !digits.isEmpty { return String(digits) }
        }
        return nil
    }

    /// `"installdir"  "dota 2 beta"` from an `appmanifest_<id>.acf`.
    public static func installDirectory(fromManifest manifest: String) -> String? {
        value(of: "installdir", in: manifest).first
    }

    /// Every `"path"` of `libraryfolders.vdf`.
    public static func libraryPaths(fromFolders vdf: String) -> [String] { value(of: "path", in: vdf) }

    /// Values of `"key"  "value"` lines; Steam escapes backslashes.
    private static func value(of key: String, in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            // ["\t", key, "\t\t", value, ""]
            guard parts.count >= 5, parts[1] == Substring(key), parts[2].allSatisfy(\.isWhitespace) else { return nil }
            let value = parts[3].replacingOccurrences(of: "\\\\", with: "\\")
            return value.isEmpty ? nil : value
        }
    }
}
