import XCTest
@testable import SwitcherCore

final class FunctionKeyPolicyTests: XCTestCase {
    func testApplicationsWithoutRuleFollowTheBaseMode() {
        let policy = FunctionKeyPolicy(base: .media, applications: ["com.apple.dt.Xcode": .standard])
        XCTAssertEqual(policy.mode(for: "com.apple.Safari"), .media)
        XCTAssertEqual(policy.mode(for: nil), .media)
        XCTAssertEqual(policy.mode(for: "com.apple.dt.Xcode"), .standard)
    }

    func testToggleChangesTheBaseOnlyOutsideRuleApplications() {
        var policy = FunctionKeyPolicy(base: .media, applications: ["com.apple.dt.Xcode": .standard])
        XCTAssertTrue(policy.toggle(for: "com.apple.Safari"))
        XCTAssertEqual(policy.base, .standard)
        XCTAssertEqual(policy.rule(for: "com.apple.dt.Xcode"), .standard)

        XCTAssertFalse(policy.toggle(for: "com.apple.dt.Xcode"))
        XCTAssertEqual(policy.base, .standard)
        XCTAssertEqual(policy.mode(for: "com.apple.dt.Xcode"), .media)
        XCTAssertEqual(policy.mode(for: "com.apple.Safari"), .standard)
    }

    func testToggleWithoutFrontmostApplicationChangesTheBase() {
        var policy = FunctionKeyPolicy(base: .standard)
        XCTAssertTrue(policy.toggle(for: nil))
        XCTAssertEqual(policy.base, .media)
    }

    func testRuleEqualToTheBaseStaysPinnedWhenTheBaseChanges() {
        var policy = FunctionKeyPolicy(base: .standard)
        policy.setRule(.standard, for: "com.apple.dt.Xcode")
        policy.toggle(for: "com.apple.Safari")
        XCTAssertEqual(policy.mode(for: "com.apple.dt.Xcode"), .standard)
        XCTAssertEqual(policy.mode(for: "com.apple.Safari"), .media)
    }

    func testRemovingRuleReturnsApplicationToTheBase() {
        var policy = FunctionKeyPolicy(base: .media, applications: ["com.apple.dt.Xcode": .standard])
        policy.setRule(nil, for: "com.apple.dt.Xcode")
        XCTAssertNil(policy.rule(for: "com.apple.dt.Xcode"))
        XCTAssertEqual(policy.mode(for: "com.apple.dt.Xcode"), .media)
        XCTAssertTrue(policy.applications.isEmpty)
    }

    func testModeRawValuesMatchTheSystemParameter() {
        XCTAssertEqual(FunctionKeyMode(rawValue: 0), .media)
        XCTAssertEqual(FunctionKeyMode(rawValue: 1), .standard)
        XCTAssertEqual(FunctionKeyMode.media.toggled, .standard)
    }
}
