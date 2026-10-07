import Foundation
import XCTest
@testable import SwitcherCore

final class ElectronApplicationBundleTests: XCTestCase {
    private var root: URL!
    private let headerHash = String(repeating: "a1", count: 32)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SSwitcher-runtime-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func write(_ relativePath: String, data: Data = Data()) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func plist(_ relativePath: String, _ info: [String: Any]) throws {
        try write(relativePath, data: PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
    }

    private func appInfo(archive: Any? = nil, package: String = "APPL") -> [String: Any] {
        ["CFBundlePackageType": package,
         "ElectronAsarIntegrity": ["Resources/app.asar": archive ?? ["algorithm": "SHA256", "hash": headerHash]]]
    }

    private func brandedPackage() throws {
        try plist("Contents/Info.plist", appInfo())
        try write("Contents/Resources/app.asar")
        // Exercise the versioned symlinks used by a real renamed framework.
        let prefix = "Contents/Frameworks/Brand Framework.framework"
        try plist("\(prefix)/Versions/A/Resources/Info.plist", ["CFBundlePackageType": "FMWK", "CFBundleExecutable": "Brand Framework"])
        try write("\(prefix)/Versions/A/Brand Framework")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("\(prefix)/Resources"), withDestinationURL: root.appendingPathComponent("\(prefix)/Versions/A/Resources"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("\(prefix)/Brand Framework"), withDestinationURL: root.appendingPathComponent("\(prefix)/Versions/A/Brand Framework"))
    }

    func testStandardElectronFrameworkRetainsExistingPreparation() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"), withIntermediateDirectories: true)
        XCTAssertTrue(ElectronApplicationBundle.recognizes(root))
    }

    func testStandardFrameworkDirectorySymlinkRetainsExistingPreparation() throws {
        let real = root.appendingPathComponent("Contents/Frameworks/Versioned Engine.framework")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"), withDestinationURL: real)
        XCTAssertTrue(ElectronApplicationBundle.recognizes(root))
    }

    func testRenamedVersionedFrameworkIsRecognizedWithoutAppNameOrBundleID() throws {
        try brandedPackage()
        XCTAssertTrue(ElectronApplicationBundle.recognizes(root))
        // Runtime classification still cannot authorize a native text setter.
        XCTAssertEqual(TextReplacementBackend.select(isSelected: true, bundleID: "com.apple.TextEdit", isCurrentProcess: false,
                                                     isElectron: ElectronApplicationBundle.recognizes(root), role: "AXTextArea",
                                                     selectedTextSettable: true), .unicodeEvents)
    }

    func testNativeAndChromiumVersionMetadataAloneAreNotElectronProof() throws {
        XCTAssertFalse(ElectronApplicationBundle.recognizes(nil))
        try plist("Contents/Info.plist", ["CFBundlePackageType": "APPL", "ChromiumBaseVersion": "154.0.8037.98", "CFBundleName": "Electron"])
        try write("Contents/Resources/app.asar")
        XCTAssertFalse(ElectronApplicationBundle.recognizes(root))
    }

    func testMalformedOrUnsupportedIntegrityMetadataCannotEnablePreparation() throws {
        try brandedPackage()
        let candidates: [Any] = ["invalid", [:] as [String: String], ["algorithm": "SHA1", "hash": headerHash],
                             ["algorithm": "SHA256", "hash": ""], ["algorithm": "SHA256", "hash": String(repeating: "g", count: 64)],
                             ["algorithm": "SHA256", "hash": String(repeating: "a", count: 63)], ["algorithm": "SHA256", "hash": 123]]
        for archive in candidates {
            try plist("Contents/Info.plist", appInfo(archive: archive))
            XCTAssertFalse(ElectronApplicationBundle.recognizes(root))
        }
        try plist("Contents/Info.plist", appInfo(package: "FMWK"))
        XCTAssertFalse(ElectronApplicationBundle.recognizes(root))
    }

    func testMetadataRequiresAnActualArchiveAndPackagedFrameworkExecutable() throws {
        try brandedPackage()
        let archive = root.appendingPathComponent("Contents/Resources/app.asar")
        try FileManager.default.removeItem(at: archive)
        XCTAssertFalse(ElectronApplicationBundle.recognizes(root))
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        XCTAssertFalse(ElectronApplicationBundle.recognizes(root))
        try FileManager.default.removeItem(at: archive)
        try write("Contents/Resources/app.asar")
        let infoPath = "Contents/Frameworks/Brand Framework.framework/Versions/A/Resources/Info.plist"
        for info in [["CFBundlePackageType": "BNDL", "CFBundleExecutable": "Brand Framework"],
                     ["CFBundlePackageType": "FMWK", "CFBundleExecutable": "../../unrelated"],
                     ["CFBundlePackageType": "FMWK", "CFBundleExecutable": ""],
                     ["CFBundlePackageType": "FMWK", "CFBundleExecutable": "missing"]] {
            try plist(infoPath, info)
            XCTAssertFalse(ElectronApplicationBundle.recognizes(root))
        }
    }
}
