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
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
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
            XCTAssertEqual(pasteboard.string(forType: .string), "original")
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
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testRestoredTransactionCannotWriteAfterLateCallback() throws {
        pasteboard.setString("original", forType: .string)
        let transaction = try XCTUnwrap(PasteboardTransaction(pasteboard: pasteboard))
        XCTAssertTrue(transaction.write("temporary"))
        transaction.restore()
        XCTAssertFalse(transaction.write("late callback"))
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }
}
