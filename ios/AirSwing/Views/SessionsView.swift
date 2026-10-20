import SwiftUI

struct SessionsView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        NavigationStack {
            List {
                if store.sessions.isEmpty {
                    Text("No sessions yet").foregroundStyle(.secondary)
                }
                ForEach(store.sessions) { session in
                    NavigationLink(value: session.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name)
                            Text("\(session.reps.count) swings · \(session.confirmedCount) confirmed")
                                .font(.caption).foregroundStyle(.secondary)
                            if session.isIncomplete {
                                Text("Ended early: \(session.endReason.rawValue)")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { store.sessions[$0].id }.forEach(store.delete)
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(store: store, id: id)
            }
        }
    }
}

struct SessionDetailView: View {
    @ObservedObject var store: SessionStore
    let id: UUID

    var body: some View {
        if let session = store.sessions.first(where: { $0.id == id }) {
            content(session)
        } else {
            Text("Session deleted").foregroundStyle(.secondary)
        }
    }

    private func content(_ s: SessionRecord) -> some View {
        List {
            Section("Summary") {
                row("Started", s.startedAt.formatted(date: .abbreviated, time: .standard))
                row("Length", String(format: "%.1f s", s.quality.duration))
                row("Swings", "\(s.reps.count) detected, \(s.confirmedCount) confirmed")
                row("Ended", s.endReason == .stopped ? "Stopped" : "Early: \(s.endReason.rawValue)")
            }

            Section {
                if s.reps.isEmpty {
                    Text("No swings detected").foregroundStyle(.secondary)
                }
                ForEach(Array(s.reps.enumerated()), id: \.element.id) { index, rep in
                    RepRow(number: index + 1, rep: rep) { review in
                        setReview(review, for: rep.id, in: s)
                    }
                }
            } header: {
                Text("Swings")
            } footer: {
                Text("Tap ✓ if it was a real swing and ✗ if it wasn't. These reviews become the answer key for tempo detection.")
            }

            Section("Data quality") {
                row("Sample rate", String(format: "%.1f Hz", s.quality.effectiveHz))
                row("Gaps over 100 ms", "\(s.quality.gapCount)")
                row("Est. missing", String(format: "%.1f%%", s.quality.estimatedDropout * 100))
                row("Longest interval", String(format: "%.0f ms", s.quality.maxInterval * 1000))
                row("Meets targets", s.quality.meetsTargets ? "Yes" : "No")
            }

            if let c = s.calibration {
                Section("Calibration") {
                    row("Address set at", String(format: "%.1f s", c.completedAt))
                    row("Rest noise", String(format: "%.3f rad/s", c.restNoise))
                    row("Practice swing", c.practiceRep.map { String(format: "%.2f s", $0.duration) } ?? "Skipped")
                    if let axis = c.downswingAxis, let sign = c.downswingSign {
                        row("Downswing axis", "\(sign > 0 ? "+" : "−")\(["x", "y", "z"][axis])")
                    }
                }
            }

            Section("Export") {
                ShareLink(items: [store.metadataURL(for: s.id), store.samplesURL(for: s.id)]) {
                    Label("Share session files", systemImage: "square.and.arrow.up")
                }
            }

            Section("Events") {
                ForEach(Array(s.events.enumerated()), id: \.offset) { _, e in
                    Text(String(format: "%7.2f s  ", e.t) + e.text)
                        .font(.caption.monospaced())
                }
            }
        }
        .navigationTitle(s.name)
        .navigationBarTitleDisplayMode(.inline)
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
    let setReview: (Rep.Review) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Swing \(number)")
                Text(String(format: "at %.1f s · %.2f s long · peak %.1f rad/s", rep.start, rep.duration, rep.peakSpeed))
                    .font(.caption).foregroundStyle(.secondary)
                if rep.possiblyClipped {
                    Text("Possibly cut off").font(.caption).foregroundStyle(.orange)
                }
                if rep.timedOut {
                    Text("Timed out").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button { setReview(.confirmed) } label: {
                Image(systemName: rep.review == .confirmed ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.title2).foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            Button { setReview(.rejected) } label: {
                Image(systemName: rep.review == .rejected ? "xmark.circle.fill" : "xmark.circle")
                    .font(.title2).foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
    }
}
