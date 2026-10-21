@testable import AirSwing
import XCTest

final class QualityTests: XCTestCase {
    func testSteadyFiftyHertz() {
        let q = QualityReport.measure((0..<500).map { Double($0) / 50 })
        XCTAssertEqual(q.effectiveHz, 50, accuracy: 1e-6)
        XCTAssertEqual(q.gapCount, 0)
        XCTAssertEqual(q.estimatedDropout, 0)
        XCTAssertTrue(q.meetsTargets)
    }

    func testGapIsCountedAndDropoutEstimated() {
        // Remove 14 samples to make one 300 ms gap.
        let t = (0..<500).map { Double($0) / 50 }.enumerated().filter { !(101...114).contains($0.offset) }.map(\.element)
        let q = QualityReport.measure(t)
        XCTAssertEqual(q.gapCount, 1)
        XCTAssertEqual(q.maxInterval, 0.3, accuracy: 1e-6)
        XCTAssertEqual(q.estimatedDropout, 14.0 / 500.0, accuracy: 1e-6)
    }

    func testEmptyAndSingleSample() {
        XCTAssertEqual(QualityReport.measure([]).sampleCount, 0)
        XCTAssertEqual(QualityReport.measure([1]).effectiveHz, 0)
    }
}

final class SampleCSVTests: XCTestCase {
    func testRoundTripKeepsEverySampleAndTimestamp() {
        let samples = Synth.samples([Synth.still(1), Synth.turn(1, -3.25)])
        let decoded = SampleCSV.decode(SampleCSV.encode(samples, comments: ["app=test", "event,0.1000,hello"]))
        XCTAssertEqual(decoded.count, samples.count)
        for (a, b) in zip(samples, decoded) {
            XCTAssertEqual(a.t, b.t, accuracy: 1e-5)
            XCTAssertEqual(a.ry, b.ry, accuracy: 1e-6)
            XCTAssertEqual(a.q.w, b.q.w, accuracy: 1e-6)
            XCTAssertEqual(a.sensor, b.sensor)
        }
    }

    func testReadsM0ProbeFormat() {
        let csv = """
        # app=AirSwing Probe 0.1.0
        # event,0.0001,recording started
        timestamp_s,qw,qx,qy,qz,rot_x,rot_y,rot_z,acc_x,acc_y,acc_z,sensor
        -0.02285,0.739032,-0.470626,0.306067,-0.372378,0.150407,0.104366,-0.127067,-0.002374,0.020864,0.003913,right
        -0.00285,0.738735,-0.469927,0.306163,-0.373769,0.075016,0.089409,-0.082052,-0.003848,0.022668,0.005251,right
        """
        let samples = SampleCSV.decode(csv)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[1].t, -0.00285, accuracy: 1e-9)
        XCTAssertEqual(samples[0].sensor, "right")
    }
}

final class SessionStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRecord() -> SessionRecord {
        SessionRecord(
            name: "Test session",
            reps: [Rep(readyTime: 1, start: 1.5, end: 3.2, peakSpeed: 12, peakTime: 2.6,
                       possiblyClipped: false, timedOut: false)],
            events: [SessionEvent(t: 0.5, text: "ready, steady")]
        )
    }

    func testSaveAndReopen() throws {
        let samples = Synth.samples([Synth.still(2)])
        let record = makeRecord()
        try SessionStore(root: root).save(record, samples: samples)

        let reopened = SessionStore(root: root)
        XCTAssertEqual(reopened.sessions.map(\.id), [record.id])
        XCTAssertEqual(reopened.sessions[0].reps, record.reps)
        XCTAssertEqual(try reopened.loadSamples(for: record.id).count, samples.count)
    }

    func testReviewPersists() throws {
        let store = SessionStore(root: root)
        var record = makeRecord()
        try store.save(record, samples: Synth.samples([Synth.still(1)]))
        record.reps[0].review = .confirmed
        try store.update(record)

        XCTAssertEqual(SessionStore(root: root).sessions[0].reps[0].review, .confirmed)
        XCTAssertEqual(try store.loadSamples(for: record.id).count, 50, "update must not touch samples")
    }

    func testDelete() throws {
        let store = SessionStore(root: root)
        let record = makeRecord()
        try store.save(record, samples: [])
        store.delete(record.id)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(for: record.id).path))
    }

    func testCSVCommentsCarryEventsForViewer() throws {
        let store = SessionStore(root: root)
        let record = makeRecord()
        try store.save(record, samples: [])
        let text = try String(contentsOf: store.samplesURL(for: record.id), encoding: .utf8)
        XCTAssertTrue(text.contains("# event,0.5000,ready; steady"))
        XCTAssertTrue(text.contains("# session=\(record.id.uuidString)"))
    }

    func testSetupIsSavedAndWrittenToCSVHeader() throws {
        let store = SessionStore(root: root)
        var record = makeRecord()
        record.setup = RecordingSetup(mount: .glove, club: "7 iron", note: "full swings\nno ball")
        try store.save(record, samples: [])

        XCTAssertEqual(SessionStore(root: root).sessions[0].setup, record.setup)
        let text = try String(contentsOf: store.samplesURL(for: record.id), encoding: .utf8)
        XCTAssertTrue(text.contains("# mount=glove\n"))
        XCTAssertTrue(text.contains("# club=7 iron\n"))
        XCTAssertTrue(text.contains("# note=full swings no ball\n"))
    }

    func testSessionWithoutSetupStillLoads() throws {
        let store = SessionStore(root: root)
        let record = makeRecord()
        try store.save(record, samples: [])
        let json = try String(contentsOf: store.metadataURL(for: record.id), encoding: .utf8)
        XCTAssertFalse(json.contains("\"setup\""), "nil setup is left out, like a session saved before it existed")
        XCTAssertNil(SessionStore(root: root).sessions[0].setup)
    }

    func testSetupLabel() {
        XCTAssertEqual(RecordingSetup().label, "")
        XCTAssertEqual(RecordingSetup(mount: .glove).label, "Glove")
        XCTAssertEqual(RecordingSetup(mount: .glove, club: " 7 iron ").label, "Glove · 7 iron")
        XCTAssertEqual(RecordingSetup(club: "Driver").label, "Driver")
    }

    func testPreferencesSavedBeforeSetupStillLoad() throws {
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as! [String: Any]
        old["tempoTarget"] = 2.5
        old.removeValue(forKey: "setup")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: "preferences")
        XCTAssertEqual(AppSettings(defaults: defaults).values.tempoTarget, 2.5)
    }
}
