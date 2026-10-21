@testable import AirSwing
import XCTest

final class PhaseDetectorTests: XCTestCase {
    private let settings = DetectionSettings()

    /// Rep covering the whole synthetic sample run.
    private func rep(_ samples: [Sample], clipped: Bool = false) -> Rep {
        Rep(readyTime: 0, start: samples[0].t, end: samples[samples.count - 1].t, peakSpeed: samples.map(\.speed).max() ?? 0,
            peakTime: 0, possiblyClipped: clipped, timedOut: false)
    }

    private func analyze(_ segments: [Synth.Segment], clipped: Bool = false,
                         axis: (axis: Int, sign: Int)? = (1, 1)) -> PhaseAnalysis {
        let samples = Synth.samples(segments)
        return PhaseDetector.analyze(samples, rep: rep(samples, clipped: clipped), axis: axis, settings: settings)
    }

    func testFindsTopAndDownswingEnd() {
        // 1.0 s backswing, 0.4 s downswing, then follow-through the other way.
        let a = analyze([Synth.turn(1.0, -3), Synth.turn(0.4, 12), Synth.turn(0.3, -2)])
        let p = try! XCTUnwrap(a.phases)
        XCTAssertEqual(a.confidence, .high, "\(a.issues)")
        XCTAssertEqual(p.backswing, 1.0, accuracy: 0.03)
        XCTAssertEqual(p.downswing, 0.4, accuracy: 0.03)
        XCTAssertEqual(p.tempoRatio, 2.5, accuracy: 0.2)
        XCTAssertTrue(a.showsTempo)
    }

    func testOppositeSignConventionGivesSameTempo() {
        let a = analyze([Synth.turn(1.0, 3), Synth.turn(0.4, -12), Synth.turn(0.3, 2)], axis: (1, -1))
        XCTAssertEqual(try XCTUnwrap(a.phases).tempoRatio, 2.5, accuracy: 0.2)
    }

    func testFallsBackToDominantAxisWithoutCalibration() {
        let a = analyze([Synth.turn(1.0, -3), Synth.turn(0.4, 12), Synth.turn(0.3, -2)], axis: nil)
        XCTAssertEqual(a.axis, 1)
        XCTAssertEqual(a.sign, 1)
        XCTAssertNotNil(a.phases)
    }

    func testNoBackswingIsNotScored() {
        let a = analyze([Synth.turn(0.5, 12), Synth.turn(0.3, -2)])
        XCTAssertEqual(a.confidence, .none)
        XCTAssertFalse(a.showsTempo)
    }

    func testGapDuringSwingIsNotScored() {
        var samples = Synth.samples([Synth.turn(1.0, -3), Synth.turn(0.4, 12), Synth.turn(0.3, -2)])
        samples.removeSubrange(20..<30)
        let a = PhaseDetector.analyze(samples, rep: rep(samples), axis: (1, 1), settings: settings)
        XCTAssertEqual(a.confidence, .none)
    }

    func testClippedSwingIsMediumConfidenceButStillScored() {
        let a = analyze([Synth.turn(1.0, -3), Synth.turn(0.3, 17.4), Synth.turn(0.3, -2)], clipped: true)
        XCTAssertEqual(a.confidence, .medium)
        XCTAssertTrue(a.showsTempo)
    }

    // MARK: Glove mode

    /// 1.0 s backswing, then a flat 0.4 s downswing peak (like a clipped sensor), with an optional
    /// acceleration jump at sample `impactAt`.
    private func gloveSwing(impactAt: Int?) -> PhaseAnalysis {
        var samples = Synth.samples([Synth.turn(1.0, -3), Synth.turn(0.4, 12), Synth.turn(0.3, -2)])
        if let impactAt { samples[impactAt].ax = 3 }
        return PhaseDetector.analyze(samples, rep: rep(samples), axis: (1, 1), settings: .glove)
    }

    func testGloveDownswingEndsAtImpact() {
        let a = gloveSwing(impactAt: 65)
        let p = try! XCTUnwrap(a.phases)
        XCTAssertEqual(p.downswingEnd, 1.3, accuracy: 1e-9)
        XCTAssertEqual(p.backswing, 1.0, accuracy: 0.03)
        XCTAssertEqual(a.confidence, .high, "\(a.issues)")
        XCTAssertEqual(a.algorithmVersion, PhaseDetector.gloveVersion)
    }

    func testGloveWithoutImpactEndsAtMiddleOfPeak() {
        let a = gloveSwing(impactAt: nil)
        // The flat peak runs from 1.0 to 1.38 s; its middle sample is at 1.18 s.
        XCTAssertEqual(try XCTUnwrap(a.phases).downswingEnd, 1.18, accuracy: 1e-9)
        XCTAssertTrue(a.issues.contains { $0.contains("No impact") })
        XCTAssertTrue(a.showsTempo)
    }

    func testGloveIgnoresJumpsFarFromPeak() {
        // A jump during the backswing is not impact.
        XCTAssertEqual(try XCTUnwrap(gloveSwing(impactAt: 25).phases).downswingEnd, 1.18, accuracy: 1e-9)
    }

    func testDirectionChangesInBackswingLowerConfidence() {
        let a = analyze([Synth.turn(0.4, -3), Synth.turn(0.2, 2), Synth.turn(0.5, -3), Synth.turn(0.4, 12), Synth.turn(0.3, -2)])
        XCTAssertEqual(a.confidence, .low)
        XCTAssertFalse(a.showsTempo)
    }

    func testManualPhasesOverrideAndCountAsScorable() {
        var r = rep(Synth.samples([Synth.turn(1, 12)]))
        r.analysis = PhaseAnalysis(phases: nil, confidence: .none, issues: [], axis: 1, sign: 1, algorithmVersion: "x")
        XCTAssertFalse(r.isScorable)
        r.manualPhases = SwingPhases(start: 0, top: 0.9, downswingEnd: 1.2)
        XCTAssertEqual(try XCTUnwrap(r.tempoRatio), 3, accuracy: 1e-9)
        XCTAssertTrue(r.isScorable)
        r.review = .rejected
        XCTAssertFalse(r.isScorable)
    }
}

final class SignatureTests: XCTestCase {
    private let swing = Synth.samples([Synth.turn(1.0, -3), Synth.turn(0.4, 12), Synth.turn(0.3, -2)])
    private let phases = SwingPhases(start: 0, top: 1.0, downswingEnd: 1.4)

    func testSignatureHasFixedLength() {
        let sig = try! XCTUnwrap(Signature.make(swing, phases: phases, axis: 1, sign: 1))
        XCTAssertEqual(sig.count, Signature.backswingPoints + Signature.downswingPoints)
        XCTAssertEqual(sig[10], -3, accuracy: 1e-9)
        XCTAssertEqual(sig[80], 12, accuracy: 1e-9)
    }

    func testShapeMatchIgnoresSpeedAndDetectsDifferentShapes() {
        let a = try! XCTUnwrap(Signature.make(swing, phases: phases, axis: 1, sign: 1))
        XCTAssertEqual(try XCTUnwrap(Signature.shapeMatch(a, a)), 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Signature.shapeMatch(a, a.map { $0 * 0.5 })), 100, accuracy: 1e-9)
        let flat = (0..<100).map { $0 < 50 ? -1.0 : 1.0 }
        XCTAssertLessThan(try XCTUnwrap(Signature.shapeMatch(a, flat)), 95)
    }

    func testComparisonAgainstBaseline() {
        let sig = try! XCTUnwrap(Signature.make(swing, phases: phases, axis: 1, sign: 1))
        let baseline = Baseline(name: "B", signature: sig, tempoRatio: 2.0, backswing: 1, downswing: 0.5,
                                peakSpeed: 10, sessionID: UUID(), repID: UUID())
        var r = Rep(readyTime: 0, start: 0, end: 1.7, peakSpeed: 12, peakTime: 1.2, possiblyClipped: false, timedOut: false)
        r.manualPhases = phases
        r.signature = sig
        let c = try! XCTUnwrap(Comparison.make(r, to: baseline))
        XCTAssertEqual(c.shapeMatch, 100, accuracy: 1e-6)
        XCTAssertEqual(c.speedRatio, 1.2, accuracy: 1e-9)
        XCTAssertEqual(c.tempoDifference, 0.5, accuracy: 1e-9)
    }
}

final class SessionStatsTests: XCTestCase {
    private func rep(back: Double, down: Double, review: Rep.Review = .unreviewed) -> Rep {
        var r = Rep(readyTime: 0, start: 0, end: back + down, peakSpeed: 10, peakTime: back, possiblyClipped: false, timedOut: false)
        r.manualPhases = SwingPhases(start: 0, top: back, downswingEnd: back + down)
        r.review = review
        return r
    }

    func testMedianAndSpread() {
        let reps = [rep(back: 1.0, down: 0.5), rep(back: 1.2, down: 0.4), rep(back: 0.9, down: 0.45),
                    rep(back: 1.5, down: 0.3, review: .rejected)]
        let s = SessionStats.compute(reps, baseline: nil, target: nil)
        XCTAssertEqual(s.swingCount, 4)
        XCTAssertEqual(s.scoredCount, 3)
        XCTAssertEqual(s.rejectedCount, 1)
        XCTAssertEqual(try XCTUnwrap(s.medianTempo), 2.0, accuracy: 1e-9)
        XCTAssertNotNil(s.tempoIQR)
        XCTAssertEqual(try XCTUnwrap(s.medianBackswing), 1.0, accuracy: 1e-9)
    }

    func testTargetCountAndFeedback() {
        let reps = [rep(back: 1.5, down: 0.5), rep(back: 1.4, down: 0.5), rep(back: 1.0, down: 0.5)]
        let s = SessionStats.compute(reps, baseline: nil, target: 3.0)
        XCTAssertEqual(s.onTargetCount, 2)
        let lines = s.feedback(target: 3.0)
        XCTAssertTrue(lines.contains { $0.hasPrefix("Your median tempo was 2.8:1 across 3 scored swings") }, "\(lines)")
        XCTAssertTrue(lines.contains("2 of 3 scored swings were within 10% of your 3.0:1 target."), "\(lines)")
    }

    func testFewSwingsAskForMore() {
        let s = SessionStats.compute([rep(back: 1, down: 0.5)], baseline: nil, target: nil)
        XCTAssertTrue(s.feedback(target: nil).contains("Record at least 3 clear swings for consistency statistics."))
    }

    func testQuantile() {
        XCTAssertEqual(SessionStats.quantile([1, 2, 3, 4], 0.5), 2.5)
        XCTAssertEqual(SessionStats.quantile([5], 0.25), 5)
        XCTAssertNil(SessionStats.quantile([], 0.5))
    }
}

final class PersistenceTests: XCTestCase {
    func testPreferencesPersist() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let a = AppSettings(defaults: defaults)
        a.values.tempoTarget = 2.5
        a.values.detection.readyHold = 1.2
        let b = AppSettings(defaults: defaults)
        XCTAssertEqual(b.values.tempoTarget, 2.5)
        XCTAssertEqual(b.values.detection.readyHold, 1.2)
    }

    func testBaselinesPersist() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BaselineStore(url: url)
        let b = Baseline(name: "Smooth", signature: [1, 2, 3], tempoRatio: 2.4, backswing: 1, downswing: 0.4,
                         peakSpeed: 12, sessionID: UUID(), repID: UUID())
        store.add(b)
        store.rename(b.id, to: "Smoothest")
        XCTAssertEqual(BaselineStore(url: url).baselines.map(\.name), ["Smoothest"])
        store.delete(b.id)
        XCTAssertTrue(BaselineStore(url: url).baselines.isEmpty)
    }

    func testSessionSavedBeforeM2StillLoads() throws {
        // A rep as written by the 0.2.0 build: no analysis, manualPhases or signature keys.
        let json = """
        {"id":"\(UUID().uuidString)","readyTime":1,"start":1.5,"end":3.2,"peakSpeed":12,"peakTime":2.6,
         "possiblyClipped":false,"timedOut":false,"review":"confirmed"}
        """
        let rep = try JSONDecoder().decode(Rep.self, from: Data(json.utf8))
        XCTAssertNil(rep.analysis)
        XCTAssertEqual(rep.review, .confirmed)
    }

    func testSwingsCSVHasOneRowPerSwing() {
        var r = Rep(readyTime: 0, start: 0, end: 2, peakSpeed: 10, peakTime: 1, possiblyClipped: false, timedOut: false)
        r.manualPhases = SwingPhases(start: 0, top: 1.0, downswingEnd: 1.4)
        let lines = SwingsCSV.encode([r, r]).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].hasPrefix("1,unreviewed,0.000,1.000,1.400,1.000,0.400,2.500,manual,yes"), String(lines[1]))
    }
}
