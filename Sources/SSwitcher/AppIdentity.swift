import AppKit
import SwitcherCore

/// Names, icons and pickers for applications chosen in Settings, and the
/// menu-item form of a shortcut.
enum AppIdentity {
    private static let pathsKey = "applicationPaths"

    /// The bundle the user picked comes first: for a Steam game that is the
    /// "Dota 2" shortcut with its icon, not the game's inner "dota2".
    static func url(of bundleID: String) -> URL? {
        if let path = (UserDefaults.standard.dictionary(forKey: pathsKey) as? [String: String])?[bundleID],
           FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private static func remember(_ bundleID: String, at url: URL) {
        var paths = UserDefaults.standard.dictionary(forKey: pathsKey) as? [String: String] ?? [:]
        paths[bundleID] = url.path
        UserDefaults.standard.set(paths, forKey: pathsKey)
    }

    /// The bundle's identifier or, for a Steam shortcut, the installed game's.
    static func bundleIdentifier(at url: URL) -> String? {
        if let id = Bundle(url: url)?.bundleIdentifier { return id }
        return steamGameIdentifier(shortcut: url)
    }

    /// Shortcut script → app id → library manifest → install folder → the
    /// first application bundle with an identifier, at most five levels down.
    private static func steamGameIdentifier(shortcut: URL) -> String? {
        let fileManager = FileManager.default
        guard let executable = Bundle(url: shortcut)?.executableURL,
              let size = (try? fileManager.attributesOfItem(atPath: executable.path))?[.size] as? Int, size < 64 * 1024,
              let script = try? String(contentsOf: executable, encoding: .utf8),
              let appID = SteamShortcut.appID(fromScript: script) else { return nil }
        let steam = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        var libraries = [steam.path]
        for list in ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"] {
            if let text = try? String(contentsOf: steam.appendingPathComponent(list), encoding: .utf8) {
                libraries += SteamShortcut.libraryPaths(fromFolders: text)
            }
        }
        var seen = Set<String>()
        for library in libraries where seen.insert(library).inserted {
            let apps = URL(fileURLWithPath: library).appendingPathComponent("steamapps")
            guard let manifest = try? String(contentsOf: apps.appendingPathComponent("appmanifest_\(appID).acf"), encoding: .utf8),
                  let folder = SteamShortcut.installDirectory(fromManifest: manifest) else { continue }
            let root = apps.appendingPathComponent("common").appendingPathComponent(folder)
            guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if walker.level > 5 { walker.skipDescendants(); continue }
                if url.pathExtension == "app", let id = Bundle(url: url)?.bundleIdentifier { return id }
            }
        }
        return nil
    }

    static func name(of bundleID: String, fallback: String? = nil) -> String {
        if let url = url(of: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return fallback ?? bundleID
    }

    static func icon(of bundleID: String) -> NSImage {
        if let url = url(of: bundleID) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }

    /// Ordinary running applications, except SSwitcher, sorted by name.
    static func runningApplications(excluding: Set<String>) -> [(id: String, name: String)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app -> (String, String)? in
            guard let id = FunctionKeyController.bundleID(app), !excluding.contains(id), seen.insert(id).inserted else { return nil }
            return (id, app.localizedName ?? name(of: id))
        }.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }.map { (id: $0.0, name: $0.1) }
    }

    /// Lets the user pick any application bundle; returns its identifier.
    static func chooseApplication() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Выберите программу"
        panel.prompt = "Добавить"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let id = bundleIdentifier(at: url) else {
            let name = FileManager.default.displayName(atPath: url.path)
            let alert = NSAlert()
            alert.messageText = "Не получается добавить «\(name)»"
            alert.informativeText = "У этой программы нет идентификатора, по которому SSwitcher её узнаёт. Запустите её и выберите в списке «Запущенные» кнопки «Добавить программу»."
            alert.addButton(withTitle: "Понятно")
            alert.runModal()
            return nil
        }
        remember(id, at: url)
        return id
    }

    /// Shows `shortcut` at the right edge of a menu item. The menu never
    /// handles it: the registered Carbon shortcut consumes the keystroke.
    static func show(_ shortcut: KeyShortcut, on item: NSMenuItem) {
        guard let key = keyEquivalent(shortcut.keyCode) else { return }
        item.keyEquivalent = key
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.control) { mask.insert(.control) }
        if shortcut.modifiers.contains(.option) { mask.insert(.option) }
        if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
        if shortcut.modifiers.contains(.command) { mask.insert(.command) }
        item.keyEquivalentModifierMask = mask
    }

    private static func keyEquivalent(_ code: UInt32) -> String? {
        let function: [UInt32: Int] = [122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
                                       103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20]
        let special: [UInt32: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey,
                                      126: NSUpArrowFunctionKey, 115: NSHomeFunctionKey, 119: NSEndFunctionKey,
                                      116: NSPageUpFunctionKey, 121: NSPageDownFunctionKey, 117: NSDeleteFunctionKey]
        if let n = function[code], let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) { return String(Character(scalar)) }
        if let value = special[code], let scalar = UnicodeScalar(value) { return String(Character(scalar)) }
        switch code {
        case 36: return "\r"
        case 48: return "\t"
        case 49: return " "
        case 51: return "\u{8}"
        case 53: return "\u{1b}"
        default: return InputSources.asciiCharacter(forKeyCode: UInt16(code))?.lowercased()
        }
    }
}
