import Charts
import SwiftUI

struct SwingDetailView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var baselines: BaselineStore
    @ObservedObject var settings: AppSettings
    let ref: SwingRef

    @State private var samples: [Sample] = []
    @State private var loadError: String?
    @State private var draft: SwingPhases?
    @State private var namingBaseline = false
    @State private var baselineName = ""

    var body: some View {
        if let session = store.sessions.first(where: { $0.id == ref.session }),
           let index = session.reps.firstIndex(where: { $0.id == ref.rep }) {
            content(session, index)
                .task(id: ref) { load() }
        } else {
            Text("Swing not found").foregroundStyle(.secondary)
        }
    }

    private func content(_ session: SessionRecord, _ index: Int) -> some View {
        let rep = session.reps[index]
        let axis = rep.analysis.map { (axis: $0.axis, sign: $0.sign) } ?? SwingAnalyzer.knownAxis(session.calibration)
        let shownPhases = draft ?? rep.effectivePhases ?? rep.analysis?.phases
        let baseline = baselines.baseline(settings.values.activeBaselineID)

        return List {
            Section {
                if samples.isEmpty {
                    Text(loadError ?? "Loading motion…").foregroundStyle(.secondary)
                } else {
                    PhaseChart(samples: chartWindow(rep, shownPhases), axis: axis, phases: shownPhases)
                        .frame(height: 240)
                }
            } footer: {
                Text("Blue: rotation on the swing axis (backswing negative, downswing positive). Grey: total rotation speed.")
            }

            if let phases = shownPhases, !samples.isEmpty,
               let arc = SwingArc.make(SwingAnalyzer.window(samples, from: phases.start, to: max(rep.end, phases.downswingEnd)),
                                       phases: phases) {
                Section {
                    SwingArcView(arc: arc)
                        .frame(maxWidth: 260)
                        .frame(maxWidth: .infinity)
                    row("Backswing turn", String(format: "%.0f°", arc.backswingDegrees))
                } header: {
                    Text("Swing arc")
                } footer: {
                    Text("Where the club pointed through the swing, seen face-on, from the hand's rotation: grey backswing, coloured downswing to impact, faint follow-through. It shows the swing's shape and length, not a measured club path.")
                }
            }

            Section("Tempo") {
                if let p = draft ?? rep.effectivePhases {
                    row("Tempo", String(format: "%.2f : 1", p.tempoRatio))
                    row("Backswing", String(format: "%.2f s", p.backswing))
                    row("Downswing", String(format: "%.2f s", p.downswing))
                } else {
                    Text("Tempo unclear for this swing.").foregroundStyle(.secondary)
                }
                row("Confidence", rep.manualPhases != nil ? "Adjusted by you" : (rep.analysis?.confidence.rawValue.capitalized ?? "Not analyzed"))
                ForEach(rep.analysis?.issues ?? [], id: \.self) { issue in
                    Text(issue).font(.footnote).foregroundStyle(.orange)
                }
                row("Peak rotation", String(format: "%.1f rad/s", rep.peakSpeed))
            }

            adjustSection(session, index, rep, shownPhases)

            if let baseline {
                Section("Compared with \(baseline.name)") {
                    if let c = Comparison.make(rep, to: baseline), let signature = rep.signature {
                        row("Shape match", String(format: "%.0f%%", c.shapeMatch))
                        row("Speed", String(format: "%.0f%% of baseline", c.speedRatio * 100))
                        row("Tempo difference", String(format: "%+.2f", c.tempoDifference))
                        ComparisonChart(swing: signature, baseline: baseline.signature)
                            .frame(height: 180)
                    } else {
                        Text("Needs clear phases on both swings to compare.").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Review") {
                Picker("This was", selection: Binding(
                    get: { rep.review },
                    set: { review in update(session) { $0.reps[index].review = review } }
                )) {
                    Text("Unreviewed").tag(Rep.Review.unreviewed)
                    Text("A real swing").tag(Rep.Review.confirmed)
                    Text("Not a swing").tag(Rep.Review.rejected)
                }
                Button("Use as my baseline") {
                    baselineName = "Baseline \(baselines.baselines.count + 1)"
                    namingBaseline = true
                }
                .disabled(rep.signature == nil || rep.tempoRatio == nil)
            }
        }
        .navigationTitle("Swing \(index + 1)")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Name this baseline", isPresented: $namingBaseline) {
            TextField("Name", text: $baselineName)
            Button("Save") { saveBaseline(session, rep) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Later swings are compared with this one. It becomes your active baseline.")
        }
    }

    @ViewBuilder
    private func adjustSection(_ session: SessionRecord, _ index: Int, _ rep: Rep, _ shown: SwingPhases?) -> some View {
        Section {
            if let d = draft {
                slider("Start", value: d.start, in: span(rep.start - 0.5, d.top - 0.05)) { draft?.start = $0 }
                slider("Top", value: d.top, in: span(d.start + 0.05, d.downswingEnd - 0.03)) { draft?.top = $0 }
                slider("Downswing end", value: d.downswingEnd, in: span(d.top + 0.03, rep.end + 0.5)) { draft?.downswingEnd = $0 }
                HStack {
                    Button("Save") {
                        update(session) { record in
                            record.reps[index].manualPhases = d
                            record.reps[index].signature = SwingAnalyzer.signature(for: record.reps[index], samples: samples)
                        }
                        draft = nil
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("Cancel", role: .cancel) { draft = nil }
                }
            } else {
                Button("Adjust phases") {
                    draft = shown ?? SwingPhases(start: rep.start, top: (rep.start + rep.peakTime) / 2, downswingEnd: rep.peakTime)
                }
                .disabled(samples.isEmpty)
                if rep.manualPhases != nil {
                    Button("Reset to automatic", role: .destructive) {
                        update(session) { record in
                            record.reps[index].manualPhases = nil
                            record.reps[index].signature = SwingAnalyzer.signature(for: record.reps[index], samples: samples)
                        }
                    }
                }
            }
        } header: {
            Text("Phases")
        } footer: {
            Text("Drag the markers if the automatic phases look wrong. Adjusted swings count as clear.")
        }
    }

    private func slider(_ label: String, value: Double, in range: ClosedRange<Double>,
                        set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.2f s", value)).monospacedDigit().foregroundStyle(.secondary)
            }
            if range.lowerBound < range.upperBound {
                Slider(value: Binding(get: { value }, set: set), in: range, step: 0.01)
            }
        }
    }

    /// A closed range that never crashes when the bounds cross while dragging.
    private func span(_ a: Double, _ b: Double) -> ClosedRange<Double> { a...max(a, b) }

    private func chartWindow(_ rep: Rep, _ phases: SwingPhases?) -> [Sample] {
        let from = min(rep.start, phases?.start ?? rep.start) - 0.4
        let to = max(rep.end, phases?.downswingEnd ?? rep.end) + 0.2
        return SwingAnalyzer.window(samples, from: from, to: to)
    }

    private func load() {
        guard samples.isEmpty else { return }
        do {
            samples = try store.loadSamples(for: ref.session)
        } catch {
            loadError = "Couldn't load motion data: \(error.localizedDescription)"
        }
    }

    private func update(_ session: SessionRecord, _ change: (inout SessionRecord) -> Void) {
        var updated = session
        change(&updated)
        try? store.update(updated)
    }

    private func saveBaseline(_ session: SessionRecord, _ rep: Rep) {
        guard let signature = rep.signature, let p = rep.effectivePhases else { return }
        let name = baselineName.trimmingCharacters(in: .whitespaces)
        let baseline = Baseline(
            name: name.isEmpty ? "Baseline" : name, signature: signature, tempoRatio: p.tempoRatio,
            backswing: p.backswing, downswing: p.downswing, peakSpeed: rep.peakSpeed,
            sessionID: session.id, repID: rep.id
        )
        baselines.add(baseline)
        settings.values.activeBaselineID = baseline.id
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct PhaseChart: View {
    let samples: [Sample]
    let axis: (axis: Int, sign: Int)?
    let phases: SwingPhases?

    private struct Point: Identifiable {
        var id: Int
        var t: Double
        var value: Double
        var series: String
    }

    private var points: [Point] {
        var out: [Point] = []
        for (i, s) in samples.enumerated() {
            out.append(Point(id: i * 2, t: s.t, value: s.speed, series: "Speed"))
            if let axis {
                out.append(Point(id: i * 2 + 1, t: s.t, value: Double(axis.sign) * s.rotation[axis.axis], series: "Swing axis"))
            }
        }
        return out
    }

    var body: some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time", p.t), y: .value("rad/s", p.value), series: .value("Series", p.series))
                    .foregroundStyle(by: .value("Series", p.series))
                    .lineStyle(StrokeStyle(lineWidth: p.series == "Speed" ? 1 : 2))
            }
            if let phases {
                marker(phases.start, "Start", .green)
                marker(phases.top, "Top", .orange)
                marker(phases.downswingEnd, "End", .purple)
            }
        }
        .chartForegroundStyleScale(["Swing axis": Color.blue, "Speed": Color.gray.opacity(0.5)])
        .chartXAxisLabel("seconds")
        .chartLegend(.hidden)
    }

    private func marker(_ t: Double, _ label: String, _ color: Color) -> some ChartContent {
        RuleMark(x: .value(label, t))
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .annotation(position: .top, alignment: .center) {
                Text(label).font(.caption2).foregroundStyle(color)
            }
    }
}

private struct ComparisonChart: View {
    let swing: [Double]
    let baseline: [Double]

    private struct Point: Identifiable {
        var id: Int
        var x: Int
        var value: Double
        var series: String
    }

    var body: some View {
        let points = swing.enumerated().map { Point(id: $0.offset, x: $0.offset, value: $0.element, series: "This swing") }
            + baseline.enumerated().map { Point(id: 1000 + $0.offset, x: $0.offset, value: $0.element, series: "Baseline") }
        Chart(points) { p in
            LineMark(x: .value("% of swing", p.x), y: .value("rad/s", p.value), series: .value("Series", p.series))
                .foregroundStyle(by: .value("Series", p.series))
            RuleMark(x: .value("Top", Signature.backswingPoints))
                .foregroundStyle(.orange.opacity(0.4))
        }
        .chartForegroundStyleScale(["This swing": Color.blue, "Baseline": Color.gray])
        .chartXAxis(.hidden)
    }
}
