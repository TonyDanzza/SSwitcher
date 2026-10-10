import AppKit
import XCTest
@testable import SwitcherCore

final class NativeServicePacketTests: XCTestCase {
    func testReadOnlyResponseHasNoFormatsRatherThanAnEmptyReplacement() throws {
        let packet = NSPasteboard.withUniqueName()
        defer { packet.releaseGlobally() }
        XCTAssertTrue(packet.setString("ghbdtn", forType: .string))
        let captured = try XCTUnwrap(packet.string(forType: .string))
        XCTAssertTrue(NativeServicePacket.discardReturnValue(packet))
        XCTAssertEqual(captured, "ghbdtn")
        XCTAssertTrue(packet.types?.isEmpty == true)
        XCTAssertNil(packet.string(forType: .string))
    }

    func testEveryStandardBoardIsExcludedAndGeneralIsNeverModified() {
        for name in [NSPasteboard.Name.general, .find, .font, .ruler, .drag] {
            XCTAssertFalse(NativeServicePacket.isDedicated(name))
        }
        let generation = NSPasteboard.general.changeCount
        XCTAssertFalse(NativeServicePacket.discardReturnValue(.general))
        XCTAssertEqual(NSPasteboard.general.changeCount, generation)
    }
}
