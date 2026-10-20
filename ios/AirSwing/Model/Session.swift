import Foundation

/// One detected swing. Times are seconds since session start.
struct Rep: Codable, Equatable, Identifiable {
    enum Review: String, Codable {
        case unreviewed, confirmed, rejected
    }

    var id = UUID()
    var readyTime: Double
    var start: Double
    var end: Double
    var peakSpeed: Double
    var peakTime: Double
    /// A rotation axis reached the suspected ~1000°/s sensor limit, so peaks may be cut off.
    var possiblyClipped: Bool
    /// Ended by the max-duration limit rather than a held finish.
    var timedOut: Bool
    var review: Review = .unreviewed
    /// Automatic phase analysis. Optional so sessions saved before M2 still load.
    var analysis: PhaseAnalysis? = nil
    /// Boundaries the user adjusted by hand; used instead of the automatic ones.
    var manualPhases: SwingPhases? = nil
    /// Time-normalized curve from the boundaries in use, for baseline comparison.
    var signature: [Double]? = nil

    var duration: Double { end - start }
}

struct Calibration: Codable, Equatable {
    /// Seconds since session start when the address hold completed.
    var completedAt: Double
    var address: Quat
    /// Mean rotation speed (rad/s) during the still hold.
    var restNoise: Double
    var holdRateHz: Double
    /// Axis (0 = x, 1 = y, 2 = z) and sign of the fastest rotation in the practice swing.
    /// For M2: the backswing turns the opposite way on this axis.
    var downswingAxis: Int? = nil
    var downswingSign: Int? = nil
    var practiceRep: Rep? = nil
}

struct DetectionSettings: Codable, Equatable {
    /// Smoothed rotation speed below this counts as still (rad/s).
    /// M0 address pauses mostly sat at 0.2–0.5, so 0.3 was too strict.
    var stillSpeed = 0.5
    /// How long to stay still at address before Ready (s).
    var readyHold = 0.8
    /// How close to the address orientation counts as "at address".
    /// M0 address poses varied by up to 24° between swings.
    var addressToleranceDegrees = 35.0
    /// Smoothed speed that starts a swing from Ready (rad/s).
    var swingStartSpeed = 1.0
    /// Movements that never get faster than this are waggles, not swings (rad/s).
    var minPeakSpeed = 5.0
    /// How long to hold the finish still before the swing ends (s).
    var finishHold = 0.5
    /// A swing that hasn't settled after this long is ended anyway (s).
    var maxSwingDuration = 6.0
    /// Any axis at or above this is flagged as possibly clipped (rad/s). M0 found a likely 17.45 limit.
    var clipSpeed = 16.5
}

struct SessionEvent: Codable, Equatable {
    var t: Double
    var text: String
}

enum EndReason: String, Codable {
    case stopped, disconnected, backgrounded
}

/// Everything about a session except its raw samples, which live in samples.csv beside it.
struct SessionRecord: Codable, Equatable, Identifiable {
    static let currentAlgorithm = "ready-detector-1"

    var id = UUID()
    var name = ""
    var startedAt = Date()
    var appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    var algorithmVersion = SessionRecord.currentAlgorithm
    var device = ""
    var sensors: [String] = []
    var settings = DetectionSettings()
    var calibration: Calibration? = nil
    var reps: [Rep] = []
    var events: [SessionEvent] = []
    var quality = QualityReport.measure([])
    var endReason = EndReason.stopped

    var isIncomplete: Bool { endReason != .stopped }
    var confirmedCount: Int { reps.filter { $0.review == .confirmed }.count }

    /// Header comments for samples.csv, in the format the viewer understands.
    var csvComments: [String] {
        var lines = [
            "app=AirSwing \(appVersion)",
            "session=\(id.uuidString)",
            "condition=\(name)",
            "started=\(ISO8601DateFormatter().string(from: startedAt))",
            "device=\(device)",
            "gap_threshold_s=\(QualityReport.gapThreshold)",
            "units: timestamp seconds since session start; rotation rad/s; user acceleration g",
        ]
        for e in events {
            lines.append("event,\(String(format: "%.4f", e.t)),\(e.text.replacingOccurrences(of: ",", with: ";"))")
        }
        return lines
    }
}
