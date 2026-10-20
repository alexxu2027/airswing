import SwiftUI

struct PracticeView: View {
    @ObservedObject var practice: PracticeSession
    @ObservedObject var motion: MotionSource

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch practice.phase {
                case .idle, .finished: startPanel
                case .holdingAddress: holdPanel
                case .practiceSwing, .practicing: swingPanel
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

            Toggle("Say \"Ready\" out loud", isOn: $practice.speakReady)

            Spacer()

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
            Spacer()
            stopButton
        }
    }

    private var swingPanel: some View {
        VStack(spacing: 20) {
            if practice.phase == .practiceSwing {
                stepHeader("Step 2 of 2", "One slow practice swing")
                Button("Skip practice swing") { practice.skipPracticeSwing() }
                    .font(.footnote)
            }

            Text(stateText)
                .font(.system(size: 44, weight: .heavy))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(stateColor, in: RoundedRectangle(cornerRadius: 20))
                .animation(.easeInOut(duration: 0.15), value: practice.detectorState)

            Text(practice.readyHint ?? " ")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            if practice.phase == .practicing {
                HStack {
                    stat("Swings", "\(practice.reps.count)")
                    stat("Last", practice.reps.last.map { String(format: "%.2f s", $0.duration) } ?? "—")
                    stat("Waggles", "\(practice.waggleCount)")
                }
                if practice.reps.last?.possiblyClipped == true {
                    Text("Last swing may have exceeded the sensor's range. Swing a little slower.")
                        .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }

            warningBanner
            Spacer()
            stopButton
        }
    }

    // MARK: Pieces

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
