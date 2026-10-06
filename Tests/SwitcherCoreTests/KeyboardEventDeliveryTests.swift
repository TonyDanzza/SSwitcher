import XCTest
import CoreGraphics
@testable import SwitcherCore

final class KeyboardEventDeliveryTests: XCTestCase {
    func testFinalPairSourceRetainsReceiptThroughMetadataRegeneration() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        var events: [CGEvent] = []
        for key: CGKeyCode in [123, 123] {
            for down in [true, false] {
                let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down))
                event.setIntegerValueField(.eventSourceUserData, value: KeyboardEventDelivery.sourceMarker)
                events.append(event)
            }
        }
        var delivery = KeyboardEventDelivery()
        let token = try XCTUnwrap(delivery.begin())
        XCTAssertTrue(KeyboardEventDelivery.tagFinalPair(events, marker: token))
        for event in events.prefix(2) { XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), KeyboardEventDelivery.sourceMarker) }
        for event in events.suffix(2) {
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), token)
            let receiptSource = try XCTUnwrap(CGEventSource(event: event))
            XCTAssertEqual(receiptSource.userData, token)
            let regenerated = try XCTUnwrap(CGEvent(keyboardEventSource: receiptSource, virtualKey: 123, keyDown: false))
            XCTAssertEqual(regenerated.getIntegerValueField(.eventSourceUserData), token)
        }
    }

    func testIncompletePairCannotAcquireReceiptTag() throws {
        XCTAssertFalse(KeyboardEventDelivery.tagFinalPair([], marker: 1))
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true))
        XCTAssertFalse(KeyboardEventDelivery.tagFinalPair([event], marker: 1))
        XCTAssertFalse(KeyboardEventDelivery.tagFinalPair([event, event], marker: 1))
    }

    func testOnlyFinalMarkedReceiptCompletesAndOnlyOnce() throws {
        var delivery = KeyboardEventDelivery()
        let token = try XCTUnwrap(delivery.begin())
        XCTAssertTrue(KeyboardEventDelivery.isSynthetic(marker: token))
        XCTAssertTrue(KeyboardEventDelivery.isSynthetic(marker: KeyboardEventDelivery.sourceMarker))
        XCTAssertFalse(KeyboardEventDelivery.isSynthetic(marker: 0))
        XCTAssertNil(delivery.begin())
        XCTAssertFalse(delivery.acknowledge(marker: KeyboardEventDelivery.sourceMarker))
        XCTAssertEqual(delivery.activeMarker, token)
        XCTAssertTrue(delivery.acknowledge(marker: token))
        XCTAssertFalse(delivery.acknowledge(marker: token))
    }

    func testLateReceiptFromCancelledBatchCannotReleaseNewBatch() throws {
        var delivery = KeyboardEventDelivery()
        let old = try XCTUnwrap(delivery.begin())
        XCTAssertTrue(delivery.cancel())
        XCTAssertFalse(delivery.cancel())
        let next = try XCTUnwrap(delivery.begin())
        XCTAssertNotEqual(old, next)
        XCTAssertFalse(delivery.acknowledge(marker: old))
        XCTAssertEqual(delivery.activeMarker, next)
        XCTAssertTrue(delivery.acknowledge(marker: next))
    }
}
