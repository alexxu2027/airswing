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
    }
}
