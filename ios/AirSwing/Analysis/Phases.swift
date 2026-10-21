import Foundation

/// Approximate shadow-swing phases, in seconds since session start.
/// These are motion phases of a handheld gesture, not validated club phases.
struct SwingPhases: Codable, Equatable {
    var start: Double
    /// Top of the backswing: where rotation on the swing axis reverses into the downswing.
    var top: Double
    /// End of the downswing: impact in glove mode, otherwise the end of its fast part.
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
    static let gloveVersion = "phases-glove-1"
    /// Glove mode looks for impact from this long before peak rotation to this long after it (s).
    static let impactBefore = 0.10
    static let impactAfter = 0.15
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
        if let jump = settings.impactJump {
            // Real club: the downswing ends at impact. Without a clear impact (no ball, a miss),
            // peak swing-axis rotation is the closest stand-in.
            let peak = plateauCenter(v, around: p)
            if let i = impactIndex(samples, after: k, near: t[peak], jump: jump) {
                end = t[i]
            } else {
                end = t[peak]
                issues.append("No impact found, so the downswing ends at peak rotation.")
            }
        } else if let j = ((p + 1)..<v.count).first(where: { v[$0] <= downswingEndFraction * v[p] }) {
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

        return PhaseAnalysis(phases: phases, confidence: confidence, issues: issues, axis: axis, sign: sign,
                             algorithmVersion: settings.impactJump == nil ? version : gloveVersion)
    }

    /// Index of the largest sample-to-sample change in user acceleration within the impact window
    /// around `peakTime`, after the top (index `top`), if it reaches `jump` g.
    static func impactIndex(_ samples: [Sample], after top: Int, near peakTime: Double, jump: Double) -> Int? {
        var best: (i: Int, jump: Double)?
        for i in max(top + 1, 1)..<samples.count {
            let dt = samples[i].t - peakTime
            guard dt >= -impactBefore else { continue }
            guard dt <= impactAfter else { break }
            let a = samples[i], b = samples[i - 1]
            let d = ((a.ax - b.ax) * (a.ax - b.ax) + (a.ay - b.ay) * (a.ay - b.ay) + (a.az - b.az) * (a.az - b.az))
                .squareRoot()
            if d > (best?.jump ?? 0) { best = (i, d) }
        }
        guard let best, best.jump >= jump else { return nil }
        return best.i
    }

    /// Middle of the run of samples around `p` that are within 2% of its value. When the sensor
    /// clips, the peak is a flat run and its first sample would put the peak too early.
    static func plateauCenter(_ v: [Double], around p: Int) -> Int {
        let level = v[p] * 0.98
        var lo = p, hi = p
        while lo > 0, v[lo - 1] >= level { lo -= 1 }
        while hi + 1 < v.count, v[hi + 1] >= level { hi += 1 }
        return (lo + hi) / 2
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
