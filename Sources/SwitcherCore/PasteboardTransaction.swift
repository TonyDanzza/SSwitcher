import AppKit

/// A temporary clipboard value that never overwrites a newer user copy.
public final class PasteboardTransaction {
    private let pasteboard: NSPasteboard
    private var savedItems: [NSPasteboardItem] = []
    private let initialChangeCount: Int
    private var writtenChangeCount: Int?

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
        guard pasteboard.changeCount == (writtenChangeCount ?? initialChangeCount) else { return false }
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

    /// Call only after our Copy command, with unchanged app focus and no user
    /// input. The copied value becomes ours to restore after conversion.
    public func acceptCopyResult() -> String? {
        guard hasCopyResult else { return nil }
        writtenChangeCount = pasteboard.changeCount
        // Figma object copies contain serialized scene data, not selected text.
        if let html = pasteboard.string(forType: .html),
           html.contains("<!--(figma)") || html.contains("data-buffer=") { return nil }
        return pasteboard.string(forType: .string)
    }

    public func restore() {
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
