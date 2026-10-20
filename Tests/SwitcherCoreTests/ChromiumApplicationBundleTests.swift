import XCTest
@testable import SwitcherCore

final class ChromiumApplicationBundleTests: XCTestCase {
    func testRendererHelperIdentifiesChromium() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Browser.app")
        let helpers = app.appendingPathComponent("Contents/Frameworks/Browser Framework.framework/Helpers")
        try FileManager.default.createDirectory(at: helpers.appendingPathComponent("Browser Helper.app"), withIntermediateDirectories: true)
        XCTAssertFalse(ChromiumApplicationBundle.recognizes(app))
        try FileManager.default.createDirectory(at: helpers.appendingPathComponent("Browser Helper (Renderer).app"), withIntermediateDirectories: true)
        XCTAssertTrue(ChromiumApplicationBundle.recognizes(app))
        XCTAssertFalse(ChromiumApplicationBundle.recognizes(nil))
    }
}
