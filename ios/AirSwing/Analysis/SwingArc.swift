import Foundation
import simd

/// Where the club points through a swing, seen face-on, worked out from the hand's rotation alone.
/// With the earbud in the lead-hand glove the hand turns with the club, so this shows the shape and
/// length of the swing. It is not a measured club path: one earbud can't tell where the hands move.
struct SwingArc: Equatable {
    struct Point: Equatable {
        var t: Double
        /// How far the club has turned in the swing plane since address (radians); the backswing is positive.
        var angle: Double
        /// How far the club points out of the swing plane (radians).
        var offPlane: Double
    }

    var points: [Point]
    var phases: SwingPhases

    func index(at t: Double) -> Int {
        points.indices.min { abs(points[$0].t - t) < abs(points[$1].t - t) } ?? 0
    }

    /// How far the club turned from address to the top (degrees).
    var backswingDegrees: Double { points.isEmpty ? 0 : points[index(at: phases.top)].angle * 180 / .pi }

    /// `samples` should run from the start of the swing through the follow-through.
    static func make(_ samples: [Sample], phases: SwingPhases) -> SwingArc? {
        guard samples.count >= 5 else { return nil }
        // Core Motion's attitude turns earbud-frame vectors into the world frame (checked against M0 data).
        let world = samples.map { $0.q.rotate(SIMD3($0.rx, $0.ry, $0.rz)) }
        guard let peak = world.max(by: { simd_length($0) < simd_length($1) }), simd_length(peak) > 0 else { return nil }

        // The swing plane's normal: the average turning axis, with backswing and downswing lined up.
        let sum = world.reduce(SIMD3<Double>()) { $0 + (simd_dot($1, peak) >= 0 ? $1 : -$1) }
        guard simd_length(sum) > 0 else { return nil }
        let n = simd_normalize(sum)
        var other = SIMD3<Double>()
        other[(0..<3).min { abs(n[$0]) < abs(n[$1]) } ?? 0] = 1
        let u = simd_normalize(simd_cross(n, other)), v = simd_cross(n, u)
        // A direction fixed in the hand that lies along u at address.
        let pointer = samples[0].q.conjugate.rotate(u)

        var points: [Point] = []
        for s in samples {
            let p = s.q.rotate(pointer)
            var angle = atan2(simd_dot(p, v), simd_dot(p, u))
            if let previous = points.last?.angle {
                while angle - previous > .pi { angle -= 2 * .pi }
                while angle - previous < -.pi { angle += 2 * .pi }
            }
            points.append(Point(t: s.t, angle: angle, offPlane: asin(max(-1, min(1, simd_dot(p, n))))))
        }

        var arc = SwingArc(points: points, phases: phases)
        if arc.points[arc.index(at: phases.top)].angle < 0 {
            // Seen from the other side of the plane, so the backswing turns the positive way.
            arc.points = points.map { Point(t: $0.t, angle: -$0.angle, offPlane: -$0.offPlane) }
        }
        return arc
    }
}

private extension Quat {
    var conjugate: Quat { Quat(w: w, x: -x, y: -y, z: -z) }

    /// Rotates `v` by this orientation.
    func rotate(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let q = SIMD3(x, y, z)
        let t = 2 * simd_cross(q, v)
        return v + w * t + simd_cross(q, t)
    }
}
