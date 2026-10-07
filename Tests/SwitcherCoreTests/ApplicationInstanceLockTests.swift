import Darwin
import Foundation
import XCTest
@testable import SwitcherCore

final class ApplicationInstanceLockTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SSwitcher-instance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testIndependentOpenCannotClaimUntilTheOwnerReleasesItsLease() throws {
        let path = root.appendingPathComponent("instance.lock")
        var owner: ApplicationInstanceLock? = try XCTUnwrap(ApplicationInstanceLock.acquire(at: path))
        XCTAssertNotNil(owner)
        XCTAssertNil(ApplicationInstanceLock.acquire(at: path))
        owner = nil
        // A stale pathname does not prevent recovery after exit; the same
        // inode remains, avoiding an unlink/create race between contenders.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let next = try XCTUnwrap(ApplicationInstanceLock.acquire(at: path))
        withExtendedLifetime(next) { XCTAssertNil(ApplicationInstanceLock.acquire(at: path)) }
    }

    func testLockIsPrivateAndSymlinksOrDirectoriesAreRefused() throws {
        let path = root.appendingPathComponent("instance.lock")
        let owner = try XCTUnwrap(ApplicationInstanceLock.acquire(at: path))
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(try XCTUnwrap(permissions).intValue & 0o777, 0o600)
        let alias = root.appendingPathComponent("alias.lock")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: path)
        withExtendedLifetime(owner) { XCTAssertNil(ApplicationInstanceLock.acquire(at: alias)) }
        XCTAssertNil(ApplicationInstanceLock.acquire(at: root))
        XCTAssertNil(ApplicationInstanceLock.acquire(at: root.appendingPathComponent("missing/instance.lock")))
    }
}
