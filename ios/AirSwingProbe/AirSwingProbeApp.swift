import SwiftUI

@main
struct AirSwingProbeApp: App {
    @StateObject private var probe = MotionProbe()

    var body: some Scene {
        WindowGroup {
            ContentView(probe: probe)
        }
    }
}
