import SwiftUI

@main
struct AirSwingApp: App {
    @StateObject private var motion: MotionSource
    @StateObject private var store: SessionStore
    @StateObject private var practice: PracticeSession
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let motion = MotionSource()
        let store = SessionStore()
        _motion = StateObject(wrappedValue: motion)
        _store = StateObject(wrappedValue: store)
        _practice = StateObject(wrappedValue: PracticeSession(motion: motion, store: store))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                PracticeView(practice: practice, motion: motion)
                    .tabItem { Label("Practice", systemImage: "figure.golf") }
                SessionsView(store: store)
                    .tabItem { Label("Sessions", systemImage: "list.bullet.rectangle") }
                DiagnosticsView(motion: motion)
                    .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
            }
            .onAppear { motion.start() }
            .onChange(of: scenePhase) { _, phase in
                // Motion stops in the background, so end and save the session cleanly.
                if phase == .background { practice.stop(reason: .backgrounded) }
            }
        }
    }
}
