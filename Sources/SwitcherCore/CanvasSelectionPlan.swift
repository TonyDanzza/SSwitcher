import Foundation

/// A bulk Select All is safe only when the independently copied selection is
/// the entire coherent document. Partial or missing AX evidence never widens it.
public enum CanvasSelectionPlan: Equatable {
    case entireDocument
    case characters(Int)

    public init(copiedText: String, replacementText: String? = nil, document: String?, range: NSRange?) {
        if !copiedText.isEmpty, let document, let range,
           range.location == 0, range.length == document.utf16.count,
           copiedText == document {
            self = .entireDocument
        } else {
            self = .characters((replacementText ?? copiedText).count)
        }
    }
}

/// Only non-destructive Copy may be repeated. A suffix can be a selection whose
/// queued arrows have not all been handled; a previous Copy can arrive late.
/// Other mismatches are not evidence that this app owns the clipboard result.
public struct CanvasSelectionVerification {
    public enum Decision: Equatable { case confirmed, retry, unverified }
    public let expected: String
    public let previouslyCopied: String
    public let expiresAt: Double
    public let maximumCopies: Int
    public private(set) var copies = 0

    public init(expected: String, previouslyCopied: String, start: Double,
                timeout: Double, maximumCopies: Int = 3) {
        self.expected = expected
        self.previouslyCopied = previouslyCopied
        expiresAt = start + timeout
        self.maximumCopies = maximumCopies
    }

    public mutating func beginCopy(at time: Double) -> Bool {
        guard time < expiresAt, copies < maximumCopies else { return false }
        copies += 1
        return true
    }

    public func isTransient(_ copied: String) -> Bool {
        !copied.isEmpty && copied != expected &&
        (expected.hasSuffix(copied) || copied == previouslyCopied)
    }

    public func decision(copied: String, at time: Double) -> Decision {
        if copied == expected { return .confirmed }
        if time < expiresAt, copies < maximumCopies, isTransient(copied) { return .retry }
        return .unverified
    }
}
