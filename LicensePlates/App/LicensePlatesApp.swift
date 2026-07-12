import SwiftUI

@main
struct LicensePlatesApp: App {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some Scene {
        WindowGroup {
            RootView(hasSeenOnboarding: $hasSeenOnboarding)
        }
    }
}
