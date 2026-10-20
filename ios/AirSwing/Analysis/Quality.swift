import Foundation

/// Sampling quality for a run of timestamps. Same method as the viewer and the M0 report.
struct QualityReport: Codable, Equatable {
    var sampleCount: Int
    var duration: Double
    var effectiveHz: Double
    var medianInterval: Double
    var maxInterval: Double
    var gapCount: Int
    /// Fraction of samples estimated missing, from intervals that span several median intervals.
    var estimatedDropout: Double

    static let gapThreshold = 0.1
    static let minRateHz = 20.0
    static let maxDropout = 0.05

    var meetsTargets: Bool { effectiveHz >= Self.minRateHz && estimatedDropout < Self.maxDropout }

    static func measure(_ timestamps: [Double]) -> QualityReport {
        let n = timestamps.count
        let intervals = zip(timestamps.dropFirst(), timestamps).map { $0 - $1 }
        let sorted = intervals.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let duration = n > 1 ? timestamps[n - 1] - timestamps[0] : 0

        var missing = 0
        if median > 0 {
            for d in intervals { missing += max(0, Int((d / median).rounded()) - 1) }
        }

        return QualityReport(
            sampleCount: n,
            duration: duration,
            effectiveHz: duration > 0 ? Double(n - 1) / duration : 0,
            medianInterval: median,
            maxInterval: sorted.last ?? 0,
            gapCount: intervals.filter { $0 > gapThreshold }.count,
            estimatedDropout: n + missing > 0 ? Double(missing) / Double(n + missing) : 0
        )
    }
}

/// Moving average of rotation speed over a short time window, to keep single noisy samples
/// from flipping still/moving decisions.
struct SpeedSmoother {
    let window: Double
    private var buffer: [(t: Double, v: Double)] = []
    private var sum = 0.0

    init(window: Double = 0.1) {
        self.window = window
    }

    mutating func add(t: Double, speed: Double) -> Double {
        buffer.append((t, speed))
        sum += speed
        while let first = buffer.first, t - first.t > window + 1e-9 {
            sum -= first.v
            buffer.removeFirst()
        }
        return sum / Double(buffer.count)
    }
}
