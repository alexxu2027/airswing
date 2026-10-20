import Foundation

/// Saves each session as a folder: session.json (metadata, swings, reviews) and samples.csv.
/// Lives in Documents so sessions are also visible in the Files app.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionRecord] = []

    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        reload()
    }

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func metadataURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("session.json") }
    func samplesURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("samples.csv") }
    func swingsURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("swings.csv") }

    func exportURLs(for id: UUID) -> [URL] { [metadataURL(for: id), samplesURL(for: id), swingsURL(for: id)] }

    func save(_ record: SessionRecord, samples: [Sample]) throws {
        try FileManager.default.createDirectory(at: folder(for: record.id), withIntermediateDirectories: true)
        try SampleCSV.encode(samples, comments: record.csvComments)
            .write(to: samplesURL(for: record.id), atomically: true, encoding: .utf8)
        try writeMetadata(record)
        reload()
    }

    /// Rewrites metadata only (reviews, name). Samples are never rewritten after recording.
    func update(_ record: SessionRecord) throws {
        try writeMetadata(record)
        reload()
    }

    func loadSamples(for id: UUID) throws -> [Sample] {
        SampleCSV.decode(try String(contentsOf: samplesURL(for: id), encoding: .utf8))
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
        reload()
    }

    func deleteAll() {
        for session in sessions { try? FileManager.default.removeItem(at: folder(for: session.id)) }
        reload()
    }

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        sessions = folders
            .compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")) else { return nil }
                return try? decoder.decode(SessionRecord.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func writeMetadata(_ record: SessionRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: metadataURL(for: record.id), options: .atomic)
        try SwingsCSV.encode(record.reps).write(to: swingsURL(for: record.id), atomically: true, encoding: .utf8)
    }
}

/// One row per detected swing with its phases and tempo, for spreadsheets.
enum SwingsCSV {
    static let header = "swing,review,start_s,top_s,downswing_end_s,backswing_s,downswing_s,tempo_ratio,"
        + "confidence,manual,peak_speed_rad_s,possibly_clipped,timed_out"

    static func encode(_ reps: [Rep]) -> String {
        var lines = [header]
        for (i, rep) in reps.enumerated() {
            let p = rep.effectivePhases
            func f(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "" }
            lines.append([
                "\(i + 1)", rep.review.rawValue, f(rep.start), f(p?.top), f(p?.downswingEnd),
                f(p?.backswing), f(p?.downswing), f(p?.tempoRatio),
                rep.manualPhases != nil ? "manual" : (rep.analysis?.confidence.rawValue ?? ""),
                rep.manualPhases != nil ? "yes" : "no",
                f(rep.peakSpeed), rep.possiblyClipped ? "yes" : "no", rep.timedOut ? "yes" : "no",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
