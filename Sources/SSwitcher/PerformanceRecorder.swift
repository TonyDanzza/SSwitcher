import Foundation
import os
import SwitcherCore

enum ConversionMetric: String, CaseIterable {
    case total, gate, ax, mutation, confirmation
    var title: String {
        switch self {
        case .total: return "До результата"
        case .gate: return "Пауза Shift"
        case .ax: return "AX"
        case .mutation: return "Отправка"
        case .confirmation: return "Подтверждение"
        }
    }
    var signpost: StaticString {
        switch self {
        case .total: return "GestureToResult"
        case .gate: return "GestureGate"
        case .ax: return "AXRead"
        case .mutation: return "Mutation"
        case .confirmation: return "ConfirmationWait"
        }
    }
}

/// No text, clipboard contents or pixels enter these records. All mutable
/// summaries/trace phases are main confined; AX has separate worker signposts.
final class PerformanceRecorder {
    private let signposter = OSSignposter(subsystem: "com.tonydanzza.SSwitcher", category: "Conversion")
    private var pending: ConversionTrace?
    private var samples: [String: [ConversionMetric: TimingSummary]] = [:]
    private var bucketOrder: [String] = []
    private var latest: ConversionTrace?

    func gestureReleased(at time: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        pending?.finish(confirmed: false)
        pending = ConversionTrace(recorder: self, signposter: signposter, release: time)
    }
    func cancelGesture() { pending?.finish(confirmed: false); pending = nil }
    func startAttempt(release: Double) -> ConversionTrace {
        let trace = pending ?? ConversionTrace(recorder: self, signposter: signposter, release: release)
        pending = nil
        trace.end(.gate)
        latest = trace
        return trace
    }
    fileprivate func record(_ trace: ConversionTrace, metric: ConversionMetric, duration: Double) {
        guard let bucket = trace.bucket else { return }
        if samples[bucket] == nil {
            if bucketOrder.count == 8 { samples.removeValue(forKey: bucketOrder.removeFirst()) }
            bucketOrder.append(bucket)
            samples[bucket] = [:]
        }
        var summary = samples[bucket]?[metric] ?? TimingSummary()
        summary.record(duration)
        samples[bucket]?[metric] = summary
    }
    var diagnosticStatus: String {
        guard let latest else { return "Измерения: ожидание жеста" }
        let values = ConversionMetric.allCases.compactMap { metric -> String? in
            guard let value = latest.durations[metric] else { return nil }
            return "\(metric.title): \(Int((value * 1000).rounded())) мс"
        }.joined(separator: "; ")
        let summary = latest.bucket.flatMap { samples[$0]?[.total] }
        let distribution: String
        if let summary, let percentiles = summary.percentiles {
            distribution = "\(latest.modeLabel), n=\(summary.count): медиана \(Int(percentiles.median * 1000)) мс, p95 \(Int(percentiles.p95 * 1000)) мс"
        } else {
            distribution = "\(latest.modeLabel): подтверждённых попыток \(summary?.count ?? 0)/20 для медианы и p95"
        }
        return values + "\n" + distribution + "\nПодтверждение редактора; момент отрисовки не измеряется"
    }
}

final class ConversionTrace {
    private weak var recorder: PerformanceRecorder?
    private let signposter: OSSignposter
    private let id: OSSignpostID
    private let release: Double
    private var intervals: [ConversionMetric: (Double, OSSignpostIntervalState)] = [:]
    private var finished = false
    private(set) var durations: [ConversionMetric: Double] = [:]
    private(set) var bucket: String?
    private(set) var modeLabel = "Редактор"

    init(recorder: PerformanceRecorder, signposter: OSSignposter, release: Double) {
        self.recorder = recorder; self.signposter = signposter; self.release = release
        id = signposter.makeSignpostID()
        begin(.total); begin(.gate)
    }
    func setMode(application: EditorApplication, selected: Bool) {
        bucket = application.session + (selected ? ":selection" : ":word")
        modeLabel = application.name + (selected ? ", выделение" : ", слово")
    }
    func begin(_ metric: ConversionMetric) {
        guard intervals[metric] == nil else { return }
        intervals[metric] = (ProcessInfo.processInfo.systemUptime, signposter.beginInterval(metric.signpost, id: id))
    }
    func end(_ metric: ConversionMetric) {
        guard let (start, state) = intervals.removeValue(forKey: metric) else { return }
        signposter.endInterval(metric.signpost, state)
        let now = ProcessInfo.processInfo.systemUptime
        let duration = metric == .total || metric == .gate ? max(0, now - release) : now - start
        durations[metric] = duration
    }
    func addAX(_ duration: Double) { durations[.ax, default: 0] += duration }
    func finish(confirmed: Bool) {
        guard !finished else { return }
        finished = true
        if confirmed { signposter.emitEvent("EditorAcknowledged", id: id) }
        for metric in Array(intervals.keys) { end(metric) }
        if confirmed { for (metric, value) in durations { recorder?.record(self, metric: metric, duration: value) } }
    }
}
