import Foundation

/// Approximate shadow-swing phases, in seconds since session start.
/// These are motion phases of a handheld gesture, not validated club phases.
struct SwingPhases: Codable, Equatable {
    var start: Double
    /// Top of the backswing: where rotation on the swing axis reverses into the downswing.
    var top: Double
    /// End of the fast part of the downswing.
    var downswingEnd: Double

    var backswing: Double { top - start }
    var downswing: Double { downswingEnd - top }
    var tempoRatio: Double { downswing > 0 ? backswing / downswing : 0 }
}

enum PhaseConfidence: String, Codable, Comparable {
    case none, low, medium, high

    private var rank: Int {
        switch self {
        case .none: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    static func < (a: PhaseConfidence, b: PhaseConfidence) -> Bool { a.rank < b.rank }
}

struct PhaseAnalysis: Codable, Equatable {
    var phases: SwingPhases?
    var confidence: PhaseConfidence
    /// Plain-language reasons confidence was reduced.
    var issues: [String]
    /// Swing axis (0 = x, 1 = y, 2 = z) and the sign that makes the downswing positive.
    var axis: Int
    var sign: Int
    var algorithmVersion: String

    /// The PRD rule: only show tempo when the phase boundaries are clear.
    var showsTempo: Bool { phases != nil && confidence >= .medium }
}

extension Rep {
    /// Hand-adjusted boundaries win; otherwise automatic ones, but only when confident.
    var effectivePhases: SwingPhases? {
        if let manualPhases { return manualPhases }
        guard let analysis, analysis.showsTempo else { return nil }
        return analysis.phases
    }

    var tempoRatio: Double? { effectivePhases?.tempoRatio }

    /// Counts toward session statistics.
    var isScorable: Bool { review != .rejected && effectivePhases != nil }
}

enum PhaseDetector {
    static let version = "phases-1"
    /// The downswing ends when swing-axis rotation falls below this fraction of its peak.
    static let downswingEndFraction = 0.3
    /// A backswing must reach at least this rotation rate the opposite way (rad/s).
    static let minBackswingRate = 0.5
    static let backswingRange = 0.25...3.0
    static let downswingRange = 0.08...1.5

    /// `samples` must cover the rep from its start to its end, in time order.
    static func analyze(_ samples: [Sample], rep: Rep, axis known: (axis: Int, sign: Int)?,
                        settings: DetectionSettings) -> PhaseAnalysis {
        let peakSample = samples.max { $0.speed < $1.speed }
        let dominant = known ?? peakSample.map { SwingAxis.dominant($0) } ?? (axis: 0, sign: 1)
        let axis = dominant.axis, sign = dominant.sign

        func fail(_ issue: String) -> PhaseAnalysis {
            PhaseAnalysis(phases: nil, confidence: .none, issues: [issue], axis: axis, sign: sign, algorithmVersion: version)
        }

        guard samples.count >= 5 else { return fail("Too few samples in this swing.") }
        if zip(samples.dropFirst(), samples).contains(where: { $0.t - $1.t > QualityReport.gapThreshold }) {
            return fail("Motion data had a gap during this swing.")
        }

        let t = samples.map(\.t)
        let v = samples.map { Double(sign) * $0.rotation[axis] }
        guard let p = v.indices.max(by: { v[$0] < v[$1] }), v[p] >= settings.minPeakSpeed * 0.5 else {
            return fail("No clear downswing on the swing axis.")
        }
        guard let k = (0..<p).last(where: { v[$0] <= 0 }) else {
            return fail("No backswing before the downswing.")
        }
        let top = crossing(t, v, from: k, level: 0)

        var issues: [String] = []
        var confidence = PhaseConfidence.high

        let end: Double
        if let j = ((p + 1)..<v.count).first(where: { v[$0] <= downswingEndFraction * v[p] }) {
            end = crossing(t, v, from: j - 1, level: downswingEndFraction * v[p])
        } else {
            end = t[t.count - 1]
            issues.append("The downswing didn't settle before the swing ended.")
            confidence = .low
        }

        let back = v[0...k]
        if (back.min() ?? 0) > -minBackswingRate {
            issues.append("The backswing barely registered on the swing axis.")
            confidence = .low
        }
        if back.contains(where: { $0 > minBackswingRate }) {
            issues.append("Several direction changes before the downswing.")
            confidence = .low
        }

        let phases = SwingPhases(start: rep.start, top: top, downswingEnd: end)
        if !backswingRange.contains(phases.backswing) {
            issues.append(String(format: "Unusual backswing length (%.2f s).", phases.backswing))
            confidence = .low
        }
        if !downswingRange.contains(phases.downswing) {
            issues.append(String(format: "Unusual downswing length (%.2f s).", phases.downswing))
            confidence = .low
        }
        if rep.possiblyClipped {
            issues.append("Peak rotation may have exceeded the sensor's range.")
            confidence = min(confidence, .medium)
        }

        return PhaseAnalysis(phases: phases, confidence: confidence, issues: issues,
                             axis: axis, sign: sign, algorithmVersion: version)
    }

    /// Time at which v crosses `level` between index i and i + 1, by linear interpolation.
    private static func crossing(_ t: [Double], _ v: [Double], from i: Int, level: Double) -> Double {
        guard i + 1 < v.count, v[i + 1] != v[i] else { return t[i] }
        let f = (level - v[i]) / (v[i + 1] - v[i])
        return t[i] + max(0, min(1, f)) * (t[i + 1] - t[i])
    }
}

/// Time-normalized swing curves for comparing swings with each other.
enum Signature {
    static let backswingPoints = 60
    static let downswingPoints = 40

    /// Signed swing-axis rotation, resampled so the backswing fills the first 60 points and the
    /// downswing the last 40. Aligning on the top of the swing compares shape within each phase.
    static func make(_ samples: [Sample], phases: SwingPhases, axis: Int, sign: Int) -> [Double]? {
        guard samples.count >= 5, phases.backswing > 0, phases.downswing > 0 else { return nil }
        let t = samples.map(\.t)
        let v = samples.map { Double(sign) * $0.rotation[axis] }
        let backTimes = (0..<backswingPoints).map {
            phases.start + phases.backswing * Double($0) / Double(backswingPoints)
        }
        let downTimes = (0..<downswingPoints).map {
            phases.top + phases.downswing * Double($0) / Double(downswingPoints - 1)
        }
        return (backTimes + downTimes).map { interpolate(t, v, at: $0) }
    }

    /// Pearson correlation of two curves as 0–100. Ignores overall speed; 100 means the same shape.
    static func shapeMatch(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count > 1 else { return nil }
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for (x, y) in zip(a, b) {
            sab += (x - ma) * (y - mb)
            saa += (x - ma) * (x - ma)
            sbb += (y - mb) * (y - mb)
        }
        guard saa > 0, sbb > 0 else { return nil }
        return max(0, sab / (saa * sbb).squareRoot()) * 100
    }

    private static func interpolate(_ t: [Double], _ v: [Double], at x: Double) -> Double {
        if x <= t[0] { return v[0] }
        if x >= t[t.count - 1] { return v[v.count - 1] }
        var lo = 0, hi = t.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if t[mid] <= x { lo = mid } else { hi = mid }
        }
        let f = (x - t[lo]) / (t[hi] - t[lo])
        return v[lo] + f * (v[hi] - v[lo])
    }
}
