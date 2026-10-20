import Foundation

/// Chromium editors can report selection offsets in a different space from
/// their AXValue: empty paragraphs before the caret are counted differently,
/// so the reported range points earlier in the value. The reported range's
/// own text (selected text, or AXStringForRange before the caret, which can
/// omit paragraph breaks) is located in the value; only one exact occurrence
/// fixes the shift.
public enum ReportedRangeShift {
    /// The amount to add to reported offsets so they index `value`; nil when
    /// the offsets disagree with `value` and no single location explains them.
    /// `textBefore` is the target's own text ending at a caret, nil when the
    /// target cannot provide it (no evidence: offsets are taken as reported).
    public static func resolve(value: String, range: NSRange, selectedText: String?, textBefore: String?) -> Int? {
        let document = value as NSString
        guard range.location >= 0, range.length >= 0 else { return nil }
        if range.length > 0 {
            guard let selectedText, !selectedText.isEmpty else { return 0 }
            if NSMaxRange(range) <= document.length,
               document.substring(with: range) == selectedText { return 0 }
            return single(selectedText, in: document).map { $0 - range.location }
        }
        guard let textBefore else { return 0 }
        let before = textBefore as NSString
        if before.length == 0 { return range.location <= document.length ? 0 : nil }
        if range.location <= document.length, range.location >= before.length,
           document.substring(with: NSRange(location: range.location - before.length, length: before.length)) == textBefore { return 0 }
        // The target's range text can omit paragraph breaks, so the longest
        // suffix found in the value locates the caret. It must occur once and
        // cover the whole word that ends at the located caret.
        var length = before.length
        while length > 0 {
            let suffix = before.substring(from: before.length - length)
            if document.range(of: suffix, options: .literal).location != NSNotFound {
                guard length >= min(before.length, 8), let location = single(suffix, in: document) else { return nil }
                let caret = location + length
                if let token = TextConversion.tokenRange(in: value, caret: caret), NSMaxRange(token) == caret,
                   token.location < location { return nil }
                return caret - range.location
            }
            length -= 1
        }
        return nil
    }

    private static func single(_ text: String, in document: NSString) -> Int? {
        let first = document.range(of: text, options: .literal)
        guard first.location != NSNotFound else { return nil }
        let rest = NSRange(location: first.location + 1, length: document.length - first.location - 1)
        guard document.range(of: text, options: .literal, range: rest).location == NSNotFound else { return nil }
        return first.location
    }
}
