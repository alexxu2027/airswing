import Foundation

enum SwingAnalyzer {
    /// Samples with t in [from, to], found by binary search on the time-ordered session samples.
    static func window(_ samples: [Sample], from: Double, to: Double) -> [Sample] {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].t < from { lo = mid + 1 } else { hi = mid }
        }
        var end = lo
        while end < samples.count, samples[end].t <= to { end += 1 }
        return Array(samples[lo..<end])
    }

    static func knownAxis(_ calibration: Calibration?) -> (axis: Int, sign: Int)? {
        guard let axis = calibration?.downswingAxis, let sign = calibration?.downswingSign else { return nil }
        return (axis, sign)
    }

    /// Runs phase detection on a rep and refreshes its signature from the boundaries in use.
    static func analyzed(_ rep: Rep, samples: [Sample], calibration: Calibration?, settings: DetectionSettings) -> Rep {
        var r = rep
        let analysis = PhaseDetector.analyze(window(samples, from: rep.start, to: rep.end), rep: rep,
                                             axis: knownAxis(calibration), settings: settings)
        r.analysis = analysis
        r.signature = signature(for: r, samples: samples)
        return r
    }

    static func signature(for rep: Rep, samples: [Sample]) -> [Double]? {
        guard let phases = rep.effectivePhases, let analysis = rep.analysis else { return nil }
        let w = window(samples, from: min(rep.start, phases.start), to: max(rep.end, phases.downswingEnd))
        return Signature.make(w, phases: phases, axis: analysis.axis, sign: analysis.sign)
    }
}

/// A swing the user chose as their personal reference.
struct Baseline: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var signature: [Double]
    var tempoRatio: Double
    var backswing: Double
    var downswing: Double
    var peakSpeed: Double
    var sessionID: UUID
    var repID: UUID
    var algorithmVersion = PhaseDetector.version
}

struct Comparison: Equatable {
    /// 0–100: how closely the swing's shape matches the baseline, ignoring overall speed.
    var shapeMatch: Double
    /// Swing peak speed as a fraction of the baseline's.
    var speedRatio: Double
    /// Swing tempo minus baseline tempo.
    var tempoDifference: Double

    static func make(_ rep: Rep, to baseline: Baseline) -> Comparison? {
        guard baseline.algorithmVersion == PhaseDetector.version,
              let signature = rep.signature, let tempo = rep.tempoRatio,
              let match = Signature.shapeMatch(signature, baseline.signature),
              baseline.peakSpeed > 0 else { return nil }
        return Comparison(shapeMatch: match, speedRatio: rep.peakSpeed / baseline.peakSpeed,
                          tempoDifference: tempo - baseline.tempoRatio)
    }
}

struct SessionStats: Equatable {
    var swingCount = 0
    var rejectedCount = 0
    var unclearCount = 0
    var scoredCount = 0
    var medianTempo: Double?
    var tempoIQR: Double?
    var medianBackswing: Double?
    var medianDownswing: Double?
    /// Coefficient of variation (standard deviation / mean) of each phase's duration.
    var backswingVariation: Double?
    var downswingVariation: Double?
    var medianShapeMatch: Double?
    /// 1-based number of the scored swing least like the baseline.
    var leastSimilarSwing: Int?
    var onTargetCount: Int?

    /// Within this fraction of a tempo target counts as on target.
    static let targetTolerance = 0.1

    static func compute(_ reps: [Rep], baseline: Baseline?, target: Double?) -> SessionStats {
        var s = SessionStats()
        s.swingCount = reps.count
        s.rejectedCount = reps.filter { $0.review == .rejected }.count
        s.unclearCount = reps.filter { $0.review != .rejected && $0.effectivePhases == nil }.count

        let scored = reps.enumerated().filter { $0.element.isScorable }
        s.scoredCount = scored.count
        let phases = scored.compactMap { $0.element.effectivePhases }
        let tempos = phases.map(\.tempoRatio)
        guard !tempos.isEmpty else { return s }

        s.medianTempo = quantile(tempos, 0.5)
        if tempos.count >= 3, let q1 = quantile(tempos, 0.25), let q3 = quantile(tempos, 0.75) {
            s.tempoIQR = q3 - q1
        }
        s.medianBackswing = quantile(phases.map(\.backswing), 0.5)
        s.medianDownswing = quantile(phases.map(\.downswing), 0.5)
        if phases.count >= 3 {
            s.backswingVariation = variation(phases.map(\.backswing))
            s.downswingVariation = variation(phases.map(\.downswing))
        }
        if let target {
            s.onTargetCount = tempos.filter { abs($0 - target) <= target * targetTolerance }.count
        }
        if let baseline {
            let matches = scored.compactMap { item in
                Comparison.make(item.element, to: baseline).map { (number: item.offset + 1, match: $0.shapeMatch) }
            }
            s.medianShapeMatch = quantile(matches.map(\.match), 0.5)
            if matches.count >= 2 { s.leastSimilarSwing = matches.min { $0.match < $1.match }?.number }
        }
        return s
    }

    /// Rule-based feedback tied to measured evidence (PRD 7.5). No swing-fault diagnosis.
    func feedback(target: Double?) -> [String] {
        var lines: [String] = []
        if let medianTempo {
            lines.append(String(format: "Your median tempo was %.1f:1 across %d scored ", medianTempo, scoredCount)
                         + (scoredCount == 1 ? "swing." : "swings."))
        }
        if scoredCount < 3 {
            lines.append("Record at least 3 clear swings for consistency statistics.")
        }
        if let back = backswingVariation, let down = downswingVariation {
            if down > back * 1.25 {
                lines.append("Downswing timing varied more than backswing timing in this session.")
            } else if back > down * 1.25 {
                lines.append("Backswing timing varied more than downswing timing in this session.")
            } else {
                lines.append("Backswing and downswing timing varied by similar amounts.")
            }
        }
        if let target, let onTargetCount {
            lines.append(String(format: "%d of %d scored swings were within 10%% of your %.1f:1 target.",
                                onTargetCount, scoredCount, target))
        }
        if let medianShapeMatch {
            lines.append(String(format: "Median shape match to your baseline was %.0f%%.", medianShapeMatch))
        }
        if let leastSimilarSwing {
            lines.append("Swing \(leastSimilarSwing) was the least similar to your baseline.")
        }
        if unclearCount > 0 {
            lines.append("\(unclearCount) swing\(unclearCount == 1 ? " had" : "s had") unclear phases and weren't scored.")
        }
        if rejectedCount > 0 {
            lines.append("\(rejectedCount) swing\(rejectedCount == 1 ? " was" : "s were") excluded by you.")
        }
        return lines
    }

    /// Linear-interpolated quantile.
    static func quantile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let pos = q * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return sorted[lo] + (pos - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    static func variation(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return nil }
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1)
        return variance.squareRoot() / mean
    }
}
