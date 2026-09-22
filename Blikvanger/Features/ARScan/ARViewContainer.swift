import Combine
import RealityKit
import SwiftUI

struct ARViewContainer: UIViewRepresentable {
    let controller: ARSessionController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let projectionScheduler = context.coordinator.projectionScheduler
        context.coordinator.updateSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak controller] _ in
            guard let controller else { return }
            projectionScheduler.schedule(for: controller)
        }
        context.coordinator.ownershipToken = controller.configure(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.updateSubscription?.cancel()
        if let ownershipToken = coordinator.ownershipToken {
            coordinator.controller.stop(ownedBy: ownershipToken, arView: uiView)
            coordinator.ownershipToken = nil
        }
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject {
        let controller: ARSessionController
        nonisolated let projectionScheduler = ProjectionUpdateScheduler()
        var updateSubscription: (any Cancellable)?
        var ownershipToken: ARViewOwnershipToken?

        init(controller: ARSessionController) {
            self.controller = controller
        }
    }
}
