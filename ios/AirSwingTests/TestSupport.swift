@testable import AirSwing
import Foundation

/// Builds synthetic 50 Hz recordings from segments of constant rotation rate.
enum Synth {
    static let rate = 50.0

    struct Segment {
        var duration: Double
        var ry: Double = 0
        var q: Quat = .identity
    }

    static func samples(_ segments: [Segment]) -> [Sample] {
        var out: [Sample] = []
        var t0 = 0.0
        for seg in segments {
            let n = Int((seg.duration * rate).rounded())
            for i in 0..<n {
                out.append(Sample(t: t0 + Double(i) / rate, q: seg.q, rx: 0, ry: seg.ry, rz: 0,
                                  ax: 0, ay: 0, az: 0, sensor: "right"))
            }
            t0 += Double(n) / rate
        }
        return out
    }

    static func still(_ duration: Double, q: Quat = .identity) -> Segment {
        Segment(duration: duration, ry: 0, q: q)
    }

    static func turn(_ duration: Double, _ ry: Double) -> Segment {
        Segment(duration: duration, ry: ry)
    }

    /// Rotation of `degrees` about z.
    static func rotated(_ degrees: Double) -> Quat {
        let half = degrees * .pi / 360
        return Quat(w: cos(half), x: 0, y: 0, z: sin(half))
    }
}

extension ReadyDetector {
    func run(_ samples: [Sample]) -> [Event] {
        samples.flatMap { process($0) }
    }
}

extension Array where Element == ReadyDetector.Event {
    var reps: [Rep] {
        compactMap { if case .rep(let r) = $0 { return r } else { return nil } }
    }

    var readyCount: Int {
        filter { if case .ready = $0 { return true } else { return false } }.count
    }

    var waggleCount: Int {
        filter { if case .waggle = $0 { return true } else { return false } }.count
    }
}
