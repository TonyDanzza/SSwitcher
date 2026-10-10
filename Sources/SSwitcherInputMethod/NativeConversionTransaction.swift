import AppKit
import Carbon
import InputMethodKit
import InputMethodSupport
import SwitcherCore

typealias NativeInputClient = IMKTextInput & NSObjectProtocol

/// Main-affine, one-shot IMK replacement. Client calls can block; a deadline
/// prevents the next call/write, but cannot interrupt a call already in flight.
final class NativeConversionTransaction {
    private let input: NativeInputClient
    private let mode: InputMethodIdentity.Mode
    private let keyboardID: String
    private let foregroundBundleID: String
    private let gestureTime: Double
    private let preparationDeadline: Double
    private let authority: () -> Bool
    private let willWrite: () -> Void
    private let completion: (InputMethodIdentity.Reason, InputMethodIdentity.Mode?, String?, [String: Any]) -> Void
    private var acknowledgementDeadline: Double?
    private var written = false
    private var finished = false
    private var bundleID: String?
    private var capabilities: [String: Any] = [:]

    init(input: NativeInputClient, mode: InputMethodIdentity.Mode, keyboardID: String, foregroundBundleID: String,
         gestureTime: Double, startedAt: Double, authority: @escaping () -> Bool, willWrite: @escaping () -> Void,
         completion: @escaping (InputMethodIdentity.Reason, InputMethodIdentity.Mode?, String?, [String: Any]) -> Void) {
        self.input = input; self.mode = mode; self.keyboardID = keyboardID
        self.foregroundBundleID = foregroundBundleID; self.gestureTime = gestureTime
        self.authority = authority; self.willWrite = willWrite; self.completion = completion
        preparationDeadline = min(startedAt + InputMethodIdentity.readBudget,
                                  gestureTime + InputMethodIdentity.requestLifetime)
    }

    private func finish(_ reason: InputMethodIdentity.Reason, target: InputMethodIdentity.Mode? = nil) {
        guard !finished else { return }
        finished = true
        let result: InputMethodIdentity.Reason = written && reason != .converted ? .unverified : reason
        completion(result, result == .converted ? target : nil, bundleID, capabilities)
    }

    private func ready() -> Bool {
        guard !finished else { return false }
        guard authority() else { finish(.sessionChanged); return false }
        let deadline = written ? (acknowledgementDeadline ?? preparationDeadline) : preparationDeadline
        guard ProcessInfo.processInfo.systemUptime <= deadline else { finish(.timedOut); return false }
        return true
    }

    private func clientReady() -> Bool {
        guard ready() else { return false }
        bundleID = input.bundleIdentifier()
        guard ready() else { return false }
        guard bundleID == foregroundBundleID else { finish(.inactiveSession); return false }
        let currentOverride = TISCopyInputMethodKeyboardLayoutOverride()?.takeRetainedValue()
        guard ready() else { return false }
        guard let currentOverride, InputMethodIdentity.string(kTISPropertyInputSourceID, of: currentOverride) == keyboardID else {
            finish(.keyboardUnavailable); return false
        }
        return true
    }

    private func capabilitiesReady() -> Bool {
        guard ready() else { return false }
        let unicode = input.supportsUnicode()
        capabilities["supportsUnicode"] = unicode
        guard ready() else { return false }
        guard unicode else { finish(.unicodeUnsupported); return false }
        let access = input.supportsProperty(TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag))
        capabilities["supportsDocumentAccess"] = access
        guard ready() else { return false }
        guard access else { finish(.documentAccessUnsupported); return false }
        return true
    }

    private static func validRange(_ range: NSRange, length: Int) -> Bool {
        range.location >= 0 && range.length >= 0 && range.location <= length && range.length <= length - range.location
    }

    private func snapshot() -> NativeTextSnapshot? {
        guard ready() else { return nil }
        let length = input.length()
        guard ready() else { return nil }
        guard length >= 0, length != NSNotFound else { finish(.documentUnavailable); return nil }
        guard length <= NativeTextSnapshot.documentLimit else { finish(.documentTooLarge); return nil }
        guard ready() else { return nil }
        let selection = input.selectedRange()
        capabilities["selection"] = Self.validRange(selection, length: length) ? (selection.length == 0 ? "caret" : "selected") : "invalid"
        guard ready() else { return nil }
        guard Self.validRange(selection, length: length) else { finish(.invalidSelection); return nil }
        guard ready() else { return nil }
        let marked = input.markedRange()
        guard ready() else { return nil }
        let unmarked = marked == NSRange(location: NSNotFound, length: 0) || (marked.length == 0 && Self.validRange(marked, length: length))
        capabilities["marked"] = unmarked ? "unmarked" : "unsupported"
        guard unmarked else {
            finish(Self.validRange(marked, length: length) && marked.length > 0 ? .compositionActive : .invalidMarkedRange)
            return nil
        }
        let fullRange = NSRange(location: 0, length: length)
        var actual = NSRange(location: NSNotFound, length: NSNotFound)
        guard ready() else { return nil }
        let document = input.string(from: fullRange, actualRange: &actual)
        guard ready() else { return nil }
        guard document != nil else { finish(.documentUnavailable); return nil }
        guard actual == fullRange else { finish(.contextClipped); return nil }
        guard document?.utf16.count == length else { finish(.invalidUTF16); return nil }
        guard ready() else { return nil }
        let freshSelection = input.selectedRange()
        guard ready() else { return nil }
        let freshMarked = input.markedRange()
        guard ready() else { return nil }
        guard freshSelection == selection, freshMarked == marked else { finish(.rangeChanged); return nil }
        guard let result = NativeTextSnapshot(document: document, length: length, actualRange: actual, selection: selection, marked: marked) else {
            finish(.invalidUTF16); return nil
        }
        return result
    }

    func start() {
        guard Thread.isMainThread, clientReady(), capabilitiesReady(), let original = snapshot() else { return }
        guard let plan = NativeTextReplacementPlan(snapshot: original) else { finish(.ignored); return }
        guard ready() else { return }
        let conversion = NativeLayoutConversion.prepare(plan.scope.text, mode: mode)
        guard ready() else { return }
        guard let conversion else { finish(.mappingUnavailable); return }
        guard !AccessibilitySelectionPlan.exactlyEqual(plan.scope.text, conversion.text) else { finish(.unchangedText); return }
        guard let replacement = plan.replacing(with: conversion.text) else { finish(.invalidUTF16); return }
        guard clientReady(), capabilitiesReady(), let fresh = snapshot() else { return }
        guard plan.matches(fresh) else { finish(.documentChanged); return }
        // The immutable preparation deadline and session/input grant still
        // apply immediately before the one document-relative insert call.
        guard ready() else { return }
        written = true
        willWrite()
        input.insertText(replacement.text, replacementRange: plan.scope.range)
        acknowledgementDeadline = min(ProcessInfo.processInfo.systemUptime + InputMethodIdentity.acknowledgementBudget,
                                      gestureTime + InputMethodIdentity.requestLifetime + InputMethodIdentity.acknowledgementBudget)
        guard ready() else { return }
        // Permit the client's commit turn, then read once. No retry, rollback,
        // polling timer, caret setter or retained selection restoration.
        DispatchQueue.main.async { [self] in
            guard clientReady(), capabilitiesReady(), let actual = snapshot() else { return }
            guard plan.confirms(replacement, snapshot: actual), ready() else { finish(.unverified); return }
            finish(.converted, target: conversion.targetMode)
        }
    }
}
