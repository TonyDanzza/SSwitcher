import XCTest
@testable import SwitcherCore

final class WindowShortcutDirectionsTests: XCTestCase {
    private func display(_ id: UInt32, _ frame: CGRect) -> WindowDisplay {
        WindowDisplay(id: id, frame: frame, visibleFrame: frame.insetBy(dx: 0, dy: 10))
    }

    func testMonitorAboveMacBookUsesOnlyUpAndDown() {
        let lg = display(1, CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let macBook = display(2, CGRect(x: 579, y: 1440, width: 1470, height: 956))
        XCTAssertEqual(WindowShortcutDirections.available(in: [lg, macBook]), [.up, .down])
    }

    func testSideBySideDisplaysUseLeftAndRight() {
        let left = display(1, CGRect(x: 0, y: 0, width: 1470, height: 956))
        let right = display(2, CGRect(x: 1470, y: -200, width: 2560, height: 1440))
        XCTAssertEqual(WindowShortcutDirections.available(in: [left, right]), [.left, .right])
    }

    func testSingleAndMirroredDisplaysUseNoArrows() {
        let frame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        XCTAssertEqual(WindowShortcutDirections.available(in: [display(1, frame)]), [])
        XCTAssertEqual(WindowShortcutDirections.available(in: [display(1, frame), display(2, frame)]), [])
    }

    func testThreeDisplaysCombineDirections() {
        let center = display(1, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let above = display(2, CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        let right = display(3, CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(WindowShortcutDirections.available(in: [center, above, right]), Set(WindowMoveDirection.allCases))
    }

    func testManualChoiceIgnoresTopology() {
        let only = display(1, CGRect(x: 0, y: 0, width: 1470, height: 956))
        XCTAssertEqual(WindowShortcutDirections.resolve(.manual([.left]), displays: [only]), [.left])
        XCTAssertEqual(WindowShortcutDirections.resolve(.automatic, displays: [only]), [])
        XCTAssertEqual(WindowShortcutDirections.arrows([.down, .up, .left]), "←↑↓")
    }
}

final class KeyShortcutTests: XCTestCase {
    func testDefaultToggleIsValidAndRoundTrips() {
        let shortcut = KeyShortcut.functionKeyToggle
        XCTAssertNil(shortcut.problem)
        XCTAssertEqual(shortcut.modifiers.symbols, "⌃⌥⌘")
        XCTAssertEqual(KeyShortcut(storage: shortcut.storage), shortcut)
    }

    func testRejectsShortcutsWithoutCommandOptionOrControl() {
        XCTAssertEqual(KeyShortcut(keyCode: 3, modifiers: []).problem, .needsModifier)
        XCTAssertEqual(KeyShortcut(keyCode: 3, modifiers: .shift).problem, .needsModifier)
        XCTAssertNil(KeyShortcut(keyCode: 105, modifiers: []).problem, "F13 works alone")
        XCTAssertEqual(KeyShortcut(keyCode: 122, modifiers: []).problem, .needsModifier, "F1 needs a modifier")
    }

    func testRejectsReservedSystemShortcutsAndModifierKeys() {
        XCTAssertEqual(KeyShortcut(keyCode: 12, modifiers: .command).problem, .reserved)
        XCTAssertEqual(KeyShortcut(keyCode: 49, modifiers: .command).problem, .reserved)
        XCTAssertNil(KeyShortcut(keyCode: 12, modifiers: [.command, .option]).problem)
        XCTAssertEqual(KeyShortcut(keyCode: 56, modifiers: .command).problem, .modifierKey)
    }

    func testStorageRejectsInvalidValues() {
        XCTAssertNil(KeyShortcut(storage: nil))
        XCTAssertNil(KeyShortcut(storage: ["keyCode": 12, "modifiers": 0x0100]))
        XCTAssertNil(KeyShortcut(storage: ["keyCode": -1, "modifiers": 0x0800]))
        XCTAssertEqual(KeyShortcut(keyCode: 3, modifiers: .init(rawValue: 0x1800 | 0x4000)).modifiers, [.control, .option])
    }
}

final class DoubleShiftKeyChoiceTests: XCTestCase {
    private func tap(_ detector: inout DoubleShiftDetector, key: UInt16, at time: Double) -> Bool {
        _ = detector.shiftChanged(key: key, anyShiftDown: true, otherModifierDown: false, time: time)
        return detector.shiftChanged(key: key, anyShiftDown: false, otherModifierDown: false, time: time + 0.05)
    }

    func testOnlyLeftShiftIgnoresRightShiftPairs() {
        var detector = DoubleShiftDetector()
        detector.keys = [56]
        XCTAssertFalse(tap(&detector, key: 60, at: 0))
        XCTAssertFalse(tap(&detector, key: 60, at: 0.15))
        XCTAssertFalse(tap(&detector, key: 56, at: 1))
        XCTAssertTrue(tap(&detector, key: 56, at: 1.15))
    }

    func testLongerIntervalAcceptsSlowerPair() {
        var detector = DoubleShiftDetector()
        XCTAssertFalse(tap(&detector, key: 56, at: 0))
        XCTAssertFalse(tap(&detector, key: 56, at: 0.4))
        detector.reset()
        detector.interval = 0.5
        XCTAssertFalse(tap(&detector, key: 56, at: 1))
        XCTAssertTrue(tap(&detector, key: 56, at: 1.4))
    }
}

final class ShortcutConflictsTests: XCTestCase {
    private func entry(_ id: Int, enabled: Bool, code: Int, flags: Int, type: String = "standard") -> [String: Any] {
        ["enabled": enabled ? 1 : 0, "value": ["parameters": [65535, code, flags], "type": type]]
    }

    func testFindsDefaultSystemShortcutsUnlessDisabled() {
        let spotlight = KeyShortcut(keyCode: 49, modifiers: .command)
        XCTAssertEqual(ShortcutConflicts.systemConflict(spotlight, stored: []), "Поиск Spotlight")
        let stored = ShortcutConflicts.parse(["64": entry(64, enabled: false, code: 49, flags: 0x100000)]).shortcuts
        XCTAssertNil(ShortcutConflicts.systemConflict(spotlight, stored: stored))
    }

    func testStoredShortcutOverridesDefaultAndIgnoresFnFlag() {
        // Control+F1 as macOS stores it: Control plus the Fn flag.
        let stored = ShortcutConflicts.parse(["12": entry(12, enabled: true, code: 122, flags: 8650752)]).shortcuts
        XCTAssertEqual(ShortcutConflicts.systemConflict(KeyShortcut(keyCode: 122, modifiers: .control), stored: stored),
                       "Управление с клавиатуры")
        let moved = ShortcutConflicts.parse(["64": entry(64, enabled: true, code: 49, flags: 0x40000 | 0x80000)]).shortcuts
        XCTAssertNil(ShortcutConflicts.systemConflict(KeyShortcut(keyCode: 49, modifiers: .command), stored: moved))
        XCTAssertNotNil(ShortcutConflicts.systemConflict(KeyShortcut(keyCode: 49, modifiers: [.control, .option]), stored: moved))
    }

    func testFixedAndApplicationShortcuts() {
        XCTAssertEqual(ShortcutConflicts.systemConflict(KeyShortcut(keyCode: 49, modifiers: [.control, .command]), stored: []),
                       "Эмодзи и символы")
        XCTAssertNotNil(ShortcutConflicts.applicationConflict(KeyShortcut(keyCode: 1, modifiers: .command)))
        XCTAssertNil(ShortcutConflicts.applicationConflict(.functionKeyToggle))
        XCTAssertNil(ShortcutConflicts.systemConflict(.functionKeyToggle, stored: []))
    }

    func testDoubleTapConflictComesFromModifierEntries() {
        let parsed = ShortcutConflicts.parse(["164": entry(164, enabled: true, code: 65535, flags: 0x40000, type: "modifier")])
        XCTAssertEqual(ShortcutConflicts.doubleTapConflict(.control, stored: parsed.doubleTaps), "Диктовка")
        XCTAssertNil(ShortcutConflicts.doubleTapConflict(.shift, stored: parsed.doubleTaps))
    }

    func testArrowConflictsNameSystemThenEditing() {
        XCTAssertEqual(ShortcutConflicts.arrowConflict(.control, .left, stored: []), "Рабочий стол слева")
        XCTAssertEqual(ShortcutConflicts.arrowConflict([.option, .shift], .left, stored: []), "выделение по словам в тексте")
        XCTAssertNil(ShortcutConflicts.arrowConflict([.control, .option], .up, stored: []))
    }
}

final class TriggerKeyTests: XCTestCase {
    func testOptionDoubleTapIgnoresShift() {
        var detector = DoubleShiftDetector()
        detector.pair = TriggerKey.option.codes
        detector.keys = TriggerSide.any.keys(of: .option)
        func tap(_ key: UInt16, _ time: Double) -> Bool {
            _ = detector.shiftChanged(key: key, anyShiftDown: true, otherModifierDown: false, time: time)
            return detector.shiftChanged(key: key, anyShiftDown: false, otherModifierDown: false, time: time + 0.05)
        }
        XCTAssertFalse(tap(56, 0))
        XCTAssertFalse(tap(56, 0.15))
        XCTAssertFalse(tap(58, 1))
        XCTAssertTrue(tap(58, 1.15))
        XCTAssertEqual(TriggerSide.left.phrase(.option), "Двойной левый ⌥")
        XCTAssertEqual(TriggerSide.any.phrase(.shift), "Двойной Shift")
    }
}

final class SteamShortcutTests: XCTestCase {
    func testReadsAppIDInstallDirectoryAndLibraries() {
        XCTAssertEqual(SteamShortcut.appID(fromScript: "#!/bin/bash\n# autogenerated file - do not edit\nopen steam://run/570\n"), "570")
        XCTAssertEqual(SteamShortcut.appID(fromScript: "open steam://rungameid/4425970"), "4425970")
        XCTAssertNil(SteamShortcut.appID(fromScript: "open -a Safari"))
        let manifest = "\"AppState\"\n{\n\t\"appid\"\t\t\"570\"\n\t\"name\"\t\t\"Dota 2\"\n\t\"installdir\"\t\t\"dota 2 beta\"\n}\n"
        XCTAssertEqual(SteamShortcut.installDirectory(fromManifest: manifest), "dota 2 beta")
        let folders = "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"/Users/me/Library/Application Support/Steam\"\n\t\t\"label\"\t\t\"\"\n\t}\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"/Volumes/Games/SteamLibrary\"\n\t}\n}\n"
        XCTAssertEqual(SteamShortcut.libraryPaths(fromFolders: folders), ["/Users/me/Library/Application Support/Steam", "/Volumes/Games/SteamLibrary"])
    }
}

final class DisplayOverrideTests: XCTestCase {
    func testPathMatchesTheWorkingLGOverride() {
        XCTAssertEqual(DisplayOverride.relativePath(vendor: 0x1e6d, model: 0x5b96), "DisplayVendorID-1e6d/DisplayProductID-5b96")
    }

    func testSizesRunFromNativeToHalfAtTheAspectRatio() {
        let sizes = DisplayOverride.scaledSizes(nativeWidth: 2560, nativeHeight: 1440)
        XCTAssertEqual(sizes.first?.width, 2560)
        XCTAssertEqual(sizes.first?.height, 1440)
        XCTAssertEqual(sizes.last?.width, 1280)
        XCTAssertTrue(sizes.contains { $0 == (1920, 1080) })
        XCTAssertTrue(sizes.contains { $0 == (1680, 945) })
        XCTAssertFalse(sizes.contains { $0.width > 2560 || $0.width < 1280 })
        XCTAssertEqual(DisplayOverride.scaledSizes(nativeWidth: 3440, nativeHeight: 1440).first?.width, 3440)
        XCTAssertTrue(DisplayOverride.scaledSizes(nativeWidth: 0, nativeHeight: 0).isEmpty)
    }

    func testEntriesEncodeLikeOneKeyHiDPI() throws {
        // The user's file: 2560x1440 looks-like as 5120x2880 with flags 1 and 1, 0x200000.
        XCTAssertEqual(DisplayOverride.entry(width: 2560, height: 1440, flags: [0x1]),
                       Data([0, 0, 0x14, 0, 0, 0, 0x0b, 0x40, 0, 0, 0, 1]))
        XCTAssertEqual(Data(base64Encoded: "AAAUAAAAC0AAAAABACAAAA=="),
                       DisplayOverride.entry(width: 2560, height: 1440, flags: [0x1, 0x200000]))
        let plist = try DisplayOverride.plist(vendor: 0x1e6d, model: 0x5b96, sizes: [(2560, 1440), (1920, 1080)])
        let value = try XCTUnwrap(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        XCTAssertEqual(value["DisplayVendorID"] as? Int, 7789)
        XCTAssertEqual(value["DisplayProductID"] as? Int, 23446)
        XCTAssertEqual((value["scale-resolutions"] as? [Data])?.count, 4)
        XCTAssertEqual(DisplayOverride.backingSizes(in: plist).map(\.width), [5120, 3840])
    }

    func testShellQuoting() {
        XCTAssertEqual(DisplayOverride.shellQuoted("/a b/it's"), "'/a b/it'\\''s'")
    }
}
