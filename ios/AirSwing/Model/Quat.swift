import Foundation

/// Unit quaternion orientation, as reported by Core Motion's attitude.
struct Quat: Codable, Equatable {
    var w: Double
    var x: Double
    var y: Double
    var z: Double

    static let identity = Quat(w: 1, x: 0, y: 0, z: 0)

    var norm: Double { (w * w + x * x + y * y + z * z).squareRoot() }

    var normalized: Quat {
        let n = norm
        return n > 0 ? Quat(w: w / n, x: x / n, y: y / n, z: z / n) : .identity
    }

    func dot(_ o: Quat) -> Double { w * o.w + x * o.x + y * o.y + z * o.z }

    /// Smallest rotation angle in radians between two orientations. q and -q are the same orientation.
    func angle(to o: Quat) -> Double {
        let d = min(1, abs(normalized.dot(o.normalized)))
        return 2 * acos(d)
    }

    /// Average of closely spaced orientations: sign-aligned sum, normalized.
    /// Accurate for the small spread of a still hold, not for widely different orientations.
    static func average(_ qs: [Quat]) -> Quat? {
        guard let ref = qs.first else { return nil }
        var sum = Quat(w: 0, x: 0, y: 0, z: 0)
        for q in qs {
            let k = q.dot(ref) < 0 ? -1.0 : 1.0
            sum.w += k * q.w
            sum.x += k * q.x
            sum.y += k * q.y
            sum.z += k * q.z
        }
        return sum.normalized
    }
}
