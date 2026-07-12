import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Camera and AR") {
                    Text("Camera images, depth, and mesh data are processed in memory on this iPhone. Parked does not save or upload camera images, location, or AR session history.")
                }

                Section("RDW vehicle lookup") {
                    Text("After a Dutch plate is confirmed across multiple frames, Parked sends only its six-character plate text over HTTPS to the public RDW Open Data service. The response contains public vehicle details; Parked never requests owner data.")
                    if let rdwURL = URL(string: "https://opendata.rdw.nl/") {
                        Link("Open Data RDW", destination: rdwURL)
                    }
                    if let rdwPrivacyURL = URL(string: "https://www.rdw.nl/over-rdw/privacy-en-security/privacyverklaring") {
                        Link("RDW privacy statement", destination: rdwPrivacyURL)
                    }
                }

                Section("Storage and tracking") {
                    Text("Vehicle labels and lookup results last only for the current app session. One on-device preference remembers whether onboarding was completed. Parked contains no advertising, analytics, cross-app tracking, or third-party SDKs.")
                }

                Section("Your control and deletion") {
                    Text("On first use, scanning starts after you choose Start scanning and allow camera access. On later launches, the camera starts when Parked opens while permission remains granted. You can withdraw camera permission in Settings at any time. Reset removes every vehicle label, lookup result, and temporary RDW cache. Force-quitting or process termination discards the AR session. Deleting the app also removes the onboarding preference. Parked has no accounts or developer-operated server records to delete.")
                }

                Section {
                    Text("Last updated 12 July 2026")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Privacy policy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
