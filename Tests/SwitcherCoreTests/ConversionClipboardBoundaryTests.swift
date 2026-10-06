import Foundation
import XCTest

final class ConversionClipboardBoundaryTests: XCTestCase {
    func testConversionSourcesCannotAccessPasteboardOrIssueCopyPasteShortcuts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
        let shortcut = try NSRegularExpression(pattern: #"\(\s*(?:CGKeyCode\(\s*)?(8|9|0x08|0x09)\s*\)?\s*,\s*(?:\.|CGEventFlags\.)maskCommand"#)
        for forbidden in ["(8, .maskCommand)", "(CGKeyCode(9), CGEventFlags.maskCommand)"] {
            XCTAssertEqual(shortcut.numberOfMatches(in: forbidden, range: NSRange(forbidden.startIndex..., in: forbidden)), 1)
        }
        var clipboardFiles: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("NSPasteboard") { clipboardFiles.append(url.lastPathComponent) }
            XCTAssertFalse(source.contains("PasteboardTransaction"), url.path)
            XCTAssertEqual(shortcut.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)), 0, url.path)
        }
        // Explicitly copying a diagnostic report is the one user-requested UI
        // action allowed to write the general pasteboard; conversion has none.
        XCTAssertEqual(clipboardFiles, ["DiagnosticsWindow.swift"])
    }
}
