import Foundation

struct Preferences: Codable, Equatable {
    var detection = DetectionSettings()
    var speakReady = true
    var speakTempo = true
    var tempoTargetEnabled = false
    var tempoTarget = 3.0
    var activeBaselineID: UUID? = nil
    /// Last recording setup, reused for the next session. Optional so older saved preferences still load.
    var setup: RecordingSetup? = nil

    var activeTarget: Double? { tempoTargetEnabled ? tempoTarget : nil }
}

/// App-wide preferences, saved to UserDefaults on every change.
final class AppSettings: ObservableObject {
    @Published var values: Preferences {
        didSet { save() }
    }

    private let defaults: UserDefaults
    private static let key = "preferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(Preferences.self, from: data) {
            values = stored
        } else {
            values = Preferences()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.key) }
    }
}

/// Saved baselines, kept in one JSON file.
final class BaselineStore: ObservableObject {
    @Published private(set) var baselines: [Baseline] = []

    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("baselines.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: self.url),
           let stored = try? decoder.decode([Baseline].self, from: data) {
            baselines = stored
        }
    }

    func baseline(_ id: UUID?) -> Baseline? {
        guard let id else { return nil }
        return baselines.first { $0.id == id }
    }

    func add(_ baseline: Baseline) {
        baselines.append(baseline)
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = baselines.firstIndex(where: { $0.id == id }) else { return }
        baselines[i].name = name
        save()
    }

    func delete(_ id: UUID) {
        baselines.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(baselines).write(to: url, options: .atomic)
    }
}
