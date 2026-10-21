import SwiftUI

struct PracticeView: View {
    @ObservedObject var practice: PracticeSession
    @ObservedObject var motion: MotionSource
    @ObservedObject var settings: AppSettings

    /// The setup for the next session, remembered between launches.
    private var setup: Binding<RecordingSetup> {
        Binding(get: { settings.values.setup ?? RecordingSetup() },
                set: { settings.values.setup = $0 })
    }

    private var inGlove: Bool { setup.wrappedValue.mount == .glove }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    switch practice.phase {
                    case .idle, .finished: startPanel
                    case .holdingAddress: holdPanel
                    case .practiceSwing, .practicing: swingPanel
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Practice")
        }
    }

    // MARK: Panels

    private var startPanel: some View {
        VStack(spacing: 20) {
            streamStatus

            if let saved = practice.lastSaved {
                VStack(spacing: 6) {
                    Text("Session saved").font(.headline)
                    Text("\(saved.reps.count) swings detected. Review them in Sessions.")
                        .foregroundStyle(.secondary)
                    if saved.isIncomplete {
                        Text("Ended early: \(saved.endReason.rawValue)").foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 8) {
                if inGlove {
                    Label("Fix one earbud in the glove, in the same spot every time. Put the other in its case.", systemImage: "hand.raised")
                    Label("Clear space around you before swinging a club.", systemImage: "exclamationmark.triangle")
                    Label("Spoken cues play in the gloved earbud, so watch the phone screen.", systemImage: "iphone")
                } else {
                    Label("Hold one earbud firmly. Put the other in its case.", systemImage: "hand.raised")
                    Label("Slow to moderate swings only, with clear space around you.", systemImage: "exclamationmark.triangle")
                    Label("Stand the phone where you can see and hear it.", systemImage: "iphone")
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                Picker("Earbud", selection: setup.mount) {
                    Text("Handheld").tag(RecordingSetup.Mount.handheld)
                    Text("In glove").tag(RecordingSetup.Mount.glove)
                }
                .pickerStyle(.segmented)
                TextField("Club (e.g. 7 iron)", text: setup.club)
                    .textFieldStyle(.roundedBorder)
                TextField("Note (e.g. full swings, hitting balls)", text: setup.note)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(spacing: 12) {
                Toggle("Tempo drill", isOn: $settings.values.tempoTargetEnabled)
                if settings.values.tempoTargetEnabled {
                    Stepper(String(format: "Target %.1f : 1", settings.values.tempoTarget),
                            value: $settings.values.tempoTarget, in: 1.5...4.0, step: 0.1)
                    Text("A target you choose for practice, not a universal ideal.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Text("Baseline")
                    Spacer()
                    Text(practice.baseline?.name ?? "None").foregroundStyle(.secondary)
                }
            }

            Button {
                practice.start()
            } label: {
                Text("Start session").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var holdPanel: some View {
        VStack(spacing: 20) {
            stepHeader("Step 1 of 2", "Set your address")
            Text(inGlove ? "Take your address with the club and keep still."
                         : "Hold the earbud the way you'd grip a club at address, and keep still.")
                .multilineTextAlignment(.center)
            ProgressView(value: practice.holdProgress)
                .scaleEffect(y: 3)
                .padding(.vertical)
            Text(practice.holdIsStill ? "Hold still…" : "Settle at address")
                .font(.title2.bold())
                .foregroundStyle(practice.holdIsStill ? .green : .secondary)
            warningBanner
            stopButton
        }
    }

    private var swingPanel: some View {
        VStack(spacing: 20) {
            if practice.phase == .practiceSwing {
                stepHeader("Step 2 of 2", "One slow practice swing")
                Text("This teaches AirSwing which way your swing turns.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Skip practice swing") { practice.skipPracticeSwing() }
                    .font(.footnote)
            }

            statusBar

            if practice.phase == .practicing {
                lastSwing
                if !practice.reps.isEmpty { sessionStrip }
            }

            warningBanner
            HStack(spacing: 12) {
                Button {
                    practice.mark()
                } label: {
                    Label(practice.markCount > 0 ? "Mark · \(practice.markCount)" : "Mark", systemImage: "flag.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                stopButton
            }
        }
    }

    /// Readable from a few steps away, with the phone on the ground.
    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(stateText).font(.system(size: 30, weight: .heavy, design: .rounded))
            Spacer(minLength: 8)
            if let hint = practice.readyHint {
                Text(hint).font(.subheadline.weight(.semibold)).multilineTextAlignment(.trailing)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(stateColor, in: RoundedRectangle(cornerRadius: 20))
        .animation(.easeInOut(duration: 0.15), value: practice.detectorState)
    }

    @ViewBuilder private var lastSwing: some View {
        if let rep = practice.reps.last {
            let phases = rep.effectivePhases
            VStack(spacing: 18) {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(phases.map { String(format: "%.1f", $0.tempoRatio) } ?? "—")
                            .font(.system(size: 96, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(phases.map { tempoColor($0.tempoRatio) } ?? .secondary)
                        if phases != nil {
                            Text(": 1").font(.system(size: 32, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
                    Text(phases == nil ? (rep.analysis?.issues.first ?? "Tempo unclear")
                                       : settings.values.activeTarget.map { String(format: "TEMPO · TARGET %.1f : 1", $0) } ?? "TEMPO")
                        .font(phases == nil ? Font.footnote : Font.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let phases {
                    HStack {
                        metric("Back", String(format: "%.2f s", phases.backswing))
                        metric("Down", String(format: "%.2f s", phases.downswing))
                        metric("Turn", practice.lastArc.map { String(format: "%.0f°", $0.backswingDegrees) } ?? "—")
                    }
                }

                if let arc = practice.lastArc {
                    SwingArcView(arc: arc).frame(maxWidth: 280)
                }

                if let baseline = practice.baseline, let c = Comparison.make(rep, to: baseline) {
                    Text(String(format: "%.0f%% shape match to ", c.shapeMatch) + baseline.name)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if rep.possiblyClipped {
                    Text(inGlove ? "Peak rotation went past the sensor's range."
                                 : "This swing may have exceeded the sensor's range. Swing a little slower.")
                        .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }
        } else {
            Text("Your tempo appears here after each swing.")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.vertical, 40)
        }
    }

    private var sessionStrip: some View {
        VStack(spacing: 6) {
            TempoStrip(tempos: practice.reps.map(\.tempoRatio), target: settings.values.activeTarget)
            HStack {
                Text(practice.reps.count == 1 ? "1 swing" : "\(practice.reps.count) swings")
                Spacer()
                Text(practice.stats.medianTempo.map { String(format: "Median %.1f : 1", $0) } ?? "Median —")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    private func tempoColor(_ tempo: Double) -> Color {
        guard let target = settings.values.activeTarget else { return .primary }
        return abs(tempo - target) <= target * SessionStats.targetTolerance ? .green : .orange
    }

    private var stateText: String {
        switch practice.detectorState {
        case .notReady: return "Get set"
        case .settling: return "Hold still…"
        case .ready: return "READY"
        case .swinging: return "Swing"
        case .finishing: return "Hold finish"
        }
    }

    private var stateColor: Color {
        switch practice.detectorState {
        case .notReady: return .gray
        case .settling: return .orange
        case .ready: return .green
        case .swinging, .finishing: return .blue
        }
    }

    private var streamStatus: some View {
        HStack {
            Circle()
                .fill(motion.isConnected && motion.liveHz > 0 ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(motion.isConnected
                 ? (motion.liveHz > 0 ? String(format: "AirPods streaming at %.0f Hz", motion.liveHz) : "AirPods connected, no motion yet")
                 : "AirPods not connected")
                .font(.subheadline)
            Spacer()
        }
    }

    @ViewBuilder private var warningBanner: some View {
        if let warning = practice.warning {
            Text(warning)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.red, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var stopButton: some View {
        Button(role: .destructive) {
            practice.stop()
        } label: {
            Text("Stop & save").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    private func stepHeader(_ step: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Text(step).font(.caption).foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label.uppercased()).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
