import SwiftUI

struct RootView: View {
    @Binding var hasSeenOnboarding: Bool

    var body: some View {
        if hasSeenOnboarding {
            ARScanView()
        } else {
            OnboardingView {
                hasSeenOnboarding = true
            }
        }
    }
}

private struct OnboardingView: View {
    let begin: () -> Void
    @State private var showsPrivacyPolicy = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.08, blue: 0.13), Color(red: 0.08, green: 0.18, blue: 0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Spacer(minLength: 24)
                        Image(systemName: "viewfinder.circle.fill")
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(.mint)
                            .accessibilityHidden(true)
                        Text("Vehicle details,\nright where they belong.")
                            .font(.largeTitle.bold())
                            .fontDesign(.rounded)
                            .foregroundStyle(.white)
                        Text("Point at stationary parked cars. Parked attaches readable cards to their real position, recognizes common yellow Dutch plates on-device, and retrieves public vehicle data from RDW.")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                        Label("Camera images stay on this iPhone. After confirmation, only the plate text is sent to the public RDW service.", systemImage: "hand.raised.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                        Button(action: begin) {
                            Text("Start scanning")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.mint)
                        .foregroundStyle(.black)
                        Button("Privacy policy") {
                            showsPrivacyPolicy = true
                        }
                        .frame(maxWidth: .infinity)
                        Spacer(minLength: 20)
                    }
                    .padding(28)
                    .frame(minHeight: geometry.size.height, alignment: .bottom)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .sheet(isPresented: $showsPrivacyPolicy) {
            PrivacyPolicyView()
        }
    }
}
