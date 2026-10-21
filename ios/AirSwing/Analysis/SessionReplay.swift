import Foundation

/// Runs a recording through the same steps as a live session: address hold, an optional practice
/// swing, then the Ready loop with phase analysis. Mirrors PracticeSession, so detection changes
/// can be checked against real recordings.
enum SessionReplay {
    struct Result {
        var calibration: Calibration?
        var reps: [Rep] = []
        var waggles = 0
    }

    static func run(_ samples: [Sample], settings: DetectionSettings, practiceSwing: Bool) -> Result {
        let calibrator = AddressCalibrator(stillSpeed: settings.stillSpeed)
        var detector: ReadyDetector?
        var awaitingPracticeSwing = practiceSwing
        var result = Result()

        for s in samples {
            guard let detector else {
                if let c = calibrator.process(s) {
                    result.calibration = c
                    detector = ReadyDetector(address: c.address, settings: settings)
                }
                continue
            }
            for event in detector.process(s) {
                switch event {
                case .waggle:
                    result.waggles += 1
                case .rep(let detected) where awaitingPracticeSwing:
                    awaitingPracticeSwing = false
                    result.calibration?.practiceRep = detected
                    if let peak = samples.first(where: { $0.t == detected.peakTime }) {
                        let dominant = SwingAxis.dominant(peak)
                        result.calibration?.downswingAxis = dominant.axis
                        result.calibration?.downswingSign = dominant.sign
                    }
                case .rep(let detected):
                    result.reps.append(SwingAnalyzer.analyzed(detected, samples: samples,
                                                              calibration: result.calibration, settings: settings))
                case .ready, .lostReady, .swingStarted:
                    break
                }
            }
        }
        return result
    }
}
