import SwiftUI

@main
struct BlikvangerApp: App {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some Scene {
        WindowGroup {
            RootView(hasSeenOnboarding: $hasSeenOnboarding)
        }
    }
}
