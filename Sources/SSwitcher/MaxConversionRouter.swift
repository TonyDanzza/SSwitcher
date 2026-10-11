import AppKit
import Carbon
import SwitcherCore

/// Converts a double Shift in MAX along the route `MaxConversionRoute` picks:
/// retyping a freshly typed word, one direct Services request, or the full
/// Services transaction. Main thread only.
final class MaxConversionRouter {
    private let monitor: KeyboardMonitor
    private let services: NativeServiceProvider
    /// Reports the user-facing result line.
    var onResult: ((String) -> Void)?
    /// Option-Shift-Left is also Qt's word-selection command. Exclusive Carbon
    /// registrations consume it even when their callback declines the move, so
    /// they are released for a Services transaction and restored afterwards.
    var suspendWindowShortcuts: (() -> Void)?
    var restoreWindowShortcuts: (() -> Void)?
    private(set) var isRetyping = false
    var isConverting: Bool { isRetyping || services.isConverting }

    init(monitor: KeyboardMonitor, services: NativeServiceProvider) {
        self.monitor = monitor
        self.services = services
    }

    static func isMax(_ application: NSRunningApplication?) -> Bool {
        application?.bundleIdentifier == MaxConversionRoute.bundleID
    }

    /// Converts in the frontmost MAX after the gesture was admitted.
    func convert(in max: NSRunningApplication, generation: UInt64) {
        let candidate = monitor.typedWordCandidate
        recordTypedWordState(candidate)
        var route = MaxConversionRoute.decide(candidate: candidate, selectionKnownEmpty: monitor.selectionKnownEmpty)
        if case .retype(let word, let boundedStart) = route {
            if retype(word, boundedStart: boundedStart, pid: max.processIdentifier, generation: generation) { return }
            route = .service(selectionKnownEmpty: monitor.selectionKnownEmpty)
        }
        convertWithServices(direct: route == .directService, generation: generation)
    }

    /// A direct word request will need a snapshot; start it during the Shift
    /// quiet interval instead of after it.
    func prepareEarlyShield() {
        guard monitor.tracksTypedWord, !isConverting, Self.isMax(NSWorkspace.shared.frontmostApplication),
              MaxConversionRoute.decide(candidate: monitor.typedWordCandidate,
                                        selectionKnownEmpty: monitor.selectionKnownEmpty).startsEarlyShield else { return }
        let generation = monitor.inputGeneration
        services.prepareEarlyShield(valid: { [weak self] in self?.monitor.inputGeneration == generation })
    }

    private func recordTypedWordState(_ candidate: TypedWordTracker.Candidate) {
        let kind: String
        switch candidate { case .unknown: kind = "unknown"; case .afterSpace: kind = "afterSpace"; case .word: kind = "word" }
        DiagnosticReports.shared.record("TypedWordStateReport", ["candidate": kind, "tracking": monitor.tracksTypedWord,
            "lastReset": monitor.typedWordReset, "keysSinceReset": monitor.typedKeysSinceReset,
            "translatedKeys": monitor.translatedKeysSinceReset, "timestamp": Date().timeIntervalSince1970])
    }

    /// Path for a word the user has just typed, as layout switchers do:
    /// delete exactly its characters and type the converted text. No
    /// selection, Services call, Accessibility read or clipboard. Returns false
    /// before any key is sent when the native Services route must decide.
    private func retype(_ word: String, boundedStart: Bool, pid: pid_t, generation: UInt64) -> Bool {
        guard let count = TypedWordTracker.backspaceCount(for: word), let conversion = InputSources.prepare(word),
              !IsSecureEventInputEnabled(), CGPreflightPostEventAccess() else { return false }
        guard conversion.text != word else {
            monitor.conversionFinished(unverified: false)
            onResult?("Слово не требует замены")
            return true
        }
        let asOneWord = TypedWordTracker.deletesAsOneWord(word, boundedStart: boundedStart)
        guard let input = UnicodeTextInput(text: conversion.text),
              let batches = input.makeEventBatches(deletingCharacters: count, asOneWord: asOneWord) else { return false }
        isRetyping = true
        let release = monitor.lastGestureRelease
        KeyboardEvents.postTextReplacement(batches, targetPID: pid, interval: 0, valid: { [weak self] in
            guard let self else { return false }
            return self.monitor.inputGeneration == generation && !IsSecureEventInputEnabled() &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }, modifiersClear: { [weak self] in self?.monitor.observedModifiersClear == true }) { [weak self] delivered in
            guard let self else { return }
            self.isRetyping = false
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - release) * 1000)
            let result: String
            if delivered {
                self.monitor.replaceTypedWord(word, with: conversion.text)
                self.monitor.assumeSelectionEmpty()
                InputSources.selectAfterConversion(conversion.target)
                result = "Слово MAX перепечатано без выделения (\(elapsed) мс)"
            } else {
                self.monitor.forgetTypedWord("interrupted")
                result = "Замена в MAX прервана вводом; проверьте текст"
            }
            DiagnosticReports.shared.record("TypedWordReplacementReport", ["delivered": delivered, "oneWordDeletion": asOneWord,
                "characters": count, "elapsedMS": elapsed])
            self.monitor.conversionFinished(unverified: !delivered)
            self.onResult?(result)
        }
        return true
    }

    private func convertWithServices(direct: Bool, generation: UInt64) {
        suspendWindowShortcuts?()
        let started = ProcessInfo.processInfo.systemUptime
        services.convertAtCursor(valid: { [weak self] in
            self?.monitor.inputGeneration == generation
        }, knownNoSelection: direct) { [weak self] outcome, target in
            guard let self else { return }
            self.restoreWindowShortcuts?()
            self.monitor.conversionFinished(unverified: outcome == .unverified)
            DiagnosticReports.shared.record("MaxServiceRouteReport", ["direct": direct, "outcome": String(describing: outcome),
                "elapsedMS": Int((ProcessInfo.processInfo.systemUptime - started) * 1000)])
            let result: String
            switch outcome {
            case .submitted:
                if let target { InputSources.selectAfterConversion(target) }
                if let text = self.services.lastDirectConversion { self.monitor.assumeTypedWord(text) }
                result = "Текст передан нативному редактору MAX"
            case .unavailable: result = self.services.conversionStatus
            case .cancelled: result = "Замена отменена: ввод или активное окно изменились"
            case .unverified: result = "Результат замены MAX не подтверждён; проверьте текст"
            }
            self.onResult?(result)
        }
    }
}
