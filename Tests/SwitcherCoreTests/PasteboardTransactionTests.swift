import AppKit
import XCTest
@testable import SwitcherCore

final class PasteboardTransactionTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() { pasteboard = .withUniqueName() }
    override func tearDown() { pasteboard.releaseGlobally() }

    func testRestoresAllOriginalFormats() throws {
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("test.custom"))
        pasteboard.writeObjects([item])
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        XCTAssertTrue(transaction.write("replacement"))
        XCTAssertEqual(pasteboard.string(forType: .string), "replacement")
        transaction.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(pasteboard.data(forType: NSPasteboard.PasteboardType("test.custom")), Data([1, 2, 3]))
    }

    func testDoesNotOverwriteNewUserCopy() throws {
        pasteboard.setString("original", forType: .string)
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        XCTAssertTrue(transaction.write("replacement"))
        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)
        transaction.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testDoesNotReplaceClipboardChangedBeforePaste() throws {
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)
        XCTAssertFalse(transaction.write("replacement"))
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testRestoresEmptyClipboardAndCanRestoreTwice() throws {
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        XCTAssertTrue(transaction.write("replacement"))
        transaction.restore()
        transaction.restore()
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testCopyFallbackThenPasteRestoresOriginalClipboard() throws {
        pasteboard.setString("original", forType: .string)
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        XCTAssertTrue(transaction.write("copy probe"))
        pasteboard.clearContents()
        pasteboard.setString("ghbdtn", forType: .string)
        XCTAssertTrue(transaction.hasCopyResult)
        XCTAssertEqual(transaction.acceptCopyResult(), "ghbdtn")
        XCTAssertTrue(transaction.write("привет"))
        transaction.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testFigmaObjectPayloadIsNotConvertedAsText() throws {
        pasteboard.setString("original", forType: .string)
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        XCTAssertTrue(transaction.write("copy probe"))
        pasteboard.clearContents()
        pasteboard.setString("not plain selected text", forType: .string)
        pasteboard.setString("<span data-buffer=\"scene\"></span>", forType: .html)
        XCTAssertNil(transaction.acceptCopyResult())
        transaction.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "not plain selected text")
    }

    func testVerificationCopyPreservesOriginalClipboard() throws {
        pasteboard.setString("original", forType: .string)
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        XCTAssertTrue(transaction.write("copy probe"))
        pasteboard.clearContents()
        pasteboard.setString("ghbdtn", forType: .string)
        XCTAssertEqual(transaction.acceptCopyResult(), "ghbdtn")
        XCTAssertTrue(transaction.write("привет"))
        XCTAssertTrue(transaction.write("verification probe"))
        XCTAssertFalse(transaction.hasCopyResult)
        XCTAssertNil(transaction.acceptCopyResult())
        pasteboard.clearContents()
        pasteboard.setString("привет", forType: .string)
        XCTAssertEqual(transaction.acceptCopyResult(), "привет")
        transaction.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testFigmaStyledTextRequiresMatchingEditorSelection() throws {
        for expected in [nil, "other text", "каждого"] as [String?] {
            pasteboard.clearContents()
            pasteboard.setString("original", forType: .string)
            let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
            XCTAssertTrue(transaction.write("copy probe"))
            pasteboard.clearContents()
            pasteboard.setString("каждого", forType: .string)
            pasteboard.setString("<span data-buffer=\"styled text\"></span>", forType: .html)
            XCTAssertEqual(transaction.acceptCopyResult(expectedSelectedText: expected), expected == "каждого" ? "каждого" : nil)
            transaction.restore()
            XCTAssertEqual(pasteboard.string(forType: .string), expected == "каждого" ? "original" : "каждого")
        }
    }

    func testLateInitialCopyCannotBeAcceptedAsVerificationPlainText() throws {
        pasteboard.setString("original", forType: .string)
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        XCTAssertTrue(transaction.write("first Copy probe"))
        pasteboard.clearContents(); pasteboard.setString("ghbdtn", forType: .string)
        XCTAssertEqual(transaction.acceptCopyResult(), "ghbdtn")
        XCTAssertTrue(transaction.write("привет"))
        XCTAssertTrue(transaction.write("verification Copy probe"))
        // A late response from the first Copy has no Figma HTML to identify it.
        pasteboard.clearContents(); pasteboard.setString("ghbdtn", forType: .string)
        XCTAssertNil(transaction.acceptCopyResult(expectedSelectedText: "привет", requireMatch: true))
        transaction.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "ghbdtn")
    }

    func testRequiredInitialCopyDoesNotAdoptUnrelatedClipboardWriter() throws {
        pasteboard.setString("original", forType: .string)
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        XCTAssertTrue(transaction.write("initial Copy probe"))
        pasteboard.clearContents()
        pasteboard.setString("OLD unrelated clipboard", forType: .string)
        XCTAssertNil(transaction.acceptCopyResult(expectedSelectedText: "ghbdtn", requireMatch: true))
        XCTAssertFalse(transaction.retainsOwnership)
        XCTAssertFalse(transaction.write("replacement"))
        transaction.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "OLD unrelated clipboard")
    }

    func testRestoredTransactionCannotWriteAfterLateCallback() throws {
        pasteboard.setString("original", forType: .string)
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        XCTAssertTrue(transaction.write("temporary"))
        transaction.restore()
        XCTAssertFalse(transaction.write("late callback"))
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCanvasTransientCopyCanBeVerifiedAgainAndOriginalClipboardRestored() throws {
        pasteboard.setString("original", forType: .string)
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        let verification = CanvasSelectionVerification(expected: "привет мир", previouslyCopied: "ghbdtn vbh", start: 0, timeout: 0.5)
        XCTAssertTrue(transaction.write("Copy probe"))
        pasteboard.clearContents(); pasteboard.setString("мир", forType: .string)
        XCTAssertEqual(transaction.acceptVerificationCopy(verification), .copied("мир"))
        XCTAssertTrue(transaction.retainsOwnership)
        XCTAssertTrue(transaction.write("second Copy probe"))
        pasteboard.clearContents(); pasteboard.setString("привет мир", forType: .string)
        XCTAssertEqual(transaction.acceptVerificationCopy(verification), .copied("привет мир"))
        transaction.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCanvasUnrelatedCopyIsNotAdoptedOrOverwritten() throws {
        pasteboard.setString("original", forType: .string)
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        let verification = CanvasSelectionVerification(expected: "привет", previouslyCopied: "ghbdtn", start: 0, timeout: 0.5)
        XCTAssertTrue(transaction.write("Copy probe"))
        pasteboard.clearContents(); pasteboard.setString("new user copy", forType: .string)
        XCTAssertEqual(transaction.acceptVerificationCopy(verification), .rejected)
        XCTAssertFalse(transaction.retainsOwnership)
        XCTAssertFalse(transaction.write("retry probe"))
        transaction.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testNewCopyBetweenTransientResponseAndRetryIsPreserved() throws {
        pasteboard.setString("original", forType: .string)
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        let verification = CanvasSelectionVerification(expected: "привет", previouslyCopied: "ghbdtn", start: 0, timeout: 0.5)
        XCTAssertTrue(transaction.write("Copy probe"))
        pasteboard.clearContents(); pasteboard.setString("вет", forType: .string)
        XCTAssertEqual(transaction.acceptVerificationCopy(verification), .copied("вет"))
        pasteboard.clearContents(); pasteboard.setString("new user copy", forType: .string)
        XCTAssertFalse(transaction.retainsOwnership)
        XCTAssertFalse(transaction.write("retry probe"))
        transaction.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testVerificationWaitsForPlainTextPublishedAfterClipboardClear() throws {
        pasteboard.setString("original", forType: .string)
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        let verification = CanvasSelectionVerification(expected: "привет", previouslyCopied: "ghbdtn", start: 0, timeout: 0.5)
        XCTAssertTrue(transaction.write("Copy probe"))
        pasteboard.clearContents()
        let pendingRevision = pasteboard.changeCount
        for _ in 0..<5 {
            XCTAssertEqual(transaction.acceptVerificationCopy(verification), .waiting)
            XCTAssertFalse(transaction.retainsOwnership)
            XCTAssertEqual(pasteboard.changeCount, pendingRevision)
        }
        XCTAssertFalse(transaction.write("premature retry probe"))
        pasteboard.setString("привет", forType: .string)
        XCTAssertEqual(transaction.acceptVerificationCopy(verification), .copied("привет"))
        XCTAssertTrue(transaction.retainsOwnership)
        transaction.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testUnrelatedTextPublishedAfterClearIsStillPreserved() throws {
        pasteboard.setString("original", forType: .string)
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        let verification = CanvasSelectionVerification(expected: "привет", previouslyCopied: "ghbdtn", start: 0, timeout: 0.5)
        XCTAssertTrue(transaction.write("Copy probe"))
        pasteboard.clearContents()
        XCTAssertEqual(transaction.acceptVerificationCopy(verification), .waiting)
        pasteboard.setString("new user copy", forType: .string)
        XCTAssertEqual(transaction.acceptVerificationCopy(verification), .rejected)
        XCTAssertFalse(transaction.retainsOwnership)
        transaction.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }
}
