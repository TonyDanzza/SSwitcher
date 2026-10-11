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
        // The UI may explicitly copy a diagnostic report. The service provider
        // may only read the packet supplied by the OS requestor.
        // The selected-only experiment may publish one private service response;
        // these exceptions never authorize pasteboards in legacy conversion.
        XCTAssertEqual(clipboardFiles.sorted(), ["DiagnosticsWindow.swift", "NativeSelectionServiceProof.swift", "NativeServicePacket.swift", "NativeServiceProvider.swift"])

        let service = try String(contentsOf: sourceRoot.appendingPathComponent("SSwitcher/NativeServiceProvider.swift"), encoding: .utf8)
        let acquireBoard = try NSRegularExpression(pattern: #"\bNSPasteboard\s*(?:\(|\.\s*(?:general|find|font|ruler|drag|withUniqueName|init)\b)"#)
        let modifyBoard = try NSRegularExpression(pattern: #"\.\s*(?:write\w*|clear\w*|declare\w*|redeclare\w*|addTypes|setString|setData|setPropertyList|prepareForNewContents|releaseGlobally)\s*\("#)
        let serviceRange = NSRange(service.startIndex..., in: service)
        XCTAssertEqual(acquireBoard.numberOfMatches(in: service, range: serviceRange), 0,
                       "The service must use only its supplied packet, never acquire or create a board")
        XCTAssertFalse(service.contains("NSGetPasteboard"))
        XCTAssertEqual(modifyBoard.numberOfMatches(in: service, range: serviceRange), 0,
                       "The phase-one service must not clear, declare or write any pasteboard")

        let selected = try String(contentsOf: sourceRoot.appendingPathComponent("SSwitcher/NativeSelectionServiceProof.swift"), encoding: .utf8)
        let selectedRange = NSRange(selected.startIndex..., in: selected)
        XCTAssertEqual(acquireBoard.numberOfMatches(in: selected, range: selectedRange), 0,
                       "The selected service must also use only the supplied board")
        let mutations = modifyBoard.matches(in: selected, range: selectedRange).map { (selected as NSString).substring(with: $0.range) }
        XCTAssertEqual(mutations, [".declareTypes(", ".setString("],
                       "Only one plain-type declaration and one response publication are permitted")
        XCTAssertFalse(selected.contains("NSGetPasteboard"))
        XCTAssertFalse(selected.contains("TISSelectInputSource"))
        let callbackStart = try XCTUnwrap(selected.range(of: "    private func convert("))
        let callbackEnd = try XCTUnwrap(selected.range(of: "    private func foregroundMatches", range: callbackStart.upperBound..<selected.endIndex))
        let callback = String(selected[callbackStart.lowerBound..<callbackEnd.lowerBound])
        XCTAssertFalse(callback.contains("AXUIElement"), "The waiting service host must not receive AX IPC")
        XCTAssertFalse(callback.contains("captureWindow("))
        for forbidden in ["AXUIElementSetAttributeValue", "AXUIElementPerformAction", "CGEvent", ".activate("] {
            XCTAssertFalse(selected.contains(forbidden), "Arming must not activate, type into or mutate a foreign client")
        }
        let diagnosticStart = try XCTUnwrap(service.range(of: "    func checkNativeSelection("))
        let diagnosticEnd = try XCTUnwrap(service.range(of: "    @objc(checkNativeEditable", range: diagnosticStart.upperBound..<service.endIndex))
        let diagnosticCallback = String(service[diagnosticStart.lowerBound..<diagnosticEnd.lowerBound])
        XCTAssertFalse(diagnosticCallback.contains("AXUIElement"))
        XCTAssertFalse(diagnosticCallback.contains("captureWindow("))

        // Name comparisons used to reject standard boards are permitted;
        // obtaining those boards or publishing replacement data is forbidden.
        let comparison = "name != NSPasteboard.Name.general"
        XCTAssertEqual(acquireBoard.numberOfMatches(in: comparison, range: NSRange(comparison.startIndex..., in: comparison)), 0)
        for forbidden in ["NSPasteboard.general", "NSPasteboard(name: .find)", "NSPasteboard.withUniqueName()"] {
            XCTAssertEqual(acquireBoard.numberOfMatches(in: forbidden, range: NSRange(forbidden.startIndex..., in: forbidden)), 1)
        }
        for method in ["clearContents", "declareTypes", "addTypes", "setString", "setData", "setPropertyList", "writeObjects", "prepareForNewContents"] {
            let forbidden = "packet.\(method)(payload)"
            XCTAssertEqual(modifyBoard.numberOfMatches(in: forbidden, range: NSRange(forbidden.startIndex..., in: forbidden)), 1)
        }
    }
}
