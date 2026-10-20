import AVFoundation
import Foundation
import UIKit

/// Runs one practice session: address calibration, a practice swing, then the Ready loop.
/// Records every sample from start to stop and saves on stop, disconnect or backgrounding.
final class PracticeSession: ObservableObject {
    enum Phase: Equatable {
        case idle, holdingAddress, practiceSwing, practicing, finished
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var holdProgress = 0.0
    @Published private(set) var holdIsStill = false
    @Published private(set) var detectorState: ReadyDetector.State = .notReady
    /// Why the detector isn't ready yet, e.g. "Back to address · 40° off".
    @Published private(set) var readyHint: String?
    @Published private(set) var reps: [Rep] = []
    @Published private(set) var waggleCount = 0
    @Published private(set) var warning: String?
    @Published private(set) var lastSaved: SessionRecord?

    /// Seconds without samples before the session warns that motion stopped.
    static let stallTimeout = 1.5

    private let motion: MotionSource
    private let store: SessionStore
    private let settings: AppSettings
    private let baselines: BaselineStore
    private let speech = AVSpeechSynthesizer()

    private(set) var detection = DetectionSettings()
    private var samples: [Sample] = []
    private var events: [SessionEvent] = []
    private var startUptime = 0.0
    private var startedAt = Date()
    private var calibrator: AddressCalibrator?
    private var calibration: Calibration?
    private var detector: ReadyDetector?
    private var lastSampleUptime = 0.0
    private var stalled = false
    private var stallTimer: Timer?

    init(motion: MotionSource, store: SessionStore, settings: AppSettings, baselines: BaselineStore) {
        self.motion = motion
        self.store = store
        self.settings = settings
        self.baselines = baselines
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        motion.onSample = { [weak self] in self?.handle($0) }
        motion.onDisconnect = { [weak self] in self?.stop(reason: .disconnected) }
    }

    var isActive: Bool {
        phase == .holdingAddress || phase == .practiceSwing || phase == .practicing
    }

    var baseline: Baseline? { baselines.baseline(settings.values.activeBaselineID) }

    var stats: SessionStats {
        SessionStats.compute(reps, baseline: baseline, target: settings.values.activeTarget)
    }

    func start() {
        guard !isActive else { return }
        motion.start()
        detection = settings.values.detection
        samples.removeAll()
        events.removeAll()
        reps.removeAll()
        waggleCount = 0
        warning = nil
        lastSaved = nil
        calibration = nil
        detector = nil
        stalled = false
        startUptime = ProcessInfo.processInfo.systemUptime
        lastSampleUptime = startUptime
        startedAt = Date()
        calibrator = AddressCalibrator(stillSpeed: detection.stillSpeed)
        holdProgress = 0
        phase = .holdingAddress
        log("session started; connected=\(motion.isConnected) permission=\(motion.authorizationText)")

        UIApplication.shared.isIdleTimerDisabled = true
        stallTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkStall()
        }
    }

    func skipPracticeSwing() {
        guard phase == .practiceSwing else { return }
        log("practice swing skipped")
        phase = .practicing
    }

    /// Ends the session and saves everything recorded so far.
    func stop(reason: EndReason = .stopped) {
        guard isActive else { return }
        log("session ended: \(reason.rawValue)")
        stallTimer?.invalidate()
        stallTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false

        let record = SessionRecord(
            name: "Session " + startedAt.formatted(date: .abbreviated, time: .shortened),
            startedAt: startedAt,
            device: "\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)",
            sensors: Array(Set(samples.map(\.sensor))).sorted(),
            settings: detection,
            calibration: calibration,
            reps: reps,
            events: events,
            quality: QualityReport.measure(samples.map(\.t)),
            endReason: reason
        )
        do {
            try store.save(record, samples: samples)
            lastSaved = record
        } catch {
            warning = "Could not save the session: \(error.localizedDescription)"
        }
        detectorState = .notReady
        readyHint = nil
        phase = .finished
    }

    private func handle(_ raw: Sample) {
        guard isActive else { return }
        lastSampleUptime = ProcessInfo.processInfo.systemUptime
        if stalled {
            stalled = false
            warning = nil
            log("motion resumed")
        }

        let s = raw.shifted(by: startUptime)
        samples.append(s)

        switch phase {
        case .holdingAddress:
            guard let calibrator else { return }
            if let result = calibrator.process(s) {
                calibration = result
                detector = ReadyDetector(address: result.address, settings: detection)
                log(String(format: "address set; rest noise %.3f rad/s", result.restNoise))
                phase = .practiceSwing
            }
            let progress = (calibrator.progress * 20).rounded() / 20
            if progress != holdProgress { holdProgress = progress }
            if calibrator.isStill != holdIsStill { holdIsStill = calibrator.isStill }

        case .practiceSwing, .practicing:
            guard let detector else { return }
            for event in detector.process(s) { handle(event) }
            if detector.state != detectorState { detectorState = detector.state }
            let hint = Self.hint(for: detector)
            if hint != readyHint {
                // Log only the kind of hint, not every change in the degree count.
                if hint?.prefix(4) != readyHint?.prefix(4) { log("hint: \(hint ?? "none")") }
                readyHint = hint
            }

        case .idle, .finished:
            break
        }
    }

    private func handle(_ event: ReadyDetector.Event) {
        switch event {
        case .ready(let t):
            log("ready", at: t)
            if settings.values.speakReady { say("Ready") }
        case .lostReady(let t):
            log("left address", at: t)
        case .swingStarted(let t):
            log("swing started", at: t)
        case .waggle(let t):
            waggleCount += 1
            log("waggle ignored", at: t)
        case .rep(let detected):
            let summary = String(format: "swing %.2f-%.2f s; peak %.1f rad/s", detected.start, detected.end, detected.peakSpeed)
            log(summary + (detected.possiblyClipped ? "; possibly clipped" : ""), at: detected.end)

            if phase == .practiceSwing {
                calibration?.practiceRep = detected
                if let peak = samples.last(where: { $0.t == detected.peakTime }) {
                    let dominant = SwingAxis.dominant(peak)
                    calibration?.downswingAxis = dominant.axis
                    calibration?.downswingSign = dominant.sign
                }
                phase = .practicing
                return
            }

            let rep = SwingAnalyzer.analyzed(detected, samples: samples, calibration: calibration, settings: detection)
            reps.append(rep)
            if let tempo = rep.tempoRatio {
                log(String(format: "tempo %.2f:1", tempo), at: detected.end)
                if settings.values.speakTempo { say(String(format: "%.1f", tempo)) }
            } else {
                log("tempo unclear: " + (rep.analysis?.issues.joined(separator: " ") ?? ""), at: detected.end)
            }
        }
    }

    private static func hint(for detector: ReadyDetector) -> String? {
        guard detector.state == .notReady || detector.state == .settling else { return nil }
        if !detector.isNearAddress {
            let degrees = Int((detector.degreesFromAddress / 5).rounded() * 5)
            return "Back to address · \(degrees)° off"
        }
        if !detector.isStill { return "Hold still" }
        return nil
    }

    private func checkStall() {
        guard isActive, !stalled,
              ProcessInfo.processInfo.systemUptime - lastSampleUptime > Self.stallTimeout else { return }
        stalled = true
        warning = "No motion data. Check the AirPods are connected and Automatic Ear Detection is off."
        log("motion stalled")
    }

    private func log(_ text: String, at t: Double? = nil) {
        events.append(SessionEvent(t: t ?? ProcessInfo.processInfo.systemUptime - startUptime, text: text))
    }

    private func say(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        speech.speak(AVSpeechUtterance(string: text))
    }
}
