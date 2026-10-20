import SwiftUI

struct PracticeView: View {
    @ObservedObject var practice: PracticeSession
    @ObservedObject var motion: MotionSource
    @ObservedObject var settings: AppSettings

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
                Label("Hold one earbud firmly. Put the other in its case.", systemImage: "hand.raised")
                Label("Slow to moderate swings only, with clear space around you.", systemImage: "exclamationmark.triangle")
                Label("Stand the phone where you can see and hear it.", systemImage: "iphone")
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)

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
            Text("Hold the earbud the way you'd grip a club at address, and keep still.")
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
        VStack(spacing: 16) {
            if practice.phase == .practiceSwing {
                stepHeader("Step 2 of 2", "One slow practice swing")
                Text("This teaches AirSwing which way your swing turns.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Skip practice swing") { practice.skipPracticeSwing() }
                    .font(.footnote)
            }

            Text(stateText)
                .font(.system(size: 44, weight: .heavy))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(stateColor, in: RoundedRectangle(cornerRadius: 20))
                .animation(.easeInOut(duration: 0.15), value: practice.detectorState)

            Text(practice.readyHint ?? " ")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            if practice.phase == .practicing {
                lastSwingCard
                HStack {
                    stat("Swings", "\(practice.reps.count)")
                    stat("Median", practice.stats.medianTempo.map { String(format: "%.1f:1", $0) } ?? "—")
                    stat("Waggles", "\(practice.waggleCount)")
                }
            }

            warningBanner
            stopButton
        }
    }

    @ViewBuilder private var lastSwingCard: some View {
        if let rep = practice.reps.last {
            VStack(spacing: 6) {
                if let p = rep.effectivePhases {
                    Text(String(format: "%.1f : 1", p.tempoRatio))
                        .font(.system(size: 40, weight: .bold).monospacedDigit())
                        .foregroundStyle(tempoColor(p.tempoRatio))
                    Text(String(format: "Back %.2f s · Down %.2f s", p.backswing, p.downswing))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let target = settings.values.activeTarget {
                        Text(String(format: "Target %.1f : 1", target)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let baseline = practice.baseline, let c = Comparison.make(rep, to: baseline) {
                        Text(String(format: "%.0f%% shape match to ", c.shapeMatch) + baseline.name)
                            .font(.subheadline)
                    }
                } else {
                    Text("Tempo unclear").font(.title2.bold())
                    Text(rep.analysis?.issues.first ?? "Phases couldn't be found reliably.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if rep.possiblyClipped {
                    Text("This swing may have exceeded the sensor's range. Swing a little slower.")
                        .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
            Text("Stop and save").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .padding(.top, 8)
    }

    private func stepHeader(_ step: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Text(step).font(.caption).foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
