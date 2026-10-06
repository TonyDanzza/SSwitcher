/// Readiness deadlines bound waits; only quiet/text-pacing/reveal intervals impose
/// a delay. None of these timers run while the app is idle.
enum ConversionTiming {
    static let shiftQuiet = 0.09
    static let axMessageTimeout: Float = 0.12
    static let canonicalDocumentBudget = 0.12
    static let overlayFocusBudget = 0.12
    static let replacementDeadline = 0.5
    static let pollInterval = 0.02
    static let textPairInterval = 0.008
    static let eventDeliveryDeadline = 0.5
    static let modifierReleaseDeadline = 1.0
    static let captureBudget = 0.055
    static let revealDuration = 0.09
    static let overlayWatchdog = 0.65
}
