import SwiftUI
import UIKit

struct ARScanView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var controller = ARSessionController()
    @State private var detailTrack: VehicleTrack?
    @State private var showsPrivacyPolicy = false
    @State private var confirmsReset = false

    var body: some View {
        ZStack {
            ARViewContainer(controller: controller)
                .ignoresSafeArea()

            switch controller.supportState {
            case .checking:
                CheckingCameraView()
            case .unsupported(let reason):
                UnsupportedDeviceView(reason: reason) {
                    showsPrivacyPolicy = true
                }
            case .cameraPermissionDenied:
                CameraPermissionView {
                    showsPrivacyPolicy = true
                }
            case .sessionFailed(let reason):
                SessionFailureView(
                    reason: reason,
                    retry: controller.retrySession,
                    showPrivacyPolicy: { showsPrivacyPolicy = true }
                )
            case .supported:
                scanOverlay
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            updateAnalysisIntent()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controller.resumeAfterAuthorizationChange()
            }
            updateAnalysisIntent()
        }
        .onChange(of: detailTrack?.id) { _, _ in
            updateAnalysisIntent()
        }
        .onChange(of: showsPrivacyPolicy) { _, _ in
            updateAnalysisIntent()
        }
        .onChange(of: confirmsReset) { _, _ in
            updateAnalysisIntent()
        }
        .sheet(item: $detailTrack) { selectedTrack in
            LiveVehicleDetailsView(
                anchorManager: controller.anchorManager,
                trackID: selectedTrack.id,
                fallback: selectedTrack
            ) {
                detailTrack = nil
            }
        }
        .sheet(isPresented: $showsPrivacyPolicy) {
            PrivacyPolicyView()
        }
        .confirmationDialog(
            "Remove all vehicles?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Remove all vehicles", role: .destructive) {
                controller.reset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every vehicle found during this scan.")
        }
    }

    private func updateAnalysisIntent() {
        controller.setAnalysisEnabled(
            scenePhase == .active
                && detailTrack == nil
                && !showsPrivacyPolicy
                && !confirmsReset
        )
    }

    private var scanOverlay: some View {
        GeometryReader { geometry in
            let cardSize = VehicleCardView.layoutSize(for: dynamicTypeSize)
            let bottomControlClearance: CGFloat = dynamicTypeSize.isAccessibilitySize ? 176 : 92
            let safeFrame = CGRect(origin: .zero, size: geometry.size)
                .inset(by: UIEdgeInsets(
                    top: geometry.safeAreaInsets.top + 64,
                    left: 12,
                    bottom: geometry.safeAreaInsets.bottom + bottomControlClearance,
                    right: 12
                ))
            let scanStatus = PendingPlateLookupFormatter().text(
                for: controller.anchorManager.tracks
            ) ?? controller.guidance
            let visible = controller.anchorManager.tracks.compactMap { track -> CardLayoutItem? in
                guard let projection = controller.projections[track.id], projection.isVisible else { return nil }
                let scale = VehicleCardView.prominenceScale(
                    for: projection.depth,
                    dynamicTypeSize: dynamicTypeSize
                )
                return CardLayoutItem(
                    id: track.id,
                    desiredPoint: projection.point,
                    size: CGSize(width: cardSize.width * scale, height: cardSize.height * scale),
                    depth: projection.depth
                )
            }
            let layouts = CardLayoutEngine().layout(
                items: visible,
                safeFrame: safeFrame
            )
            ZStack {
                ForEach(layouts.filter(\.needsLeaderLine), id: \.id) { layout in
                    LeaderLine(start: layout.anchorPoint, end: layout.cardPoint)
                        .stroke(.white.opacity(0.65), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 4]))
                        .allowsHitTesting(false)
                }
                ForEach(controller.anchorManager.tracks) { track in
                    if let projection = controller.projections[track.id], projection.isVisible,
                       let layout = layouts.first(where: { $0.id == track.id }) {
                        Button {
                            controller.anchorManager.selectedTrackID = track.id
                            detailTrack = track
                        } label: {
                            VehicleCardView(track: track, distance: projection.depth, layoutSize: cardSize)
                        }
                            .buttonStyle(.plain)
                            .position(layout.cardPoint)
                            .accessibilityAddTraits(controller.anchorManager.selectedTrackID == track.id ? .isSelected : [])
                            .accessibilityHint("Opens vehicle details")
                    }
                }

                VStack(spacing: 12) {
                    HStack {
                        Label(
                            SpatialLabelCountFormatter().text(
                                total: controller.anchorManager.tracks.count
                            ),
                            systemImage: "mappin.and.ellipse"
                        )
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                        Button {
                            showsPrivacyPolicy = true
                        } label: {
                            Image(systemName: "info.circle")
                                .frame(width: 44, height: 44)
                        }
                        .background(.ultraThinMaterial, in: Circle())
                        .accessibilityLabel("Privacy policy")
                        Button(role: .destructive) {
                            if controller.anchorManager.tracks.isEmpty {
                                controller.reset()
                            } else {
                                confirmsReset = true
                            }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .frame(width: 44, height: 44)
                        }
                        .background(.ultraThinMaterial, in: Circle())
                        .accessibilityLabel(
                            controller.anchorManager.tracks.isEmpty
                                ? "Restart scanning"
                                : "Remove all vehicles"
                        )
                    }

                    Spacer()

                    Text(scanStatus)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityLabel("Scanning status: \(scanStatus)")
                        .accessibilityAddTraits(.updatesFrequently)
                }
                .padding(.horizontal, 16)
                .padding(.top, max(8, geometry.safeAreaInsets.top))
                .padding(.bottom, max(12, geometry.safeAreaInsets.bottom))
            }
        }
    }
}

private struct LiveVehicleDetailsView: View {
    let anchorManager: AnchorManager
    let trackID: UUID
    let fallback: VehicleTrack
    let didRemove: () -> Void

    var body: some View {
        VehicleDetailsView(track: anchorManager.track(id: trackID) ?? fallback) {
            anchorManager.remove(trackID: trackID)
            didRemove()
        }
    }
}

private struct CheckingCameraView: View {
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.07, blue: 0.1).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing camera…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CameraPermissionView: View {
    @Environment(\.openURL) private var openURL
    let showPrivacyPolicy: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.07, blue: 0.1).ignoresSafeArea()
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 18) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.mint)
                            .accessibilityHidden(true)
                        Text("Camera access needed")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                        Text("Allow camera access in Settings so Blikvanger can scan vehicles. Camera images stay on this iPhone.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Open Settings") {
                            guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(settings)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.mint)
                        .foregroundStyle(.black)
                        PrivacyPolicyAccessButton(action: showPrivacyPolicy)
                    }
                    .padding(32)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

private struct UnsupportedDeviceView: View {
    let reason: String
    let showPrivacyPolicy: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.07, blue: 0.1).ignoresSafeArea()
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 18) {
                        Image(systemName: "sensor.tag.radiowaves.forward")
                            .font(.system(size: 52))
                            .foregroundStyle(.mint)
                            .accessibilityHidden(true)
                        Text("LiDAR required")
                            .font(.largeTitle.bold())
                        Text(reason)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Text("Blikvanger uses scene depth and mesh reconstruction so labels stay attached to the correct vehicle.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        PrivacyPolicyAccessButton(action: showPrivacyPolicy)
                    }
                    .padding(32)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

private struct SessionFailureView: View {
    let reason: String
    let retry: () -> Void
    let showPrivacyPolicy: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.07, blue: 0.1).ignoresSafeArea()
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 18) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("Scanning stopped")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                        Text(reason)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Text("Vehicles found during this scan were cleared so they are not shown in the wrong place.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Retry scanning", action: retry)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(.mint)
                            .foregroundStyle(.black)
                            .accessibilityHint("Starts a fresh scanning session")
                        PrivacyPolicyAccessButton(action: showPrivacyPolicy)
                    }
                    .padding(32)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

private struct PrivacyPolicyAccessButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Privacy policy", systemImage: "lock.shield")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}
