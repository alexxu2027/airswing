import Charts
import SwiftUI

struct SwingRef: Hashable {
    var session: UUID
    var rep: UUID
}

struct SessionsView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var baselines: BaselineStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            List {
                if store.sessions.count >= 2 {
                    NavigationLink {
                        TrendsView(store: store, baselines: baselines, settings: settings)
                    } label: {
                        Label("Progress across sessions", systemImage: "chart.line.uptrend.xyaxis")
                    }
                }
                if store.sessions.isEmpty {
                    Text("No sessions yet").foregroundStyle(.secondary)
                }
                ForEach(store.sessions) { session in
                    NavigationLink(value: session.id) {
                        SessionRow(session: session, stats: stats(session))
                    }
                }
                .onDelete { offsets in
                    offsets.map { store.sessions[$0].id }.forEach(store.delete)
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(store: store, baselines: baselines, settings: settings, id: id)
            }
            .navigationDestination(for: SwingRef.self) { ref in
                SwingDetailView(store: store, baselines: baselines, settings: settings, ref: ref)
            }
        }
    }

    private func stats(_ s: SessionRecord) -> SessionStats {
        SessionStats.compute(s.reps, baseline: baselines.baseline(settings.values.activeBaselineID),
                             target: settings.values.activeTarget)
    }
}

private struct SessionRow: View {
    let session: SessionRecord
    let stats: SessionStats

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.name)
            Text("\(session.reps.count) swings" + (stats.medianTempo.map { String(format: " · median %.1f:1", $0) } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            if session.isIncomplete {
                Text("Ended early: \(session.endReason.rawValue)")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct SessionDetailView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var baselines: BaselineStore
    @ObservedObject var settings: AppSettings
    let id: UUID

    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        if let session = store.sessions.first(where: { $0.id == id }) {
            content(session)
                .task(id: id) { analyzeIfNeeded(session) }
        } else {
            Text("Session deleted").foregroundStyle(.secondary)
        }
    }

    private func content(_ s: SessionRecord) -> some View {
        let baseline = baselines.baseline(settings.values.activeBaselineID)
        let stats = SessionStats.compute(s.reps, baseline: baseline, target: settings.values.activeTarget)

        return List {
            Section("Summary") {
                row("Started", s.startedAt.formatted(date: .abbreviated, time: .shortened))
                row("Swings", "\(s.reps.count) detected · \(stats.scoredCount) scored")
                if let m = stats.medianTempo { row("Median tempo", String(format: "%.2f : 1", m)) }
                if let iqr = stats.tempoIQR { row("Tempo spread (IQR)", String(format: "%.2f", iqr)) }
                if let b = stats.medianBackswing { row("Median backswing", String(format: "%.2f s", b)) }
                if let d = stats.medianDownswing { row("Median downswing", String(format: "%.2f s", d)) }
                if let m = stats.medianShapeMatch { row("Baseline match", String(format: "%.0f%%", m)) }
                if s.isIncomplete { row("Ended", "Early: \(s.endReason.rawValue)") }
            }

            Section {
                ForEach(stats.feedback(target: settings.values.activeTarget), id: \.self) { line in
                    Text(line)
                }
            } header: {
                Text("Feedback")
            } footer: {
                Text("Metrics describe your handheld shadow swing, not club or ball performance.")
            }

            Section {
                if s.reps.isEmpty {
                    Text("No swings detected").foregroundStyle(.secondary)
                }
                ForEach(Array(s.reps.enumerated()), id: \.element.id) { index, rep in
                    NavigationLink(value: SwingRef(session: s.id, rep: rep.id)) {
                        RepRow(number: index + 1, rep: rep, baseline: baseline)
                    }
                    .swipeActions(edge: .leading) {
                        Button { setReview(.confirmed, for: rep.id, in: s) } label: { Label("Real swing", systemImage: "checkmark") }
                            .tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        Button { setReview(.rejected, for: rep.id, in: s) } label: { Label("Not a swing", systemImage: "xmark") }
                            .tint(.red)
                    }
                }
            } header: {
                Text("Swings")
            } footer: {
                Text("Swipe right if it was a real swing, left if it wasn't, or tap a swing to see its phases.")
            }

            if let setup = s.setup {
                Section("Setup") {
                    row("Earbud", setup.mount == .glove ? "In glove" : "Handheld")
                    row("Club", setup.club.isEmpty ? "—" : setup.club)
                    if !setup.note.isEmpty { row("Note", setup.note) }
                    row("Marks", "\(s.events.filter { $0.text.hasPrefix("mark ") }.count)")
                }
            }

            Section("Data quality") {
                row("Length", String(format: "%.1f s", s.quality.duration))
                row("Sample rate", String(format: "%.1f Hz", s.quality.effectiveHz))
                row("Gaps over 100 ms", "\(s.quality.gapCount)")
                row("Est. missing", String(format: "%.1f%%", s.quality.estimatedDropout * 100))
                row("Meets targets", s.quality.meetsTargets ? "Yes" : "No")
            }

            if let c = s.calibration {
                Section("Calibration") {
                    row("Address set at", String(format: "%.1f s", c.completedAt))
                    row("Rest noise", String(format: "%.3f rad/s", c.restNoise))
                    row("Practice swing", c.practiceRep.map { String(format: "%.2f s", $0.duration) } ?? "Skipped")
                    if let axis = c.downswingAxis, let sign = c.downswingSign {
                        row("Swing axis", "\(sign > 0 ? "+" : "−")\(["x", "y", "z"][axis])")
                    }
                }
            }

            Section("Export") {
                ShareLink(items: store.exportURLs(for: s.id)) {
                    Label("Share session files", systemImage: "square.and.arrow.up")
                }
            }

            Section {
                DisclosureGroup("Event log (\(s.events.count))") {
                    ForEach(Array(s.events.enumerated()), id: \.offset) { _, e in
                        Text(String(format: "%7.2f s  ", e.t) + e.text)
                            .font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle(s.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Rename") {
                newName = s.name
                renaming = true
            }
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                var updated = s
                updated.name = newName.trimmingCharacters(in: .whitespaces).isEmpty ? s.name : newName
                try? store.update(updated)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Sessions recorded before tempo analysis existed get analyzed the first time they're opened.
    private func analyzeIfNeeded(_ s: SessionRecord) {
        guard s.reps.contains(where: { $0.analysis == nil }),
              let samples = try? store.loadSamples(for: s.id) else { return }
        var updated = s
        updated.reps = s.reps.map { rep in
            rep.analysis == nil
                ? SwingAnalyzer.analyzed(rep, samples: samples, calibration: s.calibration, settings: s.settings)
                : rep
        }
        try? store.update(updated)
    }

    private func setReview(_ review: Rep.Review, for repID: UUID, in session: SessionRecord) {
        var updated = session
        guard let index = updated.reps.firstIndex(where: { $0.id == repID }) else { return }
        updated.reps[index].review = updated.reps[index].review == review ? .unreviewed : review
        try? store.update(updated)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct RepRow: View {
    let number: Int
    let rep: Rep
    let baseline: Baseline?

    var body: some View {
        HStack {
            reviewIcon
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Swing \(number)")
                    Spacer()
                    if let tempo = rep.tempoRatio {
                        Text(String(format: "%.1f : 1", tempo)).monospacedDigit().bold()
                    } else {
                        Text("Unclear").foregroundStyle(.secondary)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if rep.possiblyClipped {
                    Text("Possibly cut off").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let p = rep.effectivePhases {
            parts.append(String(format: "back %.2f s · down %.2f s", p.backswing, p.downswing))
        } else {
            parts.append(String(format: "%.2f s long", rep.duration))
        }
        if rep.manualPhases != nil {
            parts.append("adjusted")
        } else if let c = rep.analysis?.confidence, c != .high {
            parts.append("\(c.rawValue) confidence")
        }
        if let baseline, let c = Comparison.make(rep, to: baseline) {
            parts.append(String(format: "%.0f%% match", c.shapeMatch))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var reviewIcon: some View {
        switch rep.review {
        case .confirmed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .rejected: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .unreviewed: Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

struct TrendsView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var baselines: BaselineStore
    @ObservedObject var settings: AppSettings

    private struct Point: Identifiable {
        var id: UUID
        var date: Date
        var name: String
        var stats: SessionStats
    }

    private var points: [Point] {
        let baseline = baselines.baseline(settings.values.activeBaselineID)
        return store.sessions.reversed().map {
            Point(id: $0.id, date: $0.startedAt, name: $0.name,
                  stats: SessionStats.compute($0.reps, baseline: baseline, target: settings.values.activeTarget))
        }
    }

    var body: some View {
        let points = points
        List {
            Section("Median tempo") {
                Chart(points.filter { $0.stats.medianTempo != nil }) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Tempo", p.stats.medianTempo ?? 0))
                    PointMark(x: .value("Date", p.date), y: .value("Tempo", p.stats.medianTempo ?? 0))
                    if let target = settings.values.activeTarget {
                        RuleMark(y: .value("Target", target))
                            .foregroundStyle(.green.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .chartYAxisLabel("backswing : downswing")
                .frame(height: 200)
            }

            if points.contains(where: { $0.stats.medianShapeMatch != nil }) {
                Section("Baseline match") {
                    Chart(points.filter { $0.stats.medianShapeMatch != nil }) { p in
                        LineMark(x: .value("Date", p.date), y: .value("Match", p.stats.medianShapeMatch ?? 0))
                        PointMark(x: .value("Date", p.date), y: .value("Match", p.stats.medianShapeMatch ?? 0))
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxisLabel("% shape match")
                    .frame(height: 200)
                }
            }

            Section("Sessions") {
                ForEach(points.reversed()) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name)
                        Text(summary(p.stats)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Progress")
    }

    private func summary(_ s: SessionStats) -> String {
        var parts = ["\(s.scoredCount) scored"]
        if let m = s.medianTempo { parts.append(String(format: "median %.2f:1", m)) }
        if let iqr = s.tempoIQR { parts.append(String(format: "IQR %.2f", iqr)) }
        if let m = s.medianShapeMatch { parts.append(String(format: "%.0f%% match", m)) }
        return parts.joined(separator: " · ")
    }
}
