/// In-memory numeric samples only. A few observations are not a benchmark.
public struct TimingSummary {
    public struct Percentiles: Equatable { public let median: Double; public let p95: Double }
    private var samples: [Double] = []
    public let capacity: Int
    public let minimumCount: Int
    public init(capacity: Int = 64, minimumCount: Int = 20) {
        self.capacity = max(1, capacity)
        self.minimumCount = max(2, minimumCount)
    }
    public var count: Int { samples.count }
    public mutating func record(_ duration: Double) {
        guard duration.isFinite, duration >= 0 else { return }
        if samples.count == capacity { samples.removeFirst() }
        samples.append(duration)
    }
    public var percentiles: Percentiles? {
        guard samples.count >= minimumCount else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        let p95Index = Int((Double(sorted.count) * 0.95).rounded(.up)) - 1
        return Percentiles(median: median, p95: sorted[max(0, p95Index)])
    }
}
