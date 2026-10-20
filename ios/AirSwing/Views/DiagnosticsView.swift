import SwiftUI

/// The M0 probe's live status screen, kept for troubleshooting.
struct DiagnosticsView: View {
    @ObservedObject var motion: MotionSource

    var body: some View {
        Form {
            Section("Status") {
                // Some Core Motion state isn't observable, so redraw a few times a second.
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    VStack(spacing: 6) {
                        row("Motion available", motion.isAvailable ? "Yes" : "No")
                        row("Headphones connected", motion.isConnected ? "Yes" : "No")
                        row("Stream active", motion.isActive ? "Yes" : "No")
                        row("Motion permission", motion.authorizationText)
                        row("Live rate", motion.liveHz > 0 ? String(format: "%.1f Hz", motion.liveHz) : "—")
                        row("Last sample", sampleAge(at: context.date))
                    }
                }
                if let error = motion.lastError {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
                Button("Restart stream") { motion.restart() }
            }

            Section("Live sensor values") {
                if let s = motion.latest {
                    row("Quaternion w x y z", fmt(s.q.w, s.q.x, s.q.y, s.q.z))
                    row("Rotation rad/s", fmt(s.rx, s.ry, s.rz))
                    row("User accel g", fmt(s.ax, s.ay, s.az))
                    row("Rotation speed", String(format: "%.2f rad/s", s.speed))
                    row("Earbud", s.sensor)
                } else {
                    Text("No samples yet. Connect AirPods and put one in your ear to start.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Diagnostics")
    }

    private func sampleAge(at now: Date) -> String {
        guard let last = motion.lastSampleDate else { return "—" }
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
