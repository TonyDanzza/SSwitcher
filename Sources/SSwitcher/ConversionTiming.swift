/// Readiness deadlines bound waits; only quiet/fallback/reveal intervals impose
/// a delay. None of these timers run while the app is idle.
enum ConversionTiming {
    static let shiftQuiet = 0.09
    static let axMessageTimeout: Float = 0.12
    static let copyDeadline = 0.5
    static let pasteDeadline = 0.5
    static let pollInterval = 0.02
    static let canvasPasteFallback = 0.32
    static let canvasSelectionFallback = 0.035
    static let captureBudget = 0.055
    static let revealDuration = 0.09
    static let overlayWatchdog = 0.65
}
