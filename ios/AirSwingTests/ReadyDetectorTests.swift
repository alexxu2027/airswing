@testable import AirSwing
import XCTest

final class ReadyDetectorTests: XCTestCase {
    private let settings = DetectionSettings()

    private func detector() -> ReadyDetector {
        ReadyDetector(address: .identity, settings: settings)
    }

    /// Shaped like the M0 swings: ~1 s backswing at -3 rad/s, fast downswing, short follow-through.
    private let swing: [Synth.Segment] = [
        Synth.turn(1.0, -3), Synth.turn(0.4, 12), Synth.turn(0.3, -2),
    ]

    func testStillAtAddressBecomesReadyAfterHold() {
        let events = detector().run(Synth.samples([Synth.still(1.5)]))
        guard case .ready(let t)? = events.first else { return XCTFail("expected ready, got \(events)") }
        XCTAssertEqual(t, settings.readyHold, accuracy: 0.05)
    }

    func testFullSwingProducesOneRep() {
        let events = detector().run(Synth.samples([Synth.still(1.5)] + swing + [Synth.still(1.5)]))
        XCTAssertEqual(events.reps.count, 1)
        let rep = try! XCTUnwrap(events.reps.first)
        XCTAssertEqual(rep.start, 1.5, accuracy: 0.05)
        XCTAssertEqual(rep.end, 3.2, accuracy: 0.15)
        XCTAssertEqual(rep.peakSpeed, 12, accuracy: 1e-9)
        XCTAssertEqual(rep.readyTime, settings.readyHold, accuracy: 0.05)
        XCTAssertFalse(rep.possiblyClipped)
        XCTAssertFalse(rep.timedOut)
    }

    func testBriefReversalAtTopDoesNotEndSwing() {
        // A short near-still moment at the top of the backswing must not split the swing.
        let samples = Synth.samples([Synth.still(1.5), Synth.turn(1.0, -3), Synth.still(0.2),
                                     Synth.turn(0.4, 12), Synth.still(1.5)])
        XCTAssertEqual(detector().run(samples).reps.count, 1)
    }

    func testWaggleIsNotASwingAndReadyReturns() {
        let samples = Synth.samples([Synth.still(1.5), Synth.turn(0.5, 2), Synth.still(2.5)])
        let events = detector().run(samples)
        XCTAssertEqual(events.reps.count, 0)
        XCTAssertEqual(events.waggleCount, 1)
        XCTAssertEqual(events.readyCount, 2)
    }

    func testStillAwayFromAddressNeverReady() {
        let samples = Synth.samples([Synth.still(3, q: Synth.rotated(45))])
        XCTAssertEqual(detector().run(samples).readyCount, 0)
    }

    func testStillWithinToleranceIsReady() {
        // M0 address poses varied by up to 24° between swings.
        let samples = Synth.samples([Synth.still(1.5, q: Synth.rotated(25))])
        XCTAssertEqual(detector().run(samples).readyCount, 1)
    }

    func testSlightHandTremorStillCountsAsStill() {
        // Typical M0 address pause: 0.2–0.4 rad/s of drift.
        let samples = Synth.samples([Synth.turn(1.5, 0.4)])
        XCTAssertEqual(detector().run(samples).readyCount, 1)
    }

    func testAddressFollowsWhereUserActuallySwingsFrom() {
        let pose = Synth.rotated(30)
        var segments: [Synth.Segment] = []
        for _ in 0..<4 { segments += [Synth.still(2.5, q: pose)] + swing }
        segments.append(Synth.still(1.0, q: Synth.rotated(55)))

        let d = detector()
        XCTAssertEqual(d.run(Synth.samples(segments)).reps.count, 4)
        // Calibrated identity blended with four swings from 30°.
        XCTAssertEqual(d.address.angle(to: .identity) * 180 / .pi, 24, accuracy: 1)
        // 55° was outside tolerance of the original address but is within it now.
        XCTAssertTrue(d.isNearAddress)
    }

    func testHintValuesExposed() {
        let d = detector()
        _ = d.run(Synth.samples([Synth.still(0.5, q: Synth.rotated(45))]))
        XCTAssertEqual(d.degreesFromAddress, 45, accuracy: 0.01)
        XCTAssertFalse(d.isNearAddress)
        XCTAssertTrue(d.isStill)
    }

    func testFastSwingIsFlaggedPossiblyClipped() {
        let samples = Synth.samples([Synth.still(1.5), Synth.turn(1.0, -3), Synth.turn(0.3, 17.4), Synth.still(1.5)])
        let rep = try! XCTUnwrap(detector().run(samples).reps.first)
        XCTAssertTrue(rep.possiblyClipped)
    }

    func testSwingThatNeverSettlesTimesOut() {
        let samples = Synth.samples([Synth.still(1.5), Synth.turn(8, 6)])
        let rep = try! XCTUnwrap(detector().run(samples).reps.first)
        XCTAssertTrue(rep.timedOut)
        XCTAssertEqual(rep.duration, settings.maxSwingDuration, accuracy: 0.05)
    }

    func testRepeatedSwingsAreEachDetected() {
        // Between swings: finish hold (0.5 s) plus a fresh Ready hold (1 s), with margin.
        let one = [Synth.still(2.5)] + swing
        let samples = Synth.samples(one + one + one + [Synth.still(1.5)])
        XCTAssertEqual(detector().run(samples).reps.count, 3)
    }
}

final class AddressCalibratorTests: XCTestCase {
    func testStillHoldSetsAddress() {
        let q = Synth.rotated(30)
        let calibrator = AddressCalibrator(stillSpeed: 0.3)
        let result = Synth.samples([Synth.still(3.5, q: q)]).lazy.compactMap { calibrator.process($0) }.first
        let c = try! XCTUnwrap(result)
        XCTAssertEqual(c.completedAt, 3.0, accuracy: 0.05)
        XCTAssertEqual(c.address.angle(to: q), 0, accuracy: 1e-6)
        XCTAssertEqual(c.holdRateHz, 50, accuracy: 0.5)
    }

    func testMovementRestartsHold() {
        let calibrator = AddressCalibrator(stillSpeed: 0.3)
        let samples = Synth.samples([Synth.still(2), Synth.turn(0.3, 3), Synth.still(4)])
        let c = try! XCTUnwrap(samples.lazy.compactMap { calibrator.process($0) }.first)
        XCTAssertGreaterThan(c.completedAt, 5.2)
    }
}

final class QuatTests: XCTestCase {
    func testAngleBetweenOrientations() {
        XCTAssertEqual(Quat.identity.angle(to: Synth.rotated(90)), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(Quat.identity.angle(to: Quat(w: -1, x: 0, y: 0, z: 0)), 0, accuracy: 1e-9)
    }

    func testAverageOfNearbyOrientations() {
        let avg = try! XCTUnwrap(Quat.average([Synth.rotated(-4), Synth.rotated(4)]))
        XCTAssertEqual(avg.angle(to: .identity), 0, accuracy: 1e-6)
    }
}
