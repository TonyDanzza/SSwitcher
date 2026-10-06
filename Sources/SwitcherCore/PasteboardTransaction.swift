import AppKit

/// A temporary clipboard value that never overwrites a newer user copy.
public final class PasteboardTransaction {
    private let pasteboard: NSPasteboard
    private var savedItems: [NSPasteboardItem] = []
    private let initialChangeCount: Int
    private var writtenChangeCount: Int?
    private var finished = false

    public init?(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        initialChangeCount = pasteboard.changeCount
        for item in pasteboard.pasteboardItems ?? [] {
            let saved = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                saved.setData(data, forType: type)
            }
            savedItems.append(saved)
        }
        guard pasteboard.changeCount == initialChangeCount else { return nil }
    }

    public func write(_ text: String) -> Bool {
        guard !finished, pasteboard.changeCount == (writtenChangeCount ?? initialChangeCount) else { return false }
        pasteboard.clearContents()
        writtenChangeCount = pasteboard.changeCount
        guard pasteboard.setString(text, forType: .string) else { restore(); return false }
        writtenChangeCount = pasteboard.changeCount
        return true
    }

    public var hasCopyResult: Bool {
        guard let writtenChangeCount else { return false }
        return pasteboard.changeCount != writtenChangeCount
    }

    public var retainsOwnership: Bool {
        !finished && pasteboard.changeCount == (writtenChangeCount ?? initialChangeCount)
    }

    public enum VerificationResult: Equatable {
        case waiting
        case copied(String)
        case rejected
    }

    /// A mismatching, unrelated clipboard revision is never adopted. A bounded
    /// verification retry may adopt only the expected text or a known transient
    /// result, and must check ownership again immediately before its next Copy.
    public func acceptVerificationCopy(_ verification: CanvasSelectionVerification) -> VerificationResult {
        guard !finished, hasCopyResult else { return .waiting }
        let revision = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)
        // Copy may first clear/declare its formats, then publish plain text.
        // A revision changing during the read is likewise an unfinished
        // snapshot, not a mismatching selection. Neither is owned yet.
        guard pasteboard.changeCount == revision, let text else { return .waiting }
        guard text == verification.expected || verification.isTransient(text) else { return .rejected }
        writtenChangeCount = revision
        return .copied(text)
    }

    /// Call only after our Copy command, with unchanged app focus and no user
    /// input. The copied value becomes ours to restore after conversion.
    public func acceptCopyResult(expectedSelectedText: String? = nil, requireMatch: Bool = false) -> String? {
        guard hasCopyResult else { return nil }
        let revision = pasteboard.changeCount
        let plainText = pasteboard.string(forType: .string)
        let html = pasteboard.string(forType: .html)
        guard pasteboard.changeCount == revision else { return nil }
        writtenChangeCount = revision
        if requireMatch { guard let expectedSelectedText, plainText == expectedSelectedText else { return nil } }
        // Figma includes scene metadata even when copying styled characters.
        // Accept it only when a text editor selection independently matches;
        // copying a canvas object must not be mistaken for selected characters.
        if let html,
           html.contains("<!--(figma)") || html.contains("data-buffer=") {
            guard let expectedSelectedText, !expectedSelectedText.isEmpty,
                  plainText == expectedSelectedText else { return nil }
        }
        return plainText
    }

    public func restore() {
        guard !finished else { return }
        finished = true
        guard let writtenChangeCount else { return }
        if pasteboard.changeCount == writtenChangeCount {
            pasteboard.clearContents()
            if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
        }
        self.writtenChangeCount = nil
        savedItems.removeAll()
    }

    deinit { restore() }
}
