import CoreMotion
import Foundation

/// Streams AirPods headphone motion. Sample timestamps are on Core Motion's uptime clock.
final class MotionSource: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()

    @Published private(set) var isStreaming = false
    @Published private(set) var isConnected = false
    /// Latest sample, published at most 10 times a second to keep the UI light.
    @Published private(set) var latest: Sample?
    @Published private(set) var lastSampleDate: Date?
    @Published private(set) var liveHz: Double = 0
    @Published private(set) var lastError: String?

    /// Called on the main queue for every sample.
    var onSample: ((Sample) -> Void)?
    var onDisconnect: (() -> Void)?

    private var recentTimestamps: [TimeInterval] = []
    private var lastPublish = Date.distantPast

    override init() {
        super.init()
        manager.delegate = self
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

    func start() {
        guard !isStreaming else { return }
        lastError = nil
        recentTimestamps.removeAll()
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.lastError = error.localizedDescription
                return
            }
            if let motion { self.handle(motion) }
        }
        isStreaming = true
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isStreaming = false
        liveHz = 0
    }

    func restart() {
        stop()
        start()
    }

    private func handle(_ motion: CMDeviceMotion) {
        let sample = Sample(motion)
        let now = Date()
        lastSampleDate = now

        recentTimestamps.append(sample.t)
        if recentTimestamps.count > 64 { recentTimestamps.removeFirst() }

        if now.timeIntervalSince(lastPublish) >= 0.1 {
            lastPublish = now
            latest = sample
            if let first = recentTimestamps.first, let last = recentTimestamps.last, last > first {
                liveHz = Double(recentTimestamps.count - 1) / (last - first)
            }
        }
        onSample?(sample)
    }

    // MARK: CMHeadphoneMotionManagerDelegate

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async {
            self.isConnected = true
        }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.onDisconnect?()
        }
    }
}

extension Sample {
    init(_ m: CMDeviceMotion) {
        let q = m.attitude.quaternion, r = m.rotationRate, a = m.userAcceleration
        let sensor: String
        switch m.sensorLocation {
        case .default: sensor = "default"
        case .headphoneLeft: sensor = "left"
        case .headphoneRight: sensor = "right"
        @unknown default: sensor = "unknown"
        }
        self.init(
            t: m.timestamp, q: Quat(w: q.w, x: q.x, y: q.y, z: q.z),
            rx: r.x, ry: r.y, rz: r.z, ax: a.x, ay: a.y, az: a.z,
            sensor: sensor
        )
    }
}
