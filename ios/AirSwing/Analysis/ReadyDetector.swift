import Foundation

/// Finds swings with the address-pause loop:
/// still near the calibrated address for `readyHold` → Ready → first real movement starts the swing →
/// holding the finish still for `finishHold` ends it. Movements that never reach `minPeakSpeed` are waggles.
final class ReadyDetector {
    enum State: Equatable {
        case notReady, settling, ready, swinging, finishing
    }

    enum Event: Equatable {
        case ready(at: Double)
        case lostReady(at: Double)
        case swingStarted(at: Double)
        case waggle(at: Double)
        case rep(Rep)
    }

    let address: Quat
    let settings: DetectionSettings
    private(set) var state: State = .notReady

    private var smoother = SpeedSmoother()
    private var stateSince = 0.0
    private var lastStillTime = 0.0
    private var readyTime = 0.0
    private var swingStart = 0.0
    private var peakSpeed = 0.0
    private var peakTime = 0.0
    private var peakAxisRate = 0.0

    init(address: Quat, settings: DetectionSettings) {
        self.address = address
        self.settings = settings
    }

    func process(_ s: Sample) -> [Event] {
        let speed = smoother.add(t: s.t, speed: s.speed)
        let still = speed < settings.stillSpeed
        if still { lastStillTime = s.t }
        let nearAddress = s.q.angle(to: address) <= settings.addressToleranceDegrees * .pi / 180

        var events: [Event] = []
        switch state {
        case .notReady:
            if still && nearAddress { enter(.settling, at: s.t) }

        case .settling:
            if !(still && nearAddress) {
                enter(.notReady, at: s.t)
            } else if s.t - stateSince >= settings.readyHold {
                enter(.ready, at: s.t)
                readyTime = s.t
                events.append(.ready(at: s.t))
            }

        case .ready:
            if speed >= settings.swingStartSpeed {
                enter(.swinging, at: s.t)
                // Backdate the start to the last still moment, before smoothing caught up.
                swingStart = lastStillTime
                peakSpeed = 0
                peakAxisRate = 0
                track(s)
                events.append(.swingStarted(at: swingStart))
            } else if still && !nearAddress {
                enter(.notReady, at: s.t)
                events.append(.lostReady(at: s.t))
            }

        case .swinging:
            track(s)
            if still {
                enter(.finishing, at: s.t)
            } else if s.t - swingStart >= settings.maxSwingDuration {
                events.append(finish(end: s.t, timedOut: true))
            }

        case .finishing:
            track(s)
            if !still {
                enter(.swinging, at: s.t)
            } else if s.t - stateSince >= settings.finishHold {
                events.append(finish(end: stateSince, timedOut: false))
            }
        }
        return events
    }

    private func enter(_ next: State, at t: Double) {
        state = next
        stateSince = t
    }

    private func track(_ s: Sample) {
        if s.speed > peakSpeed {
            peakSpeed = s.speed
            peakTime = s.t
        }
        peakAxisRate = max(peakAxisRate, abs(s.rx), abs(s.ry), abs(s.rz))
    }

    private func finish(end: Double, timedOut: Bool) -> Event {
        enter(.notReady, at: end)
        guard peakSpeed >= settings.minPeakSpeed else { return .waggle(at: end) }
        return .rep(Rep(
            readyTime: readyTime,
            start: swingStart,
            end: end,
            peakSpeed: peakSpeed,
            peakTime: peakTime,
            possiblyClipped: peakAxisRate >= settings.clipSpeed,
            timedOut: timedOut
        ))
    }
}

/// Learns the address orientation from a still hold of `holdDuration` seconds.
/// Any movement restarts the hold.
final class AddressCalibrator {
    let stillSpeed: Double
    let holdDuration: Double
    private(set) var progress = 0.0
    private(set) var isStill = false

    private var smoother = SpeedSmoother()
    private var held: [Sample] = []

    init(stillSpeed: Double, holdDuration: Double = 3.0) {
        self.stillSpeed = stillSpeed
        self.holdDuration = holdDuration
    }

    func process(_ s: Sample) -> Calibration? {
        isStill = smoother.add(t: s.t, speed: s.speed) < stillSpeed
        guard isStill else {
            held.removeAll()
            progress = 0
            return nil
        }
        held.append(s)
        let span = s.t - held[0].t
        progress = min(1, span / holdDuration)
        guard span >= holdDuration, let address = Quat.average(held.map(\.q)) else { return nil }
        return Calibration(
            completedAt: s.t,
            address: address,
            restNoise: held.map(\.speed).reduce(0, +) / Double(held.count),
            holdRateHz: QualityReport.measure(held.map(\.t)).effectiveHz
        )
    }
}

enum SwingAxis {
    /// The axis with the largest rotation at a sample, and its sign.
    static func dominant(_ s: Sample) -> (axis: Int, sign: Int) {
        let r = s.rotation
        let axis = (0..<3).max { abs(r[$0]) < abs(r[$1]) } ?? 0
        return (axis, r[axis] >= 0 ? 1 : -1)
    }
}
