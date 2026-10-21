@testable import AirSwing
import XCTest

/// Replays real recordings in Fixtures/<name>/samples.csv and checks the swings and phases match
/// Fixtures/<name>/expected.json, written by tools/analyze.py from its port of the same detector.
/// A mismatch means the Swift detector and the Python tuning tool have drifted apart.
final class ReplayFixtureTests: XCTestCase {
    struct Expected: Decodable {
        struct Swing: Decodable {
            var start: Double
            var end: Double
            var peakTime: Double
            var possiblyClipped: Bool
            var top: Double?
            var downswingEnd: Double?
            var confidence: PhaseConfidence
        }

        var practiceSwing: Bool
        var settings: DetectionSettings
        var swings: [Swing]
        var waggles: Int
    }

    static let tolerance = 1e-6

    func testRecordingsMatchExpected() throws {
        let fixtures = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil),
                                     "Fixtures folder missing from the test bundle")
        let names = try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
            .filter { FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("\($0)/expected.json").path) }
            .sorted()
        XCTAssertFalse(names.isEmpty, "No fixtures found")

        for name in names {
            let folder = fixtures.appendingPathComponent(name)
            let expected = try JSONDecoder().decode(Expected.self,
                                                    from: Data(contentsOf: folder.appendingPathComponent("expected.json")))
            let samples = SampleCSV.decode(try String(contentsOf: folder.appendingPathComponent("samples.csv"), encoding: .utf8))
            let result = SessionReplay.run(samples, settings: expected.settings, practiceSwing: expected.practiceSwing)

            XCTAssertEqual(result.waggles, expected.waggles, "\(name): waggles")
            XCTAssertEqual(result.reps.count, expected.swings.count, "\(name): swing count")
            for (i, (rep, want)) in zip(result.reps, expected.swings).enumerated() {
                let label = "\(name) swing \(i + 1)"
                XCTAssertEqual(rep.start, want.start, accuracy: Self.tolerance, label)
                XCTAssertEqual(rep.end, want.end, accuracy: Self.tolerance, label)
                XCTAssertEqual(rep.peakTime, want.peakTime, accuracy: Self.tolerance, label)
                XCTAssertEqual(rep.possiblyClipped, want.possiblyClipped, label)
                XCTAssertEqual(rep.analysis?.confidence, want.confidence, label)
                let phases = rep.analysis?.phases
                XCTAssertEqual(phases == nil, want.top == nil, "\(label): phases found")
                if let phases, let top = want.top, let end = want.downswingEnd {
                    XCTAssertEqual(phases.top, top, accuracy: Self.tolerance, label)
                    XCTAssertEqual(phases.downswingEnd, end, accuracy: Self.tolerance, label)
                }
            }
        }
    }
}
