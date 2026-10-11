/// Readiness deadlines bound waits; only quiet/text-pacing/reveal intervals impose
/// a delay. None of these timers run while the app is idle.
enum ConversionTiming {
    // Services callbacks arrive before the requesting editor resumes its
    // responder loop. These finite waits apply only to MAX native requests.
    static let nativeServiceReturnSettle = 0.25
    static let nativeNavigationSettle = 0.05
    static let nativeServiceReplyDeadline = 0.6
    static let nativeWordDeadline = 4.0
    static let shiftQuiet = 0.09
    static let axMessageTimeout: Float = 0.12
    static let electronPreparationBudget = 0.36
    static let canonicalDocumentBudget = 0.12
    static let attachmentScopeBudget = 0.12
    static let overlayFocusBudget = 0.12
    static let qtFocusPreparationBudget = 0.6
    static let qtFocusProofBudget = 0.36
    static let replacementDeadline = 0.5
    static let pollInterval = 0.02
    static let textPairInterval = 0.008
    static let eventDeliveryDeadline = 0.5
    static let modifierReleaseDeadline = 1.0
    static let captureBudget = 0.055
    static let revealDuration = 0.09
    static let overlayWatchdog = 0.65
    static let nativeVisualPresentationSettle = 0.034
    static let nativeVisualCommitSettle = 0.1
    static let nativeVisualWatchdog = 1.0
    static let nativeVisualEarlyClaim = 0.4
}
