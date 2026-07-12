import ARKit
import AVFoundation
import Foundation
import Observation
import RealityKit
import simd

enum ARSupportState: Equatable {
    case checking
    case supported
    case unsupported(reason: String)
    case cameraPermissionDenied
    case sessionFailed(reason: String)
}

private enum OrderedARSessionEvent: Sendable {
    case trackingNormal
    case trackingInsufficientFeatures
    case trackingLimited(relocalizing: Bool)
    case trackingUnavailable
    case failed
    case interrupted
    case interruptionEnded
}

@MainActor
@Observable
final class ARSessionController: NSObject {
    nonisolated let frameGate = FrameAdmissionGate()
    nonisolated let sessionCallbackGate = ARSessionCallbackGate()
    nonisolated let sessionDelegateQueue = DispatchQueue(
        label: "nl.jobvandijke.Parked.ARSessionDelegate",
        qos: .userInitiated
    )
    let anchorManager = AnchorManager()
    private(set) var projections: [UUID: AnchorProjection] = [:]
    private(set) var supportState: ARSupportState = .checking
    private(set) var trackingIsNormal = false
    private(set) var guidance = "Point the camera at a yellow Dutch plate, roughly 1–5 m away"

    private weak var arView: ARView?
    private let automaticCoordinator = AutomaticVehicleCoordinator()
    private let rdwClient: any RDWClientProtocol
    private let detectionWorker = PlateDetectionWorker()
    private let recognitionWorker = PlateRecognitionWorker()
    private var detectionTask: Task<Void, Never>?
    private var detectionJobID: UUID?
    private var recognitionTask: Task<Void, Never>?
    private var recognitionJobID: UUID?
    private var recognitionCandidateID: UUID?
    private var recognitionReservationTimestamp: TimeInterval?
    private var cameraAuthorizationTask: Task<Void, Never>?
    private var requiresSessionReset = false
    private var enrichmentTasks: [UUID: Task<Void, Never>] = [:]
    private var analysisRequested = true
    private var sessionEventBuffer = OrderedSessionEventBuffer<OrderedARSessionEvent>()
    private var isSessionInterrupted = false
    private var lastAutomaticDetectionTimestamp = -TimeInterval.infinity
    private var projectionFrameTrust = ProjectionFrameTrust()
    private var viewOwnership = ARViewOwnership()

    private var readyGuidance: String {
        "Point the camera at a yellow Dutch plate, roughly 1–5 m away"
    }

    private var idleGuidance: String {
        ScanGuidanceReducer().message(
            diagnostics: AutomaticPipelineDiagnostics(),
            tracks: anchorManager.tracks,
            secondsSinceDetection: .infinity,
            readyMessage: readyGuidance
        ) ?? readyGuidance
    }

    override init() {
        self.rdwClient = RDWClient()
        super.init()
    }

    @discardableResult
    func configure(_ arView: ARView) -> ARViewOwnershipToken {
        if let currentView = self.arView, currentView !== arView {
            tearDownCurrentView(pauseSession: true)
            viewOwnership.clear()
        }
        let ownershipToken = viewOwnership.claim(arView)
        isSessionInterrupted = false
        self.arView = arView
        anchorManager.attach(to: arView.session)
        sessionCallbackGate.deactivate()
        frameGate.suspend(minimumTimestamp: arView.session.currentFrame?.timestamp)
        arView.session.delegateQueue = sessionDelegateQueue
        arView.session.delegate = self
        arView.renderOptions.insert(.disableMotionBlur)

        guard ARWorldTrackingConfiguration.isSupported else {
            supportState = .unsupported(reason: "World tracking is not available on this iPhone.")
            return ownershipToken
        }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
              ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            supportState = .unsupported(reason: "Parked requires an iPhone Pro with a LiDAR Scanner for reliable vehicle placement.")
            return ownershipToken
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession(in: arView, resetTracking: requiresSessionReset)
        case .notDetermined:
            supportState = .checking
            cameraAuthorizationTask?.cancel()
            cameraAuthorizationTask = Task { @MainActor [weak self, weak arView] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard let self, let arView, !Task.isCancelled,
                      self.viewOwnership.owns(arView, token: ownershipToken) else { return }
                cameraAuthorizationTask = nil
                if granted {
                    startSession(in: arView, resetTracking: requiresSessionReset)
                } else {
                    supportState = .cameraPermissionDenied
                }
            }
        case .denied, .restricted:
            supportState = .cameraPermissionDenied
        @unknown default:
            supportState = .cameraPermissionDenied
        }
        return ownershipToken
    }

    private func startSession(in arView: ARView, resetTracking: Bool = false) {
        isSessionInterrupted = false
        resetDetectionRecency()
        let configuration = ARWorldTrackingConfiguration()
        if let fourK = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution,
           fourK.framesPerSecond >= 30 {
            // Distant plates are pixel-limited. The detector itself remains
            // cadence-gated, so use ARKit's supported 4K stream when available
            // without increasing how often expensive Vision work runs.
            configuration.videoFormat = fourK
        }
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.sceneReconstruction = .mesh
        configuration.frameSemantics.insert(.sceneDepth)
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        arView.environment.sceneUnderstanding.options = [.occlusion, .physics, .collision, .receivesLighting]
        let options: ARSession.RunOptions = resetTracking
            ? [.resetTracking, .removeExistingAnchors]
            : []
        cancelSpatialPipelineWork(resetCandidates: resetTracking)
        runSession(configuration, options: options, in: arView)
        requiresSessionReset = false
        guidance = resetTracking
            ? "Move slowly while scanning restarts"
            : "Move slowly while scanning starts"
        supportState = .supported
    }

    /// Establishes an explicit run boundary. Old callbacks are invalidated and
    /// drained while frame admission remains suspended; timestamp floors then
    /// prevent a queued pre-run frame from being labelled with the new generation.
    private func runSession(
        _ configuration: ARConfiguration,
        options: ARSession.RunOptions,
        in arView: ARView
    ) {
        guard self.arView === arView else { return }
        let session = arView.session
        let preRunTimestamp = session.currentFrame?.timestamp
        frameGate.suspend(minimumTimestamp: preRunTimestamp)
        requireFreshProjectionFrame(after: preRunTimestamp)

        sessionCallbackGate.deactivate()
        session.delegate = nil
        sessionDelegateQueue.sync {}
        sessionCallbackGate.activate(session)
        sessionEventBuffer.reset()
        session.delegateQueue = sessionDelegateQueue
        session.delegate = self

        session.run(configuration, options: options)
        let postRunTimestamp = session.currentFrame?.timestamp ?? preRunTimestamp
        projectionFrameTrust.requireFreshFrame(after: postRunTimestamp)
        if analysisRequested {
            frameGate.activate(minimumTimestamp: postRunTimestamp)
        } else {
            frameGate.suspend(minimumTimestamp: postRunTimestamp)
        }
    }

    func resumeAfterAuthorizationChange() {
        guard supportState == .cameraPermissionDenied,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let arView else { return }
        startSession(in: arView, resetTracking: requiresSessionReset)
    }

    func retrySession() {
        guard case .sessionFailed = supportState, let arView else { return }
        supportState = .checking
        trackingIsNormal = false
        guidance = "Restarting scanning…"

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession(in: arView, resetTracking: true)
        case .notDetermined:
            configure(arView)
        case .denied, .restricted:
            supportState = .cameraPermissionDenied
        @unknown default:
            supportState = .cameraPermissionDenied
        }
    }

    func updateProjections() {
        guard analysisRequested,
              let arView,
              let frame = arView.session.currentFrame,
              arView.bounds.width > 0,
              arView.bounds.height > 0 else {
            projections = [:]
            return
        }
        let frameTrackingWasNormal: Bool
        if case .normal = frame.camera.trackingState {
            frameTrackingWasNormal = true
        } else {
            frameTrackingWasNormal = false
        }
        guard projectionFrameTrust.accepts(
            timestamp: frame.timestamp,
            trackingWasNormal: frameTrackingWasNormal
        ) else {
            if !frameTrackingWasNormal {
                projectionFrameTrust.requireFreshFrame(after: frame.timestamp)
            }
            trackingIsNormal = false
            projections = [:]
            return
        }
        if !trackingIsNormal {
            trackingIsNormal = true
            guidance = idleGuidance
        }
        let viewport = arView.bounds.size
        let viewProjection = frame.camera.projectionMatrix(
            for: .portrait,
            viewportSize: viewport,
            zNear: 0.001,
            zFar: 100
        ) * frame.camera.viewMatrix(for: .portrait)
        let camera = frame.camera.transform.columns.3
        let cameraWorldPosition = SIMD3(camera.x, camera.y, camera.z)
        let projectionService = AnchorProjectionService()
        let trackedAnchorIdentifiers = Set(anchorManager.tracks.map(\.anchorIdentifier))
        let transformsByIdentifier = frame.anchors.reduce(into: [UUID: simd_float4x4]()) { result, anchor in
            guard trackedAnchorIdentifiers.contains(anchor.identifier) else { return }
            result[anchor.identifier] = anchor.transform
        }
        let frameAnchorTransforms = FrameAnchorTransformIndex(
            transformsByIdentifier: transformsByIdentifier
        )
        for track in anchorManager.tracks {
            if let transform = frameAnchorTransforms.transform(for: track.anchorIdentifier) {
                anchorManager.synchronizeARKitTransform(
                    anchorIdentifier: track.anchorIdentifier,
                    transform: transform
                )
            }
        }
        var next: [UUID: AnchorProjection] = [:]
        for track in anchorManager.tracks {
            // Camera and anchor transforms must come from the same ARFrame. If
            // ARKit has not delivered (or has removed) this anchor for the frame,
            // hide it instead of projecting a stale model-space transform.
            guard let anchorTransform = frameAnchorTransforms.transform(
                for: track.anchorIdentifier
            ) else { continue }
            let base = anchorTransform.columns.3
            let basePosition = SIMD3<Float>(base.x, base.y, base.z)
            let attachment = SIMD3<Float>(base.x, base.y + 0.75, base.z)
            next[track.id] = projectionService.projectAnnotation(
                trackID: track.id,
                baseWorldPoint: basePosition,
                attachmentWorldPoint: attachment,
                viewProjection: viewProjection,
                viewport: viewport,
                cameraWorldPosition: cameraWorldPosition
            )
        }
        projections = next
    }

    func reset() {
        cancelPipelineWork()
        Task { await rdwClient.clearCache() }
        let currentFrameTimestamp = arView?.session.currentFrame?.timestamp
        frameGate.suspend(minimumTimestamp: currentFrameTimestamp)
        requireFreshProjectionFrame(after: currentFrameTimestamp)
        automaticCoordinator.reset()
        anchorManager.reset()
        projections.removeAll()
        resetDetectionRecency()
        guard let arView, let configuration = arView.session.configuration else { return }
        runSession(
            configuration,
            options: [.resetTracking, .removeExistingAnchors],
            in: arView
        )
        guidance = "Move slowly while scanning restarts. \(readyGuidance)"
    }

    func stop(ownedBy token: ARViewOwnershipToken, arView expectedView: ARView) {
        guard viewOwnership.owns(expectedView, token: token),
              arView === expectedView else { return }
        viewOwnership.release(expectedView, token: token)
        tearDownCurrentView(pauseSession: true)
    }

    private func tearDownCurrentView(pauseSession: Bool) {
        let ownedView = arView
        sessionCallbackGate.deactivate()
        frameGate.suspend(minimumTimestamp: ownedView?.session.currentFrame?.timestamp)
        ownedView?.session.delegate = nil
        cancelPipelineWork()
        automaticCoordinator.reset()
        // An AR world map is session-relative. If SwiftUI dismantles this ARView,
        // retaining its transforms for a later, fresh session would show stale
        // labels with no corresponding ARAnchor objects in that session.
        anchorManager.reset()
        projections.removeAll()
        resetDetectionRecency()
        trackingIsNormal = false
        isSessionInterrupted = false
        supportState = .checking
        arView = nil
        if pauseSession {
            ownedView?.session.pause()
        }
    }

    func setAnalysisEnabled(_ enabled: Bool) {
        guard analysisRequested != enabled else { return }
        analysisRequested = enabled
        let currentFrameTimestamp = arView?.session.currentFrame?.timestamp
        if enabled {
            requireFreshProjectionFrame(after: currentFrameTimestamp)
            guard !isSessionInterrupted else {
                frameGate.suspend(minimumTimestamp: currentFrameTimestamp)
                guidance = "Scanning paused — waiting for camera tracking"
                return
            }
            frameGate.activate(minimumTimestamp: currentFrameTimestamp)
            guidance = "Move slowly while scanning resumes"
        } else {
            frameGate.suspend(minimumTimestamp: currentFrameTimestamp)
            requireFreshProjectionFrame(after: currentFrameTimestamp)
            cancelSpatialPipelineWork(resetCandidates: true)
            guidance = "Scanning paused"
        }
    }

    private func requireFreshProjectionFrame(after timestamp: TimeInterval?) {
        projectionFrameTrust.requireFreshFrame(after: timestamp)
        trackingIsNormal = false
        projections.removeAll()
    }

    private func cancelPipelineWork() {
        cameraAuthorizationTask?.cancel()
        cameraAuthorizationTask = nil
        cancelSpatialPipelineWork(resetCandidates: false)
        for task in enrichmentTasks.values { task.cancel() }
        enrichmentTasks.removeAll()
    }

    private func cancelSpatialPipelineWork(resetCandidates: Bool) {
        detectionTask?.cancel()
        detectionTask = nil
        detectionJobID = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionJobID = nil
        if let recognitionCandidateID {
            automaticCoordinator.cancelOCR(
                candidateID: recognitionCandidateID,
                reservedAt: recognitionReservationTimestamp
            )
            self.recognitionCandidateID = nil
            recognitionReservationTimestamp = nil
        }
        if resetCandidates {
            automaticCoordinator.reset()
        }
    }

    private func accept(_ snapshot: ARFrameSnapshot) {
        let admission = FrameAdmission(
            timestamp: snapshot.timestamp,
            generation: snapshot.generation,
            droppedFrames: snapshot.droppedFrames
        )
        guard supportState == .supported,
              analysisRequested,
              frameGate.isCurrent(snapshot.generation) else {
            frameGate.finish(admission)
            return
        }
        let jobID = UUID()
        detectionJobID = jobID
        detectionTask = Task { @MainActor [weak self] in
            defer {
                self?.frameGate.finish(admission)
                if self?.detectionJobID == jobID {
                    self?.detectionTask = nil
                    self?.detectionJobID = nil
                }
            }
            guard let self, !Task.isCancelled else { return }
            let detections = await detectionWorker.detect(snapshot: snapshot)
            guard !Task.isCancelled,
                  frameGate.isCurrent(snapshot.generation) else { return }
            _ = automaticCoordinator.ingest(
                detections: detections,
                depthGrid: snapshot.depthGrid,
                calibration: snapshot.calibration,
                anchorManager: anchorManager,
                timestamp: snapshot.timestamp,
                trackingWasNormal: snapshot.trackingWasNormal,
                meshWorldPointsForQuadrilateral: { [weak arView] quadrilateral in
                    guard let arView else { return [] }
                    return MeshEvidenceProvider().worldPoints(
                        for: quadrilateral,
                        calibration: snapshot.calibration,
                        in: arView
                    )
                }
            )
            let diagnostics = automaticCoordinator.latestDiagnostics
            updateAutomaticGuidance(diagnostics, timestamp: snapshot.timestamp)
            scheduleRecognition(snapshot: snapshot)
            scheduleEligibleEnrichmentRetries(generation: snapshot.generation)
        }
    }

    private func scheduleRecognition(snapshot: ARFrameSnapshot) {
        guard recognitionTask == nil,
              let candidate = automaticCoordinator.nextOCRCandidate(at: snapshot.timestamp),
              let quad = candidate.latestQuadrilateral else { return }
        let jobID = UUID()
        recognitionJobID = jobID
        recognitionCandidateID = candidate.id
        recognitionReservationTimestamp = snapshot.timestamp
        recognitionTask = Task { @MainActor [weak self] in
            var releasedReservation = false
            defer {
                if let self {
                    if !releasedReservation {
                        automaticCoordinator.cancelOCR(
                            candidateID: candidate.id,
                            reservedAt: snapshot.timestamp
                        )
                    }
                    if recognitionJobID == jobID {
                        recognitionTask = nil
                        recognitionJobID = nil
                        recognitionCandidateID = nil
                        recognitionReservationTimestamp = nil
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            let observations = await recognitionWorker.recognize(
                snapshot: snapshot,
                rawQuadrilateral: quad
            )
            guard !Task.isCancelled,
                  frameGate.isCurrent(snapshot.generation) else { return }
            let plate = automaticCoordinator.ingestOCR(
                observations,
                candidateID: candidate.id,
                reservedAt: snapshot.timestamp,
                anchorManager: anchorManager
            )
            // A rejected mixed/stale result intentionally leaves its reservation
            // untouched inside the coordinator. Release only this exact frame's
            // token here so a newer reservation can never be cancelled by it.
            automaticCoordinator.cancelOCR(
                candidateID: candidate.id,
                reservedAt: snapshot.timestamp
            )
            releasedReservation = true
            if let plate,
               let trackID = automaticCoordinator.trackID(for: candidate.id) {
                scheduleEnrichment(trackID: trackID, plate: plate, generation: snapshot.generation)
            }
        }
    }

    private func scheduleEnrichment(trackID: UUID, plate: DutchLicensePlate, generation: UInt64) {
        guard enrichmentTasks[trackID] == nil else { return }
        enrichmentTasks[trackID] = Task { @MainActor [weak self] in
            defer { self?.enrichmentTasks[trackID] = nil }
            guard let self, !Task.isCancelled, frameGate.isCurrent(generation) else { return }
            await VehicleEnrichmentService().enrich(
                trackID: trackID,
                plate: plate,
                anchorManager: anchorManager,
                client: rdwClient
            )
        }
    }

    private func scheduleEligibleEnrichmentRetries(generation: UInt64) {
        for request in VehicleEnrichmentRetryPolicy().dueRequests(
            in: anchorManager.tracks,
            at: Date()
        ) {
            scheduleEnrichment(
                trackID: request.trackID,
                plate: request.plate,
                generation: generation
            )
        }
    }

    private func invalidateSpatialAnalysis(resetCandidates: Bool = true) {
        let timestamp = arView?.session.currentFrame?.timestamp
        if analysisRequested, !isSessionInterrupted {
            frameGate.reset(minimumTimestamp: timestamp)
        } else {
            frameGate.suspend(minimumTimestamp: timestamp)
        }
        cancelSpatialPipelineWork(resetCandidates: resetCandidates)
    }

    private func updateAutomaticGuidance(
        _ diagnostics: AutomaticPipelineDiagnostics,
        timestamp: TimeInterval
    ) {
        if diagnostics.detections > 0 {
            lastAutomaticDetectionTimestamp = timestamp
        }
        if let message = ScanGuidanceReducer().message(
            diagnostics: diagnostics,
            tracks: anchorManager.tracks,
            secondsSinceDetection: timestamp - lastAutomaticDetectionTimestamp,
            readyMessage: readyGuidance
        ) {
            guidance = message
        }
    }

    private func resetDetectionRecency() {
        lastAutomaticDetectionTimestamp = -.infinity
    }

    private func discardFailedSessionState() {
        isSessionInterrupted = false
        cancelPipelineWork()
        let currentFrameTimestamp = arView?.session.currentFrame?.timestamp
        frameGate.suspend(minimumTimestamp: currentFrameTimestamp)
        requireFreshProjectionFrame(after: currentFrameTimestamp)
        automaticCoordinator.reset()
        anchorManager.reset()
        projections.removeAll()
        arView?.session.pause()
        requiresSessionReset = true
    }

    private func acceptSessionEvent(_ event: OrderedARSessionEvent, token: ARSessionEventToken) {
        guard sessionCallbackGate.isCurrent(token) else { return }
        for orderedEvent in sessionEventBuffer.receive(event, token: token) {
            handleSessionEvent(orderedEvent)
        }
    }

    private func handleSessionEvent(_ event: OrderedARSessionEvent) {
        let currentTimestamp = arView?.session.currentFrame?.timestamp
        switch event {
        case .trackingNormal:
            guard supportState == .supported else { return }
            if analysisRequested, !isSessionInterrupted {
                updateProjections()
            }
        case .trackingInsufficientFeatures:
            guard supportState == .supported else { return }
            requireFreshProjectionFrame(after: currentTimestamp)
            if analysisRequested, !isSessionInterrupted {
                guidance = "Keep a plate in view and hold the iPhone steady"
            }
        case .trackingLimited(let relocalizing):
            guard supportState == .supported else { return }
            requireFreshProjectionFrame(after: currentTimestamp)
            // Initializing, excessive motion, and relocalization establish a new
            // tracking-quality epoch. Discard all unanchored temporal/pose
            // evidence so pre-degradation poses cannot authorize a later anchor.
            invalidateSpatialAnalysis(resetCandidates: true)
            guidance = relocalizing
                ? "Recovering saved vehicle positions — move slowly"
                : "Move the iPhone slowly"
        case .trackingUnavailable:
            guard supportState == .supported else { return }
            requireFreshProjectionFrame(after: currentTimestamp)
            invalidateSpatialAnalysis()
            guidance = "Camera tracking is unavailable"
        case .failed:
            requireFreshProjectionFrame(after: currentTimestamp)
            discardFailedSessionState()
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .denied, .restricted:
                supportState = .cameraPermissionDenied
            default:
                guidance = "Scanning is unavailable"
                supportState = .sessionFailed(
                    reason: "The camera tracking session stopped unexpectedly. Please try again."
                )
            }
        case .interrupted:
            isSessionInterrupted = true
            requireFreshProjectionFrame(after: currentTimestamp)
            frameGate.suspend(minimumTimestamp: currentTimestamp)
            cancelSpatialPipelineWork(resetCandidates: true)
            guidance = "Scanning paused — vehicles will return when tracking recovers"
        case .interruptionEnded:
            isSessionInterrupted = false
            requireFreshProjectionFrame(after: currentTimestamp)
            if analysisRequested {
                frameGate.activate(minimumTimestamp: currentTimestamp)
            } else {
                frameGate.suspend(minimumTimestamp: currentTimestamp)
            }
            guidance = "Move slowly while scanning recovers"
        }
    }
}

extension ARSessionController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard sessionCallbackGate.owns(session) else { return }
        let trackingSupportsAnalysis: Bool
        switch frame.camera.trackingState {
        case .normal, .limited(.insufficientFeatures):
            // Smooth vehicle panels often provide too few visual keypoints even
            // though LiDAR depth and a continuously tracked camera transform are
            // available. Continue measured analysis in that state; initializing,
            // relocalizing, and excessive-motion states remain blocked.
            trackingSupportsAnalysis = true
        default:
            trackingSupportsAnalysis = false
        }
        guard let admission = frameGate.admit(
            timestamp: frame.timestamp,
            trackingIsNormal: trackingSupportsAnalysis
        ) else { return }
        guard let snapshot = ARFrameSnapshot.make(from: frame, admission: admission) else {
            frameGate.finish(admission)
            return
        }
        Task { @MainActor [weak self] in self?.accept(snapshot) }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard let token = sessionCallbackGate.token(for: session) else { return }
        let event: OrderedARSessionEvent = switch camera.trackingState {
        case .normal:
            .trackingNormal
        case .limited(.insufficientFeatures):
            .trackingInsufficientFeatures
        case .limited(let reason):
            .trackingLimited(relocalizing: reason == .relocalizing)
        case .notAvailable:
            .trackingUnavailable
        }
        Task { @MainActor [weak self] in
            self?.acceptSessionEvent(event, token: token)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: any Error) {
        guard let token = sessionCallbackGate.token(for: session) else { return }
        Task { @MainActor [weak self] in
            self?.acceptSessionEvent(.failed, token: token)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        guard let token = sessionCallbackGate.token(for: session) else { return }
        Task { @MainActor [weak self] in
            self?.acceptSessionEvent(.interrupted, token: token)
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        guard let token = sessionCallbackGate.token(for: session) else { return }
        Task { @MainActor [weak self] in
            self?.acceptSessionEvent(.interruptionEnded, token: token)
        }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        sessionCallbackGate.owns(session)
    }
}
