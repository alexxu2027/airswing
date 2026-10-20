import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var baselines: BaselineStore
    @ObservedObject var store: SessionStore
    @ObservedObject var motion: MotionSource
    @Binding var showSetup: Bool

    @State private var confirmingDeleteAll = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Voice cues") {
                    Toggle("Say \"Ready\"", isOn: $settings.values.speakReady)
                    Toggle("Say tempo after each swing", isOn: $settings.values.speakTempo)
                }

                Section {
                    Toggle("Tempo drill", isOn: $settings.values.tempoTargetEnabled)
                    if settings.values.tempoTargetEnabled {
                        Stepper(String(format: "Target %.1f : 1", settings.values.tempoTarget),
                                value: $settings.values.tempoTarget, in: 1.5...4.0, step: 0.1)
                    }
                } header: {
                    Text("Tempo target")
                } footer: {
                    Text("An optional target you choose. Swings within 10% count as on target.")
                }

                Section {
                    Picker("Active baseline", selection: $settings.values.activeBaselineID) {
                        Text("None").tag(UUID?.none)
                        ForEach(baselines.baselines) { b in
                            Text(b.name).tag(UUID?.some(b.id))
                        }
                    }
                    ForEach(baselines.baselines) { b in
                        VStack(alignment: .leading) {
                            Text(b.name)
                            Text(String(format: "%.2f:1 · saved ", b.tempoRatio) + b.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        for id in offsets.map({ baselines.baselines[$0].id }) {
                            if settings.values.activeBaselineID == id { settings.values.activeBaselineID = nil }
                            baselines.delete(id)
                        }
                    }
                } header: {
                    Text("Baselines")
                } footer: {
                    Text("Save a baseline from any swing's detail screen. Swings are compared with your own reference, not a pro standard.")
                }

                Section {
                    DetectionSettingsEditor(detection: $settings.values.detection)
                    Button("Reset to defaults") { settings.values.detection = DetectionSettings() }
                } header: {
                    Text("Swing detection")
                } footer: {
                    Text("Changes apply to the next session. Saved sessions keep the settings they were recorded with.")
                }

                Section("Help") {
                    Button("Show setup again") { showSetup = true }
                    NavigationLink("Diagnostics") { DiagnosticsView(motion: motion) }
                    NavigationLink("Limitations and privacy") { AboutView() }
                }

                Section {
                    Button("Delete all sessions", role: .destructive) { confirmingDeleteAll = true }
                        .disabled(store.sessions.isEmpty)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete all \(store.sessions.count) sessions?", isPresented: $confirmingDeleteAll,
                                titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { store.deleteAll() }
            } message: {
                Text("This can't be undone. Export anything you want to keep first.")
            }
        }
    }
}

private struct DetectionSettingsEditor: View {
    @Binding var detection: DetectionSettings

    var body: some View {
        Group {
            row("Still below", $detection.stillSpeed, 0.2...1.0, 0.05, "%.2f rad/s")
            row("Ready after holding", $detection.readyHold, 0.3...2.0, 0.1, "%.1f s")
            row("Address tolerance", $detection.addressToleranceDegrees, 10...60, 5, "%.0f°")
            row("Swing starts at", $detection.swingStartSpeed, 0.5...3.0, 0.1, "%.1f rad/s")
            row("Waggle if peak below", $detection.minPeakSpeed, 2...10, 0.5, "%.1f rad/s")
            row("Finish hold", $detection.finishHold, 0.2...1.5, 0.1, "%.1f s")
        }
    }

    private func row(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                     _ step: Double, _ format: String) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section("What AirSwing measures") {
                Text("The timing and rotation of a handheld AirPod during a club-free shadow swing: backswing and downswing durations, tempo ratio, and how similar a swing is to your own saved baseline.")
            }
            Section("What it doesn't measure") {
                Text("Clubhead speed, swing plane, clubface angle, ball flight, or hand position in space. Phases are approximate motion phases of a handheld gesture, not validated club phases. AirSwing gives no coaching, medical or injury-prevention advice.")
            }
            Section("Safety") {
                Text("Hold the earbud securely in a closed hand and keep swings slow to moderate, indoors, away from people and fragile objects. Never throw the earbud or swing at full force. A dropped earbud can be damaged or lost.")
            }
            Section("Privacy") {
                Text("Motion data stays on this iPhone. Nothing is uploaded and there are no accounts. Data leaves the phone only when you share it. AirSwing doesn't use the microphone or heart-rate data.")
            }
        }
        .navigationTitle("Limitations and privacy")
    }
}

struct OnboardingView: View {
    @ObservedObject var motion: MotionSource
    let finish: () -> Void

    @State private var page = 0

    var body: some View {
        VStack {
            TabView(selection: $page) {
                welcome.tag(0)
                safety.tag(1)
                airpods.tag(2)
                check.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < 3 {
                    withAnimation { page += 1 }
                } else {
                    finish()
                }
            } label: {
                Text(page < 3 ? "Next" : "Start practising").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .onChange(of: page) { _, newPage in
            // Starting motion updates is what asks for motion permission.
            if newPage == 3 { motion.start() }
        }
    }

    private var welcome: some View {
        infoPage("figure.golf", "AirSwing",
             "Practise your swing tempo without a club. Hold one AirPod like a grip, make slow shadow swings, and AirSwing times your backswing and downswing.",
             "It measures the rhythm of a handheld gesture, not club or ball performance.")
    }

    private var safety: some View {
        infoPage("exclamationmark.shield", "Swing safely",
             "Hold the earbud firmly in a closed hand. Keep swings slow to moderate, indoors, with clear space around you.",
             "Never throw the earbud or swing at full force.")
    }

    private var airpods: some View {
        VStack(spacing: 18) {
            Image(systemName: "airpodspro").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Set up your AirPods").font(.title.bold())
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Open Settings and tap your AirPods near the top.")
                step(2, "Turn off Automatic Ear Detection. Otherwise motion stops when the earbud leaves your ear.")
                step(3, "Hold one earbud and keep the other closed in its case.")
            }
            Text("With ear detection off, audio won't pause when you take an earbud out. Turn it back on after practice if you like.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
    }

    private var check: some View {
        VStack(spacing: 18) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Check the signal").font(.title.bold())
            Text("Allow motion access if asked. Then take the earbud out of your ear and turn it slowly in your hand.")
                .multilineTextAlignment(.center)
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let fresh = motion.lastSampleDate.map { context.date.timeIntervalSince($0) < 0.5 } ?? false
                Label(fresh ? String(format: "Receiving motion at %.0f Hz", motion.liveHz) : "Waiting for motion…",
                      systemImage: fresh ? "checkmark.circle.fill" : "hourglass")
                    .font(.headline)
                    .foregroundStyle(fresh ? .green : .secondary)
            }
            Text("Permission: \(motion.authorizationText)").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(28)
    }

    private func infoPage(_ icon: String, _ title: String, _ body: String, _ note: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 56)).foregroundStyle(.tint)
            Text(title).font(.title.bold())
            Text(body).multilineTextAlignment(.center)
            Text(note).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 26, height: 26).background(.tint.opacity(0.15), in: Circle())
            Text(text)
        }
    }
}
