import Foundation

/// One Core Motion reading. Units as Core Motion reports them:
/// rotation rate in rad/s, user acceleration in g.
struct Sample: Equatable {
    /// Seconds. Uptime clock from the motion source; seconds since session start once recorded.
    var t: Double
    var q: Quat
    var rx: Double
    var ry: Double
    var rz: Double
    var ax: Double
    var ay: Double
    var az: Double
    /// Which earbud reported it: "left", "right", "default" or "unknown".
    var sensor: String

    var speed: Double { (rx * rx + ry * ry + rz * rz).squareRoot() }
    var rotation: [Double] { [rx, ry, rz] }

    func shifted(by offset: Double) -> Sample {
        var s = self
        s.t -= offset
        return s
    }
}

/// Reads and writes samples in the same CSV layout as the M0 probe, so the viewer reads both.
enum SampleCSV {
    static let header = "timestamp_s,qw,qx,qy,qz,rot_x,rot_y,rot_z,acc_x,acc_y,acc_z,sensor"

    static func encode(_ samples: [Sample], comments: [String] = []) -> String {
        var lines = comments.map { "# " + $0 }
        lines.reserveCapacity(lines.count + samples.count + 1)
        lines.append(header)
        for s in samples {
            lines.append(String(
                format: "%.5f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,",
                s.t, s.q.w, s.q.x, s.q.y, s.q.z, s.rx, s.ry, s.rz, s.ax, s.ay, s.az
            ) + s.sensor)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func decode(_ text: String) -> [Sample] {
        var samples: [Sample] = []
        var sawHeader = false
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") { continue }
            if !sawHeader {
                sawHeader = true
                continue
            }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 12 else { continue }
            let d = fields[0..<11].compactMap { Double($0) }
            guard d.count == 11 else { continue }
            samples.append(Sample(
                t: d[0], q: Quat(w: d[1], x: d[2], y: d[3], z: d[4]),
                rx: d[5], ry: d[6], rz: d[7], ax: d[8], ay: d[9], az: d[10],
                sensor: String(fields[11])
            ))
        }
        return samples
    }
}
