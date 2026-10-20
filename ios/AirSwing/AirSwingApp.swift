import SwiftUI

@main
struct AirSwingApp: App {
    @StateObject private var motion: MotionSource
    @StateObject private var store: SessionStore
    @StateObject private var settings: AppSettings
    @StateObject private var baselines: BaselineStore
    @StateObject private var practice: PracticeSession
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("setupComplete") private var setupComplete = false
    @State private var showSetup = false

    init() {
        let motion = MotionSource()
        let store = SessionStore()
        let settings = AppSettings()
        let baselines = BaselineStore()
        _motion = StateObject(wrappedValue: motion)
        _store = StateObject(wrappedValue: store)
        _settings = StateObject(wrappedValue: settings)
        _baselines = StateObject(wrappedValue: baselines)
        _practice = StateObject(wrappedValue: PracticeSession(motion: motion, store: store,
                                                              settings: settings, baselines: baselines))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                PracticeView(practice: practice, motion: motion, settings: settings)
                    .tabItem { Label("Practice", systemImage: "figure.golf") }
                SessionsView(store: store, baselines: baselines, settings: settings)
                    .tabItem { Label("Sessions", systemImage: "list.bullet.rectangle") }
                SettingsView(settings: settings, baselines: baselines, store: store, motion: motion, showSetup: $showSetup)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .onAppear {
                // Motion starts once setup has explained why AirSwing asks for motion access.
                if setupComplete { motion.start() } else { showSetup = true }
            }
            .fullScreenCover(isPresented: $showSetup) {
                OnboardingView(motion: motion) {
                    setupComplete = true
                    showSetup = false
                    motion.start()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // Motion stops in the background, so end and save the session cleanly.
                if phase == .background { practice.stop(reason: .backgrounded) }
            }
        }
    }
}
