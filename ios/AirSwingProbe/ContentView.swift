import CoreMotion
import SwiftUI

struct ContentView: View {
    @ObservedObject var probe: MotionProbe

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                liveSection
                trialSection
                if let summary = probe.lastSummary { summarySection(summary) }
                recordingsSection
            }
            .navigationTitle("AirSwing Probe")
            .onAppear { probe.startStream() }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            // Some Core Motion state isn't observable, so redraw a few times a second.
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                VStack(spacing: 6) {
                    row("Motion available", probe.isAvailable ? "Yes" : "No")
                    row("Headphones connected", probe.isConnected ? "Yes" : "No")
                    row("Stream active", probe.isActive ? "Yes" : "No")
                    row("Motion permission", probe.authorizationText)
                    row("Live rate", probe.liveHz > 0 ? String(format: "%.1f Hz", probe.liveHz) : "—")
                    row("Last sample", sampleAge(at: context.date))
                }
            }
            if let error = probe.lastError {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
            Button(probe.isStreaming ? "Restart stream" : "Start stream") {
                probe.stopStream()
                probe.startStream()
            }
            .disabled(probe.isRecording)
        }
    }

    private var liveSection: some View {
        Section("Live sensor values") {
            if let m = probe.latest {
                let q = m.attitude.quaternion, r = m.rotationRate, a = m.userAcceleration
                row("Quaternion w x y z", fmt(q.w, q.x, q.y, q.z))
                row("Rotation rad/s", fmt(r.x, r.y, r.z))
                row("User accel g", fmt(a.x, a.y, a.z))
                row("Rotation speed", String(format: "%.2f rad/s", (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()))
            } else {
                Text("No samples yet. Connect AirPods and put one in your ear to start.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trialSection: some View {
        Section {
            Picker("Condition", selection: $probe.condition) {
                ForEach(TrialCondition.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(probe.isRecording)

            if probe.isRecording {
                row("Samples", "\(probe.recordedCount)")
                row("Gaps over \(Int(MotionProbe.gapThreshold * 1000)) ms", "\(probe.recordedGaps)")
            }

            Button(probe.isRecording ? "Stop and save" : "Start recording") {
                probe.isRecording ? probe.stopRecording() : probe.startRecording()
            }
            .font(.headline)
            .foregroundStyle(probe.isRecording ? .red : .accentColor)
        } header: {
            Text("Trial")
        } footer: {
            Text("Go target: 30+ seconds of usable data in three handheld trials in a row. Hold the earbud securely and move slowly.")
        }
    }

    private func summarySection(_ s: RecordingSummary) -> some View {
        Section("Last recording") {
            row("Samples", "\(s.sampleCount)")
            row("Duration", String(format: "%.1f s", s.duration))
            row("Effective rate", String(format: "%.1f Hz", s.effectiveHz))
            row("Gaps", "\(s.gapCount)")
            row("Longest interval", String(format: "%.0f ms", s.maxIntervalMs))
            if let file = s.file {
                ShareLink("Export CSV", item: file)
            }
        }
    }

    private var recordingsSection: some View {
        Section("Saved recordings") {
            if probe.savedFiles.isEmpty {
                Text("None yet").foregroundStyle(.secondary)
            }
            ForEach(probe.savedFiles, id: \.self) { url in
                ShareLink(item: url) {
                    Text(url.lastPathComponent).font(.footnote.monospaced())
                }
            }
            .onDelete { offsets in
                offsets.map { probe.savedFiles[$0] }.forEach(probe.delete)
            }
        }
    }

    private func sampleAge(at now: Date) -> String {
        guard let last = probe.lastSampleDate else { return "—" }
        let age = now.timeIntervalSince(last)
        return age < 1 ? String(format: "%.0f ms ago", age * 1000) : String(format: "%.1f s ago", age)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func fmt(_ values: Double...) -> String {
        values.map { String(format: "%+.2f", $0) }.joined(separator: " ")
    }
}
