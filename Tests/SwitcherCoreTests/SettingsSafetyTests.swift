import Foundation
import XCTest
@testable import SwitcherCore

final class SettingsSafetyTests: XCTestCase {
    func testOutOfRangeShortcutModifiersAreRejected() {
        for flags in [-1, Int(UInt32.max) + 1, Int.max] {
            XCTAssertNil(KeyShortcut(storage: ["keyCode": 3, "modifiers": flags]))
            XCTAssertNil(MouseButtonBinding(storage: ["button": 3, "modifiers": flags, "action": "back"]))
            XCTAssertNil(MouseButtonBinding(storage: ["button": 3, "modifiers": 0, "action": "shortcut",
                                                      "keyCode": 3, "keyModifiers": flags]))
        }
        XCTAssertEqual(KeyShortcut(storage: KeyShortcut.functionKeyToggle.storage), .functionKeyToggle)
        let binding = MouseButtonBinding(button: 3, action: .shortcut(KeyShortcut(keyCode: 13, modifiers: .command)))!
        XCTAssertEqual(MouseButtonBinding(storage: binding.storage), binding)
        XCTAssertEqual(MouseButtonBinding(storage: ["button": 3, "modifiers": 0, "action": "shortcut"])?.action,
                       .shortcut(nil))
    }

    func testModeChangesPreserveDeadlineInsteadOfRestartingTimer() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let end = start.addingTimeInterval(600)
        let initial = try XCTUnwrap(KeepAwakeConfiguration(systemOnly: false, endDate: end, now: start))
        let changed = try XCTUnwrap(KeepAwakeConfiguration(systemOnly: true, endDate: end, now: start.addingTimeInterval(580.5)))
        XCTAssertEqual(initial.timeout, 600)
        XCTAssertEqual(changed.timeout, 19.5)
        XCTAssertTrue(changed.systemOnly)
        XCTAssertNil(KeepAwakeConfiguration(systemOnly: true, endDate: end, now: end))
        XCTAssertNil(KeepAwakeConfiguration(systemOnly: false, endDate: end, now: end.addingTimeInterval(1)))
        XCTAssertNil(try XCTUnwrap(KeepAwakeConfiguration(systemOnly: true, endDate: nil, now: start)).timeout)
    }
}

final class DisplayOverrideRemovalTests: XCTestCase {
    private func withFolder(_ test: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sswitcher-removal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try test(root)
    }

    private func run(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testRemovalBacksUpBothFilesAndPreservesNeighbors() throws {
        try withFolder { root in
            let target = root.appendingPathComponent("DisplayProductID-it's $(literal)")
            let icon = URL(fileURLWithPath: target.path + ".icns")
            let neighbor = root.appendingPathComponent("other-monitor")
            let backup = root.appendingPathComponent("backup")
            try Data("plist".utf8).write(to: target)
            try Data("icon".utf8).write(to: icon)
            try Data("neighbor".utf8).write(to: neighbor)
            let plan = try DisplayOverrideRemoval(target: target.path, backupDirectory: backup)
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try run(plan.command), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: icon.path))
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(target.lastPathComponent)), Data("plist".utf8))
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(icon.lastPathComponent)), Data("icon".utf8))
            XCTAssertEqual(try Data(contentsOf: neighbor), Data("neighbor".utf8))
        }
    }

    func testDeletionFailureIsNotReportedAsSuccessAndBackupSurvives() throws {
        try withFolder { root in
            let target = root.appendingPathComponent("DisplayProductID-test")
            try Data("original".utf8).write(to: target)
            let backup = root.appendingPathComponent("backup")
            let plan = try DisplayOverrideRemoval(target: target.path, backupDirectory: backup)
            // A directory cannot be removed by rm -f. Simulate a changed target.
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            XCTAssertNotEqual(try run(plan.command), 0)
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(target.lastPathComponent)), Data("original".utf8))
        }
    }

    func testBackupFailureLeavesOriginalFilesUntouched() throws {
        try withFolder { root in
            let target = root.appendingPathComponent("DisplayProductID-test")
            let backup = root.appendingPathComponent("backup")
            try Data("original".utf8).write(to: target)
            try Data("not-a-directory".utf8).write(to: backup)
            XCTAssertThrowsError(try DisplayOverrideRemoval(target: target.path, backupDirectory: backup))
            XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
        }
    }

    func testIconAloneIsBackedUpAndRemoved() throws {
        try withFolder { root in
            let target = root.appendingPathComponent("DisplayProductID-test")
            let icon = URL(fileURLWithPath: target.path + ".icns")
            let backup = root.appendingPathComponent("backup")
            try Data("icon".utf8).write(to: icon)
            let plan = try DisplayOverrideRemoval(target: target.path, backupDirectory: backup)
            XCTAssertEqual(try run(plan.command), 0)
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(icon.lastPathComponent)), Data("icon".utf8))
        }
    }
}
