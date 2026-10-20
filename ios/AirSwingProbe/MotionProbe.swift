import CoreMotion
import Foundation
import UIKit

/// The five Gate 0A test conditions from the PRD.
enum TrialCondition: String, CaseIterable, Identifiable {
    case wornInEar = "Worn in ear, ear detection on"
    case handheldDetectionOn = "Handheld, ear detection on"
    case handheldDetectionOff = "Handheld, ear detection off"
    case openThenClosedHand = "Open palm, then closed hand"
    case deskThenRotated = "On desk, then rotated by hand"

    var id: String { rawValue }

    var slug: String {
        switch self {
        case .wornInEar: return "worn"
        case .handheldDetectionOn: return "handheld-ed-on"
        case .handheldDetectionOff: return "handheld-ed-off"
        case .openThenClosedHand: return "palm-to-closed"
        case .deskThenRotated: return "desk-rotated"
        }
    }
}

struct MotionSample {
    /// Seconds since recording started, on the same uptime clock Core Motion uses.
    let t: TimeInterval
    let quaternion: CMQuaternion
    let rotationRate: CMRotationRate
    let userAcceleration: CMAcceleration
    let sensor: String
}

struct RecordingSummary {
    let sampleCount: Int
    let duration: TimeInterval
    let effectiveHz: Double
    let gapCount: Int
    let maxIntervalMs: Double
    let file: URL?
}

/// Streams AirPods headphone motion, measures sample timing, and records trials to CSV.
final class MotionProbe: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {
    /// An interval longer than this counts as a gap. Fixed so results compare across trials.
    static let gapThreshold: TimeInterval = 0.1

    private let manager = CMHeadphoneMotionManager()

    @Published private(set) var isStreaming = false
    @Published private(set) var isConnected = false
    @Published private(set) var latest: CMDeviceMotion?
    @Published private(set) var lastSampleDate: Date?
    @Published private(set) var liveHz: Double = 0
    @Published private(set) var lastError: String?

    @Published var condition: TrialCondition = .wornInEar
    @Published private(set) var isRecording = false
    @Published private(set) var recordedCount = 0
    @Published private(set) var recordedGaps = 0
    @Published private(set) var lastSummary: RecordingSummary?
    @Published private(set) var savedFiles: [URL] = []

    private var recentTimestamps: [TimeInterval] = []
    private var samples: [MotionSample] = []
    private var events: [(TimeInterval, String)] = []
    private var recordStartUptime: TimeInterval = 0
    private var recordStartDate = Date()
    private var lastRecordedTimestamp: TimeInterval?
    private var maxInterval: TimeInterval = 0

    override init() {
        super.init()
        manager.delegate = self
        refreshFiles()
    }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isActive: Bool { manager.isDeviceMotionActive }

    var authorizationText: String {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .notDetermined: return "Not asked yet"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorized: return "Allowed"
        @unknown default: return "Unknown"
        }
    }

    // MARK: Streaming

    func startStream() {
        guard !isStreaming else { return }
        lastError = nil
        recentTimestamps.removeAll()
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.lastError = error.localizedDescription
                self.logEvent("error: \(error.localizedDescription)")
                return
            }
            if let motion { self.handle(motion) }
        }
        isStreaming = true
        logEvent("stream started")
    }

    func stopStream() {
        if isRecording { stopRecording() }
        manager.stopDeviceMotionUpdates()
        isStreaming = false
        liveHz = 0
    }

    private func handle(_ motion: CMDeviceMotion) {
        latest = motion
        lastSampleDate = Date()

        recentTimestamps.append(motion.timestamp)
        if recentTimestamps.count > 64 { recentTimestamps.removeFirst() }
        if let first = recentTimestamps.first, let last = recentTimestamps.last, last > first {
            liveHz = Double(recentTimestamps.count - 1) / (last - first)
        }

        guard isRecording else { return }
        if let previous = lastRecordedTimestamp {
            let interval = motion.timestamp - previous
            maxInterval = max(maxInterval, interval)
            if interval > Self.gapThreshold { recordedGaps += 1 }
        }
        lastRecordedTimestamp = motion.timestamp
        samples.append(MotionSample(
            t: motion.timestamp - recordStartUptime,
            quaternion: motion.attitude.quaternion,
            rotationRate: motion.rotationRate,
            userAcceleration: motion.userAcceleration,
            sensor: Self.sensorName(motion.sensorLocation)
        ))
        recordedCount = samples.count
    }

    private static func sensorName(_ location: CMDeviceMotion.SensorLocation) -> String {
        switch location {
        case .default: return "default"
        case .headphoneLeft: return "left"
        case .headphoneRight: return "right"
        @unknown default: return "unknown"
        }
    }

    // MARK: Recording

    func startRecording() {
        if !isStreaming { startStream() }
        samples.removeAll()
        events.removeAll()
        recordedCount = 0
        recordedGaps = 0
        maxInterval = 0
        lastRecordedTimestamp = nil
        lastSummary = nil
        recordStartUptime = ProcessInfo.processInfo.systemUptime
        recordStartDate = Date()
        isRecording = true
        logEvent("recording started; connected=\(isConnected) active=\(isActive) available=\(isAvailable) permission=\(authorizationText)")
    }

    func stopRecording() {
        guard isRecording else { return }
        logEvent("recording stopped")
        isRecording = false

        let duration = samples.count > 1 ? samples[samples.count - 1].t - samples[0].t : 0
        let hz = duration > 0 ? Double(samples.count - 1) / duration : 0
        let file = writeCSV()
        lastSummary = RecordingSummary(
            sampleCount: samples.count,
            duration: duration,
            effectiveHz: hz,
            gapCount: recordedGaps,
            maxIntervalMs: maxInterval * 1000,
            file: file
        )
        refreshFiles()
    }

    private func logEvent(_ text: String) {
        guard isRecording else { return }
        events.append((ProcessInfo.processInfo.systemUptime - recordStartUptime, text))
    }

    // MARK: Files

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func writeCSV() -> URL? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let name = "airswing_\(condition.slug)_\(stamp.string(from: recordStartDate)).csv"
        let url = documentsURL.appendingPathComponent(name)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var lines: [String] = [
            "# app=AirSwing Probe \(version)",
            "# condition=\(condition.rawValue)",
            "# started=\(ISO8601DateFormatter().string(from: recordStartDate))",
            "# device=\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)",
            "# gap_threshold_s=\(Self.gapThreshold)",
            "# units: timestamp seconds since record start; rotation rad/s; user acceleration g",
        ]
        for (t, text) in events {
            lines.append("# event,\(String(format: "%.4f", t)),\(text.replacingOccurrences(of: ",", with: ";"))")
        }
        lines.append("timestamp_s,qw,qx,qy,qz,rot_x,rot_y,rot_z,acc_x,acc_y,acc_z,sensor")
        for s in samples {
            let q = s.quaternion, r = s.rotationRate, a = s.userAcceleration
            lines.append(String(
                format: "%.5f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,",
                s.t, q.w, q.x, q.y, q.z, r.x, r.y, r.z, a.x, a.y, a.z
            ) + s.sensor)
        }

        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            lastError = "Could not save: \(error.localizedDescription)"
            return nil
        }
    }

    func refreshFiles() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: documentsURL, includingPropertiesForKeys: nil)) ?? []
        savedFiles = urls.filter { $0.pathExtension == "csv" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshFiles()
    }

    // MARK: CMHeadphoneMotionManagerDelegate

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.logEvent("headphones connected")
        }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.logEvent("headphones disconnected")
        }
    }
}
