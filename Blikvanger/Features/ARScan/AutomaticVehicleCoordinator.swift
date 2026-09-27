import Foundation
import simd

struct AutomaticPipelineStatus: Equatable, Sendable {
    var detections = 0
    var candidates = 0
    var maximumObservationCount = 0
    var poseCandidates = 0
    var maximumDepthSamples = 0
    var maximumMeshSamples = 0
    var acceptedPoseEstimates = 0
    var depthOnlyEstimates = 0
    var lastPoseSource: PoseSource?
    var depthSource: DepthSource = .sceneDepth
    var maximumNormallyTrackedPoseSamples = 0
    var stableCandidates = 0
    var anchoredCandidates = 0
    var currentTargetCardState: VehicleCardState?
}

@MainActor
final class AutomaticVehicleCoordinator {
    private(set) var latestStatus = AutomaticPipelineStatus()
    private var tracker = PlateTracker()
    private var candidateToAnchor: [UUID: UUID] = [:]
    private var provisionalTransforms: [UUID: simd_float4x4] = [:]
    private var stationarityReferences: [UUID: simd_float4x4] = [:]
    private var normallyTrackedPoseTimestamps: [UUID: [TimeInterval]] = [:]
    private var consecutiveSpatialConflicts: [UUID: Int] = [:]
    private var ocrEvidence: [UUID: [OCRObservation]] = [:]
    private var ocrSchedule: [UUID: OCRSchedule] = [:]
    private var completedOCRCandidateIDs = Set<UUID>()
    private var ocrInFlightCandidateID: UUID?
    private var ocrInFlightTimestamp: TimeInterval?
    private let reassociationDistance: Float = 0.45
    private let maximumStationaryDisplacement: Float = 0.18
    private let maximumStationaryAngularDisplacement: Float = .pi / 12
    private let minimumSpatialObservationSpan: TimeInterval = 0.25
    private let minimumNormallyTrackedPoseSamples = 2
    private let maximumNormallyTrackedPoseAge: TimeInterval = 0.55
    private let maximumOCREvidence = 24

    func ingest(
        detections: [PlateDetection],
        depthGrid: DepthGrid,
        calibration: CameraCalibration,
        anchorManager: AnchorManager,
        timestamp: TimeInterval,
        trackingWasNormal: Bool = true,
        depthSource: DepthSource = .sceneDepth,
        meshWorldPointsForQuadrilateral: ((PlateQuadrilateral) -> [MeshSample])? = nil
    ) -> [PlateCandidate] {
        // A rectangle may only be fused with depth and camera calibration from
        // the ARFrame that produced it. Reject mismatched timestamps at this API
        // boundary so a stale detection can never be sampled against newer depth.
        let exactFrameDetections = detections.filter {
            Self.sameFrame($0.timestamp, timestamp)
        }
        _ = tracker.ingest(exactFrameDetections, timestamp: timestamp)
        cleanupMetadata(for: tracker.removedCandidateIDs)
        reconcileMappings(with: anchorManager)

        let candidatesNeedingPose = tracker.candidates.filter {
            $0.consecutiveObservationCount >= 2
                && Self.sameFrame($0.lastSeen, timestamp)
                && $0.state != .rejected
                && $0.state != .lost
        }
        var status = AutomaticPipelineStatus(
            detections: exactFrameDetections.count,
            candidates: tracker.candidates.count,
            maximumObservationCount: tracker.candidates.map(\.consecutiveObservationCount).max() ?? 0,
            poseCandidates: candidatesNeedingPose.count,
            depthSource: depthSource
        )
        for candidate in candidatesNeedingPose {
            guard let quad = candidate.latestQuadrilateral else { continue }
            // Glossy paint and retroreflective plates are commonly labelled low
            // confidence by ARKit even when finite LiDAR measurements are present.
            // The automatic path can admit them because it separately requires a
            // coherent local stencil and repeated world-space agreement.
            let depth = DepthSampler(minimumConfidence: 0).sample(
                quadrilateral: quad,
                grid: depthGrid,
                calibration: calibration
            )
            let meshWorldPoints = meshWorldPointsForQuadrilateral?(quad) ?? []
            status.maximumDepthSamples = max(status.maximumDepthSamples, depth.count)
            status.maximumMeshSamples = max(status.maximumMeshSamples, meshWorldPoints.count)

            let estimator = PlatePoseEstimator()
            let meshEstimate = meshWorldPoints.isEmpty ? nil : estimator.estimate(
                quadrilateral: quad,
                calibration: calibration,
                depthSamples: depth,
                meshWorldPoints: meshWorldPoints
            )
            // Scene reconstruction is coarse and reflective plates often have no
            // collision mesh. Repeated calibrated depth poses are still measured
            // world evidence, so use them when mesh fusion is unavailable.
            let depthPlanarEstimate = estimator.estimate(
                quadrilateral: quad,
                calibration: calibration,
                depthSamples: depth,
                meshWorldPoints: []
            )
            let depthOnlyEstimate = (meshEstimate == nil && depthPlanarEstimate == nil)
                ? DepthCentroidPoseEstimator().estimate(
                    quadrilateral: quad,
                    calibration: calibration,
                    depthSamples: depth
                )
                : nil
            if depthOnlyEstimate != nil {
                status.depthOnlyEstimates += 1
            }
            guard let estimate = meshEstimate ?? depthPlanarEstimate ?? depthOnlyEstimate else {
                continue
            }
            if meshEstimate == nil,
               stronglyContradictoryMesh(meshWorldPoints, estimate: estimate) {
                // Missing or degenerate mesh remains optional. A spatially broad
                // reconstructed surface that is far from the depth-backed plate,
                // however, is independent evidence against committing an anchor.
                continue
            }
            status.acceptedPoseEstimates += 1
            status.lastPoseSource = estimate.source
            // Card attachment uses only the measured world position. A
            // gravity-aligned transform keeps fusion stable when some frames have
            // a strict planar orientation and others use the depth-only path.
            var measuredTransform = matrix_identity_float4x4
            measuredTransform.columns.3 = estimate.worldTransform.columns.3
            if let stationarityReference = stationarityReferences[candidate.id] {
                guard PoseFusion().estimatorsAgree(
                    stationarityReference,
                    measuredTransform,
                    tolerance: maximumStationaryDisplacement,
                    angularTolerance: maximumStationaryAngularDisplacement
                ) else {
                    recordSpatialConflict(candidate.id)
                    continue
                }
            }
            if let provisional = provisionalTransforms[candidate.id],
               !PoseFusion().estimatorsAgree(
                provisional,
                measuredTransform,
                tolerance: 0.22,
                angularTolerance: .pi / 9
               ) {
                recordSpatialConflict(candidate.id)
                continue
            }
            consecutiveSpatialConflicts.removeValue(forKey: candidate.id)
            tracker.addPose(PoseSample(worldTransform: measuredTransform, confidence: estimate.confidence, timestamp: timestamp), to: candidate.id)
            if trackingWasNormal {
                var timestamps = normallyTrackedPoseTimestamps[candidate.id, default: []]
                if !timestamps.contains(where: { Self.sameFrame($0, timestamp) }) {
                    timestamps.append(timestamp)
                }
                normallyTrackedPoseTimestamps[candidate.id] = Array(timestamps.suffix(10))
            }
            guard let updated = tracker.candidate(id: candidate.id) else { continue }
            let recentNormalPoseTimestamps = normallyTrackedPoseTimestamps[candidate.id, default: []]
                .filter { normalTimestamp in
                    updated.poseSamples.contains { Self.sameFrame($0.timestamp, normalTimestamp) }
                }
            normallyTrackedPoseTimestamps[candidate.id] = recentNormalPoseTimestamps
            status.maximumNormallyTrackedPoseSamples = max(
                status.maximumNormallyTrackedPoseSamples,
                recentNormalPoseTimestamps.count
            )
            guard updated.consecutiveObservationCount >= 5,
                  updated.poseSamples.count >= 4,
                  recentNormalPoseTimestamps.count >= minimumNormallyTrackedPoseSamples,
                  let latestNormallyTrackedPose = recentNormalPoseTimestamps.max(),
                  timestamp - latestNormallyTrackedPose <= maximumNormallyTrackedPoseAge,
                  let firstPoseTimestamp = updated.poseSamples.map(\.timestamp).min(),
                  let lastPoseTimestamp = updated.poseSamples.map(\.timestamp).max(),
                  lastPoseTimestamp - firstPoseTimestamp >= minimumSpatialObservationSpan,
                  let stable = PoseFusion().stableTransform(from: updated.poseSamples) else { continue }
            // Set the long-lived stationarity reference only from robustly fused
            // evidence. A single bad first LiDAR frame must not poison acquisition.
            if stationarityReferences[candidate.id] == nil {
                stationarityReferences[candidate.id] = stable
            }
            establishSpatialAnchor(candidateID: candidate.id, stable: stable, anchorManager: anchorManager)
        }
        reassociateStableCandidates(with: anchorManager)
        status.stableCandidates = tracker.candidates.count {
            provisionalTransforms[$0.id] != nil && $0.state != .rejected && $0.state != .lost
        }
        status.anchoredCandidates = tracker.candidates.count {
            candidateToAnchor[$0.id] != nil && $0.state != .rejected && $0.state != .lost
        }
        let currentCandidate = tracker.candidates
            .filter {
                Self.sameFrame($0.lastSeen, timestamp)
                    && $0.state != .rejected
                    && $0.state != .lost
            }
            .sorted {
                if $0.consecutiveObservationCount != $1.consecutiveObservationCount {
                    return $0.consecutiveObservationCount > $1.consecutiveObservationCount
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .first
        if let currentCandidate,
           let trackID = candidateToAnchor[currentCandidate.id],
           let track = anchorManager.track(id: trackID) {
            status.currentTargetCardState = track.cardState
        }
        latestStatus = status
        return tracker.candidates
    }

    func ingestOCR(
        _ observations: [OCRObservation],
        candidateID: UUID,
        reservedAt claimedReservationTimestamp: TimeInterval? = nil,
        anchorManager: AnchorManager
    ) -> DutchLicensePlate? {
        let validObservations = observations.filter { $0.timestamp.isFinite && $0.confidence.isFinite }
        guard ocrInFlightCandidateID == candidateID,
              let reservedTimestamp = ocrInFlightTimestamp,
              claimedReservationTimestamp.map({
                  $0.isFinite && Self.sameFrame($0, reservedTimestamp)
              }) ?? true,
              validObservations.allSatisfy({
                  Self.sameFrame($0.timestamp, reservedTimestamp)
              }) else {
            // An older OCR task for this candidate may finish after a newer frame
            // has already been reserved. It must neither contribute mixed-frame
            // evidence nor release the newer task's reservation.
            return nil
        }

        ocrInFlightCandidateID = nil
        ocrInFlightTimestamp = nil
        guard let candidate = tracker.candidate(id: candidateID),
              candidate.state != .rejected,
              candidate.state != .lost,
              !completedOCRCandidateIDs.contains(candidateID),
              candidateToAnchor[candidateID] != nil || provisionalTransforms[candidateID] != nil else { return nil }

        ocrEvidence[candidateID, default: []].append(contentsOf: validObservations)
        ocrEvidence[candidateID] = Array(ocrEvidence[candidateID, default: []].suffix(maximumOCREvidence))

        guard let plate = PlateConsensus().confirmedPlate(from: ocrEvidence[candidateID, default: []]) else {
            var schedule = ocrSchedule[candidateID, default: OCRSchedule()]
            schedule.recordUnconfirmedResult(hasPlausiblePlateRead: validObservations.contains {
                $0.confidence >= 0.20
                    && $0.confidence <= 1
                    && DutchLicensePlate.recognizedPlate(in: $0.text) != nil
            })
            ocrSchedule[candidateID] = schedule
            tracker.markState(candidateToAnchor[candidateID] == nil ? .spatiallyStable : .anchored, for: candidateID)
            if let trackID = candidateToAnchor[candidateID], var track = anchorManager.track(id: trackID) {
                track.ocrEvidence = ocrEvidence[candidateID, default: []]
                if track.cardState == .generic {
                    track.cardState = .candidate
                }
                anchorManager.update(track)
            }
            return nil
        }

        let currentTrackID = candidateToAnchor[candidateID]
        if let currentTrackID,
           let currentTrack = anchorManager.track(id: currentTrackID),
           let currentPlate = recognizedPlate(for: currentTrack),
           currentPlate != plate {
            tracker.markState(.rejected, for: candidateID)
            return nil
        }

        if let existing = anchorManager.track(
            withCanonicalPlate: plate.canonical,
            excluding: currentTrackID
        ) {
            // The same physical vehicle can be observed from its front and rear.
            // Its two plate observations may be farther apart than spatial
            // reassociation allows, so plate identity is the stronger invariant.
            if let currentTrackID,
               let currentTrack = anchorManager.track(id: currentTrackID),
               currentTrack.canonicalPlate == nil,
               !candidateToAnchor.contains(where: { $0.key != candidateID && $0.value == currentTrackID }) {
                anchorManager.remove(trackID: currentTrackID)
            }
            associate(candidateID: candidateID, with: existing.id, anchorManager: anchorManager)
            completedOCRCandidateIDs.insert(candidateID)
            tracker.markState(.anchored, for: candidateID)
            return plate
        }

        if currentTrackID == nil {
            guard let stable = provisionalTransforms[candidateID] else { return nil }
            if let existing = nearestTrack(to: stable, among: anchorManager.tracks) {
                if let existingPlate = recognizedPlate(for: existing), existingPlate != plate {
                    tracker.markState(.rejected, for: candidateID)
                    return nil
                }
                associate(candidateID: candidateID, with: existing.id, anchorManager: anchorManager)
            } else {
                let track = anchorManager.createAnchor(
                    at: stable,
                    displayName: AppStrings.text("Plate candidate")
                )
                associate(candidateID: candidateID, with: track.id, anchorManager: anchorManager)
            }
        }

        guard let trackID = candidateToAnchor[candidateID],
              var track = anchorManager.track(id: trackID) else { return nil }
        // OCR has confirmed the provisional spatial anchor. It is now persistent
        // and must no longer be removed if the detector candidate later expires.
        completedOCRCandidateIDs.insert(candidateID)
        if track.cardState == .confirmed, recognizedPlate(for: track) == plate {
            tracker.markState(.anchored, for: candidateID)
            return plate
        }
        tracker.markState(.confirming, for: candidateID)
        track.displayName = plate.formatted
        track.lifecycle = .confirming
        track.cardState = .confirming
        track.rdwLookupPlateCanonical = plate.canonical
        track.ocrEvidence = ocrEvidence[candidateID, default: []]
        anchorManager.update(track)
        return plate
    }

    /// Reserves one anchored candidate for OCR. Calls are serialized until the
    /// reservation is completed with `ingestOCR` or `cancelOCR`.
    func nextOCRCandidate(at timestamp: TimeInterval) -> PlateCandidate? {
        guard timestamp.isFinite, ocrInFlightCandidateID == nil else { return nil }
        let eligible = tracker.candidates.filter {
            (candidateToAnchor[$0.id] != nil || provisionalTransforms[$0.id] != nil)
                && Self.sameFrame($0.lastSeen, timestamp)
                && !completedOCRCandidateIDs.contains($0.id)
                && $0.latestQuadrilateral != nil
                && $0.state != .rejected
                && $0.state != .lost
                && ocrSchedule[$0.id, default: OCRSchedule()].canAttempt(at: timestamp)
        }
        guard let selected = eligible.min(by: isLowerOCRPriority) else { return nil }

        var schedule = ocrSchedule[selected.id, default: OCRSchedule()]
        schedule.reserveAttempt(at: timestamp)
        ocrSchedule[selected.id] = schedule
        ocrInFlightCandidateID = selected.id
        ocrInFlightTimestamp = timestamp
        tracker.markState(.reading, for: selected.id)
        return tracker.candidate(id: selected.id)
    }

    func cancelOCR(candidateID: UUID, reservedAt claimedReservationTimestamp: TimeInterval? = nil) {
        guard ocrInFlightCandidateID == candidateID,
              let reservedTimestamp = ocrInFlightTimestamp,
              claimedReservationTimestamp.map({
                  $0.isFinite && Self.sameFrame($0, reservedTimestamp)
              }) ?? true else { return }
        ocrInFlightCandidateID = nil
        ocrInFlightTimestamp = nil
        if tracker.candidate(id: candidateID) != nil {
            tracker.markState(candidateToAnchor[candidateID] == nil ? .spatiallyStable : .anchored, for: candidateID)
        }
    }

    func trackID(for candidateID: UUID) -> UUID? {
        candidateToAnchor[candidateID]
    }

    func reset() {
        tracker.reset()
        candidateToAnchor.removeAll()
        provisionalTransforms.removeAll()
        stationarityReferences.removeAll()
        normallyTrackedPoseTimestamps.removeAll()
        consecutiveSpatialConflicts.removeAll()
        ocrEvidence.removeAll()
        ocrSchedule.removeAll()
        completedOCRCandidateIDs.removeAll()
        ocrInFlightCandidateID = nil
        ocrInFlightTimestamp = nil
        latestStatus = AutomaticPipelineStatus()
    }

    private func nearestTrack(to transform: simd_float4x4, among anchors: [VehicleTrack]) -> VehicleTrack? {
        let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        return anchors.compactMap { track -> (track: VehicleTrack, distance: Float)? in
            let existing = SIMD3(track.stableTransform.columns.3.x, track.stableTransform.columns.3.y, track.stableTransform.columns.3.z)
            let distance = simd_distance(position, existing)
            return distance <= reassociationDistance ? (track, distance) : nil
        }
        .min { $0.distance < $1.distance }?
        .track
    }

    private func establishSpatialAnchor(
        candidateID: UUID,
        stable: simd_float4x4,
        anchorManager: AnchorManager
    ) {
        provisionalTransforms[candidateID] = stable
        guard candidateToAnchor[candidateID] == nil else { return }
        if let existing = nearestTrack(to: stable, among: anchorManager.tracks) {
            guard !candidateToAnchor.contains(where: { $0.key != candidateID && $0.value == existing.id }) else {
                tracker.markState(.rejected, for: candidateID)
                return
            }
            associate(candidateID: candidateID, with: existing.id, anchorManager: anchorManager)
        } else {
            let track = anchorManager.createAnchor(
                at: stable,
                displayName: AppStrings.text("Scanning vehicle")
            )
            associate(candidateID: candidateID, with: track.id, anchorManager: anchorManager)
        }
    }

    private func associate(candidateID: UUID, with trackID: UUID, anchorManager: AnchorManager) {
        guard var track = anchorManager.track(id: trackID) else { return }
        candidateToAnchor[candidateID] = trackID
        tracker.markState(.anchored, for: candidateID)

        switch track.cardState {
        case .generic:
            track.cardState = .candidate
            anchorManager.update(track)
        case .confirming, .loading, .confirmed, .uncertain, .unavailable:
            completedOCRCandidateIDs.insert(candidateID)
        case .candidate:
            break
        }
    }

    private func reconcileMappings(with anchorManager: AnchorManager) {
        let existingTrackIDs = Set(anchorManager.tracks.map(\.id))
        let staleCandidateIDs = Set(candidateToAnchor.compactMap { existingTrackIDs.contains($0.value) ? nil : $0.key })
        for id in staleCandidateIDs {
            tracker.markState(.rejected, for: id)
        }
        cleanupMetadata(for: staleCandidateIDs)
    }

    private func reassociateStableCandidates(with anchorManager: AnchorManager) {
        for candidate in tracker.candidates where candidateToAnchor[candidate.id] == nil {
            guard let stable = provisionalTransforms[candidate.id],
                  let existing = nearestTrack(to: stable, among: anchorManager.tracks) else { continue }
            guard !candidateToAnchor.contains(where: { $0.key != candidate.id && $0.value == existing.id }) else {
                tracker.markState(.rejected, for: candidate.id)
                continue
            }
            associate(candidateID: candidate.id, with: existing.id, anchorManager: anchorManager)
        }
    }

    private func cleanupMetadata(for candidateIDs: Set<UUID>) {
        guard !candidateIDs.isEmpty else { return }
        for id in candidateIDs {
            // Once repeated depth/pose evidence has produced a world anchor, losing
            // the 2D detector candidate must not erase that spatial result. Drop
            // only the short-lived recognition metadata so a later observation can
            // reassociate with the persistent anchor. Explicit reset/removal and a
            // measured motion rejection still remove anchors through their own paths.
            candidateToAnchor.removeValue(forKey: id)
            provisionalTransforms.removeValue(forKey: id)
            stationarityReferences.removeValue(forKey: id)
            normallyTrackedPoseTimestamps.removeValue(forKey: id)
            consecutiveSpatialConflicts.removeValue(forKey: id)
            ocrEvidence.removeValue(forKey: id)
            ocrSchedule.removeValue(forKey: id)
            completedOCRCandidateIDs.remove(id)
        }
        if let inFlight = ocrInFlightCandidateID, candidateIDs.contains(inFlight) {
            ocrInFlightCandidateID = nil
            ocrInFlightTimestamp = nil
        }
    }

    private func isLowerOCRPriority(_ lhs: PlateCandidate, _ rhs: PlateCandidate) -> Bool {
        let lhsSchedule = ocrSchedule[lhs.id, default: OCRSchedule()]
        let rhsSchedule = ocrSchedule[rhs.id, default: OCRSchedule()]
        if lhsSchedule.attemptCount != rhsSchedule.attemptCount {
            return lhsSchedule.attemptCount < rhsSchedule.attemptCount
        }
        if lhsSchedule.lastAttempt != rhsSchedule.lastAttempt {
            return lhsSchedule.lastAttempt < rhsSchedule.lastAttempt
        }
        if lhs.firstSeen != rhs.firstSeen {
            return lhs.firstSeen < rhs.firstSeen
        }
        let lhsBox = lhs.latestQuadrilateral.map(boundingBox) ?? .null
        let rhsBox = rhs.latestQuadrilateral.map(boundingBox) ?? .null
        if lhsBox.minX != rhsBox.minX { return lhsBox.minX < rhsBox.minX }
        if lhsBox.minY != rhsBox.minY { return lhsBox.minY < rhsBox.minY }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func boundingBox(_ quadrilateral: PlateQuadrilateral) -> CGRect {
        PlateDetection(quadrilateral: quadrilateral, confidence: 1, timestamp: 0).boundingBox
    }

    private func stronglyContradictoryMesh(
        _ samples: [MeshSample],
        estimate: PlatePoseEstimate
    ) -> Bool {
        var distinct: [MeshSample] = []
        for sample in samples where sample.worldPoint.x.isFinite
            && sample.worldPoint.y.isFinite
            && sample.worldPoint.z.isFinite {
            guard !distinct.contains(where: {
                hypot($0.imagePoint.x - sample.imagePoint.x, $0.imagePoint.y - sample.imagePoint.y) < 0.004
            }) else { continue }
            distinct.append(sample)
        }
        guard distinct.count >= 3 else { return false }
        let maximumSpan = distinct.indices.flatMap { first in
            distinct.indices.filter { $0 > first }.map {
                simd_distance(distinct[first].worldPoint, distinct[$0].worldPoint)
            }
        }.max() ?? 0
        guard maximumSpan >= 0.04 else { return false }

        func median(_ values: [Float]) -> Float {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        let meshCenter = SIMD3(
            median(distinct.map(\.worldPoint.x)),
            median(distinct.map(\.worldPoint.y)),
            median(distinct.map(\.worldPoint.z))
        )
        let position = estimate.worldTransform.columns.3
        let estimatedCenter = SIMD3(position.x, position.y, position.z)
        return simd_distance(meshCenter, estimatedCenter) > max(0.45, estimate.distance * 0.12)
    }

    private func recognizedPlate(for track: VehicleTrack) -> DutchLicensePlate? {
        guard let canonical = track.canonicalPlate else { return nil }
        return DutchLicensePlate(canonical)
    }

    private func rejectSpatialCandidate(_ candidateID: UUID) {
        // A transform that already passed multi-frame spatial convergence is an
        // established world anchor. Freeze it through later contradictory input;
        // reject only the live detector candidate. This keeps persistence based on
        // spatial evidence instead of whether OCR happened to finish first.
        candidateToAnchor.removeValue(forKey: candidateID)
        provisionalTransforms.removeValue(forKey: candidateID)
        stationarityReferences.removeValue(forKey: candidateID)
        normallyTrackedPoseTimestamps.removeValue(forKey: candidateID)
        consecutiveSpatialConflicts.removeValue(forKey: candidateID)
        ocrEvidence.removeValue(forKey: candidateID)
        ocrSchedule.removeValue(forKey: candidateID)
        completedOCRCandidateIDs.remove(candidateID)
        if ocrInFlightCandidateID == candidateID {
            ocrInFlightCandidateID = nil
            ocrInFlightTimestamp = nil
        }
        tracker.markState(.rejected, for: candidateID)
    }

    private func recordSpatialConflict(_ candidateID: UUID) {
        let count = consecutiveSpatialConflicts[candidateID, default: 0] + 1
        consecutiveSpatialConflicts[candidateID] = count
        // Reflective paint, chrome, and plate material can produce an isolated bad
        // depth/rectangle estimate. Freeze the established anchor through noise and
        // remove it only after repeated, consecutive evidence of real movement.
        if count >= 3 {
            rejectSpatialCandidate(candidateID)
        }
    }

    private static func sameFrame(_ lhs: TimeInterval, _ rhs: TimeInterval) -> Bool {
        abs(lhs - rhs) < 0.000_001
    }
}

private struct OCRSchedule {
    var attemptCount = 0
    var lastAttempt = -TimeInterval.infinity
    private var nextEligibleAttempt = -TimeInterval.infinity
    private var consecutiveUnreadableResults = 0
    private var consecutivePlausibleUnconfirmedResults = 0

    func canAttempt(at timestamp: TimeInterval) -> Bool {
        timestamp + 0.000_001 >= nextEligibleAttempt
    }

    mutating func reserveAttempt(at timestamp: TimeInterval) {
        attemptCount += 1
        lastAttempt = timestamp
        // Even cancellation or an empty result cannot spin another expensive
        // request in the same camera instant. Normal detector cadence is slower
        // than this small floor, so promising multi-frame reads stay responsive.
        nextEligibleAttempt = timestamp + 0.08
    }

    mutating func recordUnconfirmedResult(hasPlausiblePlateRead: Bool) {
        if hasPlausiblePlateRead {
            consecutiveUnreadableResults = 0
            consecutivePlausibleUnconfirmedResults += 1
            // The first three plausible frames must remain fast enough to satisfy
            // temporal consensus. If plausible strings keep conflicting beyond
            // that, taper to one request every two seconds rather than running
            // accurate OCR at detector cadence forever.
            guard consecutivePlausibleUnconfirmedResults >= 3 else { return }
            let exponent = min(consecutivePlausibleUnconfirmedResults - 3, 2)
            let delay = min(2.0, 0.5 * pow(2, Double(exponent)))
            nextEligibleAttempt = max(nextEligibleAttempt, lastAttempt + delay)
            return
        }
        consecutivePlausibleUnconfirmedResults = 0
        consecutiveUnreadableResults += 1
        // Give autofocus and fragmented OCR three consecutive acquisition frames
        // before tapering expensive accurate recognition.
        guard consecutiveUnreadableResults >= 3 else { return }
        let exponent = min(max(consecutiveUnreadableResults - 3, 0), 3)
        let delay = min(3.6, 0.45 * pow(2, Double(exponent)))
        nextEligibleAttempt = max(nextEligibleAttempt, lastAttempt + delay)
    }
}
