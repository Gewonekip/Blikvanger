import simd
import XCTest
@testable import LicensePlates

@MainActor
final class PipelineReplayTests: XCTestCase {
    func testAnchorReplayCreatesProjectedPersistentCardThenResetRemovesIt() {
        let manager = AnchorManager()
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(0, 0, 0.5, 1)
        let track = manager.createAnchor(at: transform)
        let projection = AnchorProjectionService().project(
            trackID: track.id,
            worldPoint: SIMD3(0, 0, 0.5),
            viewProjection: matrix_identity_float4x4,
            viewport: CGSize(width: 390, height: 844)
        )
        XCTAssertTrue(projection.isVisible)
        XCTAssertEqual(manager.track(id: track.id)?.stableTransform.columns.3.z, 0.5)
        manager.reset()
        XCTAssertTrue(manager.tracks.isEmpty)
    }

    func testAutomaticReplayNeedsRepeatedSpatialEvidenceThenEnrichesExistingAnchor() async {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        let detection = { (time: Double) in PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: time) }
        let calibration = CameraCalibration(
            intrinsics: simd_float3x3(SIMD3(900, 0, 0), SIMD3(0, 900, 0), SIMD3(200, 100, 1)),
            cameraToWorld: matrix_identity_float4x4,
            imageSize: SIMD2(400, 200)
        )
        let grid = DepthGrid(width: 4, height: 4, depths: Array(repeating: 2, count: 16), confidences: Array(repeating: 2, count: 16))
        var candidates: [PlateCandidate] = []
        for index in 0..<5 {
            let time = Double(index) * 0.1
            candidates = coordinator.ingest(detections: [detection(time)], depthGrid: grid, calibration: calibration, anchorManager: manager, timestamp: time)
        }
        let candidateID = candidates[0].id
        XCTAssertEqual(manager.tracks.count, 1, "Stable measured geometry should create the spatial anchor before OCR")
        XCTAssertEqual(manager.tracks[0].cardState, .candidate)
        let anchorID = manager.tracks[0].id

        confirmPlate(for: candidateID, coordinator: coordinator, manager: manager, startingAt: 0.5)
        XCTAssertEqual(manager.tracks.count, 1)
        XCTAssertEqual(manager.tracks[0].id, anchorID, "OCR must enrich the existing spatial anchor")
        let plate = DutchLicensePlate("12BD34")!
        await VehicleEnrichmentService().enrich(trackID: anchorID, plate: plate, anchorManager: manager, client: RDWMock())

        XCTAssertEqual(manager.tracks.count, 1, "RDW must update rather than replace the spatial anchor")
        XCTAssertEqual(manager.tracks[0].id, anchorID)
        XCTAssertEqual(manager.tracks[0].vehicle?.make, "Volvo")
        XCTAssertEqual(manager.tracks[0].cardState, .confirmed)

        let revisitTimestamp = 0.8
        _ = coordinator.ingest(
            detections: [detection(revisitTimestamp)],
            depthGrid: grid,
            calibration: calibration,
            anchorManager: manager,
            timestamp: revisitTimestamp
        )
        XCTAssertEqual(coordinator.latestDiagnostics.currentTargetCardState, .confirmed)
    }

    func testOCRFailureLeavesTheMeasuredCandidateAnchorInPlace() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        let candidates = establishCandidates(
            [quad],
            coordinator: coordinator,
            manager: manager,
            startingAt: 0
        )
        let candidateID = candidates[0].id
        let trackID = manager.tracks[0].id
        let anchorIdentifier = manager.tracks[0].anchorIdentifier

        let timestamp = 0.5
        _ = coordinator.ingest(
            detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
            depthGrid: depthGrid(),
            calibration: calibration(),
            anchorManager: manager,
            timestamp: timestamp
        )
        XCTAssertEqual(coordinator.nextOCRCandidate(at: timestamp)?.id, candidateID)
        XCTAssertNil(coordinator.ingestOCR(
            [OCRObservation(text: "NOT A PLATE", confidence: 0.95, timestamp: timestamp)],
            candidateID: candidateID,
            anchorManager: manager
        ))

        XCTAssertEqual(manager.tracks.count, 1)
        XCTAssertEqual(manager.tracks[0].id, trackID)
        XCTAssertEqual(manager.tracks[0].anchorIdentifier, anchorIdentifier)
        XCTAssertEqual(manager.tracks[0].cardState, .candidate)
        XCTAssertNil(manager.tracks[0].vehicle)
    }

    func testLocalizedCandidateCanReadRGBWhenCurrentLiDARFrameHasNoPose() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        let candidateID = establishCandidates(
            [quad],
            coordinator: coordinator,
            manager: manager,
            startingAt: 0
        )[0].id
        let timestamp = 0.5
        let unavailableDepth = DepthGrid(
            width: 2,
            height: 2,
            depths: Array(repeating: .nan, count: 4),
            confidences: Array(repeating: 0, count: 4)
        )

        let candidates = coordinator.ingest(
            detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
            depthGrid: unavailableDepth,
            calibration: calibration(),
            anchorManager: manager,
            timestamp: timestamp
        )

        XCTAssertFalse(candidates[0].poseSamples.contains { abs($0.timestamp - timestamp) < 0.000_001 })
        XCTAssertEqual(coordinator.nextOCRCandidate(at: timestamp)?.id, candidateID)
        XCTAssertNil(coordinator.ingestOCR(
            [OCRObservation(text: "12BD34", confidence: 0.75, timestamp: timestamp)],
            candidateID: candidateID,
            anchorManager: manager
        ))
        XCTAssertEqual(manager.tracks.count, 1)
    }

    func testOCRStillRejectsAnObservationFromOutsideItsReservedFrame() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        let candidateID = establishCandidates(
            [quad],
            coordinator: coordinator,
            manager: manager,
            startingAt: 0
        )[0].id

        XCTAssertEqual(coordinator.nextOCRCandidate(at: 0.4)?.id, candidateID)
        XCTAssertNil(coordinator.ingestOCR(
            [OCRObservation(text: "12BD34", confidence: 0.95, timestamp: 0.3)],
            candidateID: candidateID,
            anchorManager: manager
        ))
        XCTAssertTrue(manager.tracks[0].ocrEvidence.isEmpty)
    }

    func testOCRRejectsEntireBatchWhenAnyFiniteObservationHasAnotherTimestamp() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let candidateID = establishCandidates(
            [standardQuad()],
            coordinator: coordinator,
            manager: manager,
            startingAt: 0
        )[0].id

        XCTAssertEqual(coordinator.nextOCRCandidate(at: 0.4)?.id, candidateID)
        XCTAssertNil(coordinator.ingestOCR(
            [
                OCRObservation(text: "12", confidence: 0.95, timestamp: 0.3),
                OCRObservation(text: "BD", confidence: 0.95, timestamp: 0.4),
                OCRObservation(text: "34", confidence: 0.95, timestamp: 0.4)
            ],
            candidateID: candidateID,
            reservedAt: 0.4,
            anchorManager: manager
        ))

        XCTAssertTrue(manager.tracks[0].ocrEvidence.isEmpty)
        XCTAssertNil(
            coordinator.nextOCRCandidate(at: 0.4),
            "Invalid mixed-frame evidence must not silently release the active reservation"
        )
        coordinator.cancelOCR(candidateID: candidateID, reservedAt: 0.4)
    }

    func testStaleIngestAndCancelCannotReleaseNewerReservationForSameCandidate() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        let candidateID = establishCandidates(
            [quad],
            coordinator: coordinator,
            manager: manager,
            startingAt: 0
        )[0].id

        XCTAssertEqual(coordinator.nextOCRCandidate(at: 0.4)?.id, candidateID)
        coordinator.cancelOCR(candidateID: candidateID, reservedAt: 0.4)
        _ = coordinator.ingest(
            detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: 0.5)],
            depthGrid: depthGrid(),
            calibration: calibration(),
            anchorManager: manager,
            timestamp: 0.5
        )
        XCTAssertEqual(coordinator.nextOCRCandidate(at: 0.5)?.id, candidateID)

        XCTAssertNil(coordinator.ingestOCR(
            [OCRObservation(text: "12BD34", confidence: 0.95, timestamp: 0.4)],
            candidateID: candidateID,
            reservedAt: 0.4,
            anchorManager: manager
        ))
        coordinator.cancelOCR(candidateID: candidateID, reservedAt: 0.4)
        XCTAssertNil(
            coordinator.nextOCRCandidate(at: 0.5),
            "The stale completion must leave the 0.5 reservation in flight"
        )

        XCTAssertNil(coordinator.ingestOCR(
            [OCRObservation(text: "12BD34", confidence: 0.75, timestamp: 0.5)],
            candidateID: candidateID,
            reservedAt: 0.5,
            anchorManager: manager
        ))
        XCTAssertEqual(manager.tracks[0].ocrEvidence.count, 1)
    }

    func testUnreadableOCRUsesBoundedExponentialBackoff() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        let candidateID = establishCandidates(
            [quad],
            coordinator: coordinator,
            manager: manager,
            startingAt: 0
        )[0].id

        func ingestFrame(at timestamp: TimeInterval) {
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(),
                calibration: calibration(),
                anchorManager: manager,
                timestamp: timestamp
            )
        }
        func submitUnreadable(at timestamp: TimeInterval) {
            XCTAssertEqual(coordinator.nextOCRCandidate(at: timestamp)?.id, candidateID)
            XCTAssertNil(coordinator.ingestOCR(
                [OCRObservation(text: "NOT A PLATE", confidence: 0.95, timestamp: timestamp)],
                candidateID: candidateID,
                anchorManager: manager
            ))
        }

        ingestFrame(at: 0.5)
        submitUnreadable(at: 0.5)
        ingestFrame(at: 0.55)
        XCTAssertNil(coordinator.nextOCRCandidate(at: 0.55))
        ingestFrame(at: 0.6)
        submitUnreadable(at: 0.6)
        ingestFrame(at: 0.65)
        XCTAssertNil(coordinator.nextOCRCandidate(at: 0.65))
        ingestFrame(at: 0.7)
        submitUnreadable(at: 0.7)

        ingestFrame(at: 1.14)
        XCTAssertNil(coordinator.nextOCRCandidate(at: 1.14))
        ingestFrame(at: 1.15)
        submitUnreadable(at: 1.15)

        ingestFrame(at: 2.04)
        XCTAssertNil(coordinator.nextOCRCandidate(at: 2.04))
        ingestFrame(at: 2.05)
        submitUnreadable(at: 2.05)

        for timestamp in [2.8, 3.5, 3.84] {
            ingestFrame(at: timestamp)
            XCTAssertNil(coordinator.nextOCRCandidate(at: timestamp))
        }
        ingestFrame(at: 3.85)
        submitUnreadable(at: 3.85)

        for timestamp in [4.6, 5.4, 6.2, 7.0, 7.44] {
            ingestFrame(at: timestamp)
            XCTAssertNil(coordinator.nextOCRCandidate(at: timestamp))
        }
        ingestFrame(at: 7.45)
        XCTAssertEqual(coordinator.nextOCRCandidate(at: 7.45)?.id, candidateID)

        XCTAssertEqual(manager.tracks.count, 1)
        XCTAssertEqual(manager.tracks[0].cardState, .candidate)
    }

    func testConflictingPlausibleOCRStaysFastForConsensusThenThrottlesWithoutStopping() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        let candidateID = establishCandidates(
            [quad],
            coordinator: coordinator,
            manager: manager,
            startingAt: 0
        )[0].id
        func ingestFrame(at timestamp: TimeInterval) {
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(),
                calibration: calibration(),
                anchorManager: manager,
                timestamp: timestamp
            )
        }
        func submit(_ text: String, at timestamp: TimeInterval) {
            XCTAssertEqual(coordinator.nextOCRCandidate(at: timestamp)?.id, candidateID)
            XCTAssertNil(coordinator.ingestOCR(
                [OCRObservation(text: text, confidence: 0.95, timestamp: timestamp)],
                candidateID: candidateID,
                anchorManager: manager
            ))
        }

        for (index, text) in ["12BD10", "12BD11", "12BD12"].enumerated() {
            let timestamp = 0.5 + Double(index) * 0.1
            ingestFrame(at: timestamp)
            submit(text, at: timestamp)
        }

        for timestamp in [0.8, 1.0, 1.1] {
            ingestFrame(at: timestamp)
            XCTAssertNil(coordinator.nextOCRCandidate(at: timestamp))
        }
        ingestFrame(at: 1.2)
        submit("12BD13", at: 1.2)

        for timestamp in [1.4, 1.8, 2.1] {
            ingestFrame(at: timestamp)
            XCTAssertNil(coordinator.nextOCRCandidate(at: timestamp))
        }
        ingestFrame(at: 2.2)
        submit("12BD14", at: 2.2)

        for timestamp in [2.6, 3.0, 3.4, 3.8, 4.1] {
            ingestFrame(at: timestamp)
            XCTAssertNil(coordinator.nextOCRCandidate(at: timestamp))
        }
        ingestFrame(at: 4.2)
        submit("12BD15", at: 4.2)

        for timestamp in [4.6, 5.0, 5.4, 5.8, 6.1] {
            ingestFrame(at: timestamp)
            XCTAssertNil(coordinator.nextOCRCandidate(at: timestamp))
        }
        ingestFrame(at: 6.2)
        XCTAssertEqual(coordinator.nextOCRCandidate(at: 6.2)?.id, candidateID)
    }

    func testExpiredCandidateMetadataIsCleanedAndReobservationReassociatesWithoutDuplicate() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()

        let initialCandidates = establishCandidates(
            [quad],
            coordinator: coordinator,
            manager: manager,
            startingAt: 0
        )
        XCTAssertEqual(manager.tracks.count, 1)
        XCTAssertEqual(manager.tracks[0].cardState, .candidate)
        confirmPlate(for: initialCandidates[0].id, coordinator: coordinator, manager: manager, startingAt: 0.5)
        XCTAssertEqual(manager.tracks.count, 1)
        XCTAssertEqual(manager.tracks[0].cardState, .confirming)
        let originalCandidateID = initialCandidates[0].id
        let originalTrackID = manager.tracks[0].id
        XCTAssertEqual(coordinator.trackID(for: originalCandidateID), originalTrackID)

        _ = coordinator.ingest(
            detections: [],
            depthGrid: depthGrid(),
            calibration: calibration(),
            anchorManager: manager,
            timestamp: 1.7
        )
        XCTAssertNil(coordinator.trackID(for: originalCandidateID))
        XCTAssertNil(coordinator.nextOCRCandidate(at: 1.7), "Expired candidate metadata must not remain eligible for OCR")
        XCTAssertNil(coordinator.ingestOCR(
            [OCRObservation(text: "12BD34", confidence: 1, timestamp: 1.7)],
            candidateID: originalCandidateID,
            anchorManager: manager
        ))

        let reobserved = establishCandidates(
            [quad],
            coordinator: coordinator,
            manager: manager,
            startingAt: 1.8
        )
        XCTAssertEqual(manager.tracks.count, 1, "Reobserving a measured car must reuse its persistent world anchor")
        XCTAssertNotEqual(reobserved[0].id, originalCandidateID)
        XCTAssertEqual(coordinator.trackID(for: reobserved[0].id), originalTrackID)
    }

    func testDuplicatePlateCandidatesCreateOnlyOneAnchor() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let first = standardQuad()
        let overlapping = PlateQuadrilateral(
            topLeft: CGPoint(x: 0.2175, y: 0.62375), topRight: CGPoint(x: 0.8025, y: 0.62375),
            bottomRight: CGPoint(x: 0.8025, y: 0.37625), bottomLeft: CGPoint(x: 0.2175, y: 0.37625)
        )

        let candidates = establishCandidates(
            [first, overlapping],
            coordinator: coordinator,
            manager: manager,
            startingAt: 0
        )

        XCTAssertEqual(manager.tracks.count, 1, "Duplicate spatial candidates must converge on one provisional anchor")
        confirmPlate(for: candidates[0].id, coordinator: coordinator, manager: manager, startingAt: 0.5)
        let updatedCandidates = coordinator.ingest(
            detections: [
                PlateDetection(quadrilateral: first, confidence: 0.95, timestamp: 0.9),
                PlateDetection(quadrilateral: overlapping, confidence: 0.95, timestamp: 0.9)
            ],
            depthGrid: depthGrid(),
            calibration: calibration(),
            anchorManager: manager,
            timestamp: 0.9
        )
        XCTAssertEqual(manager.tracks.count, 1)
        XCTAssertEqual(candidates.filter { coordinator.trackID(for: $0.id) != nil }.count, 1)
        XCTAssertEqual(updatedCandidates.filter { $0.state == .rejected }.count, 1)
        XCTAssertNil(coordinator.nextOCRCandidate(at: 0.9), "The duplicate provisional candidate must not trigger redundant recognition")
    }

    func testOCRCandidateSelectionIsSerializedAndFairAcrossCars() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let left = PlateQuadrilateral(
            topLeft: CGPoint(x: 0.05, y: 0.555), topRight: CGPoint(x: 0.31, y: 0.555),
            bottomRight: CGPoint(x: 0.31, y: 0.445), bottomLeft: CGPoint(x: 0.05, y: 0.445)
        )
        let right = PlateQuadrilateral(
            topLeft: CGPoint(x: 0.69, y: 0.555), topRight: CGPoint(x: 0.95, y: 0.555),
            bottomRight: CGPoint(x: 0.95, y: 0.445), bottomLeft: CGPoint(x: 0.69, y: 0.445)
        )

        let candidates = establishCandidates(
            [right, left],
            coordinator: coordinator,
            manager: manager,
            startingAt: 0,
            calibration: wideCalibration(),
            depthGrid: depthGrid(depth: 1)
        )
        XCTAssertEqual(manager.tracks.count, 2, "Each independently stable car should have a provisional spatial anchor")
        let leftCandidate = candidates.min { $0.latestQuadrilateral!.topLeft.x < $1.latestQuadrilateral!.topLeft.x }!
        let rightCandidate = candidates.max { $0.latestQuadrilateral!.topLeft.x < $1.latestQuadrilateral!.topLeft.x }!

        XCTAssertEqual(coordinator.nextOCRCandidate(at: 0.4)?.id, leftCandidate.id)
        XCTAssertNil(coordinator.nextOCRCandidate(at: 0.4), "Only one expensive OCR request may be in flight")
        coordinator.cancelOCR(candidateID: leftCandidate.id)

        _ = coordinator.ingest(
            detections: [right, left].map { PlateDetection(quadrilateral: $0, confidence: 0.95, timestamp: 0.5) },
            depthGrid: depthGrid(depth: 1),
            calibration: wideCalibration(),
            anchorManager: manager,
            timestamp: 0.5
        )
        XCTAssertEqual(coordinator.nextOCRCandidate(at: 0.5)?.id, rightCandidate.id)
        coordinator.cancelOCR(candidateID: rightCandidate.id)
        _ = coordinator.ingest(
            detections: [right, left].map { PlateDetection(quadrilateral: $0, confidence: 0.95, timestamp: 0.6) },
            depthGrid: depthGrid(depth: 1),
            calibration: wideCalibration(),
            anchorManager: manager,
            timestamp: 0.6
        )
        XCTAssertEqual(coordinator.nextOCRCandidate(at: 0.6)?.id, leftCandidate.id)
    }

    func testMissingProductionMeshFallsBackToRepeatedDepthPose() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        for index in 0..<5 {
            let time = Double(index) * 0.1
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: time)],
                depthGrid: depthGrid(),
                calibration: calibration(),
                anchorManager: manager,
                timestamp: time,
                meshWorldPointsForQuadrilateral: { _ in [] }
            )
        }

        XCTAssertNotNil(coordinator.nextOCRCandidate(at: 0.4))
        XCTAssertEqual(manager.tracks.count, 1)
        XCTAssertEqual(manager.tracks[0].cardState, .candidate)
        XCTAssertEqual(coordinator.latestDiagnostics.maximumMeshSamples, 0)
        XCTAssertGreaterThanOrEqual(coordinator.latestDiagnostics.maximumDepthSamples, 3)
        XCTAssertEqual(coordinator.latestDiagnostics.acceptedPoseEstimates, 1)
        XCTAssertEqual(coordinator.latestDiagnostics.stableCandidates, 1)
        XCTAssertEqual(coordinator.latestDiagnostics.anchoredCandidates, 1)
        XCTAssertEqual(coordinator.latestDiagnostics.currentTargetCardState, .candidate)
    }

    func testAgreeingMeshCreatesSpatialAnchorBeforeRecognition() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        for index in 0..<5 {
            let time = Double(index) * 0.1
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: time)],
                depthGrid: depthGrid(),
                calibration: calibration(),
                anchorManager: manager,
                timestamp: time,
                meshWorldPointsForQuadrilateral: { self.agreeingMesh(for: $0, depth: 2) }
            )
        }

        XCTAssertNotNil(coordinator.nextOCRCandidate(at: 0.4))
        XCTAssertEqual(manager.tracks.count, 1)
        XCTAssertGreaterThanOrEqual(coordinator.latestDiagnostics.maximumMeshSamples, 3)
    }

    func testBroadMeshThatContradictsDepthCannotBeSilentlyBypassed() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        for index in 0..<5 {
            let timestamp = Double(index) * 0.1
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(depth: 2),
                calibration: calibration(),
                anchorManager: manager,
                timestamp: timestamp,
                meshWorldPointsForQuadrilateral: { self.agreeingMesh(for: $0, depth: 4) }
            )
        }

        XCTAssertTrue(manager.tracks.isEmpty)
        XCTAssertGreaterThanOrEqual(coordinator.latestDiagnostics.maximumMeshSamples, 3)
        XCTAssertEqual(coordinator.latestDiagnostics.acceptedPoseEstimates, 0)
    }

    func testMissingDetectionsCannotAccumulatePoseOrOCRAgainstNewerFrames() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        for index in 0..<3 {
            let time = Double(index) * 0.1
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: time)],
                depthGrid: depthGrid(),
                calibration: calibration(),
                anchorManager: manager,
                timestamp: time
            )
        }
        for time in [0.3, 0.4, 0.5] {
            _ = coordinator.ingest(
                detections: [],
                depthGrid: depthGrid(depth: 5),
                calibration: calibration(),
                anchorManager: manager,
                timestamp: time
            )
            XCTAssertNil(coordinator.nextOCRCandidate(at: time))
        }
        XCTAssertTrue(manager.tracks.isEmpty, "Fewer than three agreeing pose samples must never become permanent")
    }

    func testFiveConsecutiveDetectionsAcrossTimeCreateExactlyOneAnchor() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()

        for index in 0..<4 {
            let timestamp = Double(index) * 0.2
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(),
                calibration: calibration(),
                anchorManager: manager,
                timestamp: timestamp
            )
            XCTAssertTrue(manager.tracks.isEmpty)
        }

        _ = coordinator.ingest(
            detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: 0.8)],
            depthGrid: depthGrid(),
            calibration: calibration(),
            anchorManager: manager,
            timestamp: 0.8
        )
        XCTAssertEqual(manager.tracks.count, 1)

        for index in 5..<20 {
            let timestamp = Double(index) * 0.2
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(),
                calibration: calibration(),
                anchorManager: manager,
                timestamp: timestamp
            )
        }
        XCTAssertEqual(manager.tracks.count, 1, "A long observation of one car must keep one world anchor")
    }

    func testLimitedTrackingDepthCannotCreateAnchorUntilTwoRecentNormalPoses() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()

        for index in 0..<5 {
            let timestamp = Double(index) * 0.1
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(),
                calibration: calibration(),
                anchorManager: manager,
                timestamp: timestamp,
                trackingWasNormal: false
            )
        }
        XCTAssertTrue(manager.tracks.isEmpty)

        for (index, timestamp) in [0.5, 0.6].enumerated() {
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(),
                calibration: calibration(),
                anchorManager: manager,
                timestamp: timestamp,
                trackingWasNormal: true
            )
            XCTAssertEqual(manager.tracks.count, index)
        }
        XCTAssertEqual(manager.tracks.count, 1)
    }

    func testOldNormalPosesDoNotAuthorizeLaterLimitedTrackingAnchor() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        let frames: [(TimeInterval, Bool)] = [
            (0, true), (0.1, true), (0.2, true), (0.3, false), (0.8, false)
        ]

        for (timestamp, trackingWasNormal) in frames {
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(),
                calibration: calibration(),
                anchorManager: manager,
                timestamp: timestamp,
                trackingWasNormal: trackingWasNormal
            )
        }
        XCTAssertTrue(manager.tracks.isEmpty)

        _ = coordinator.ingest(
            detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: 0.9)],
            depthGrid: depthGrid(),
            calibration: calibration(),
            anchorManager: manager,
            timestamp: 0.9,
            trackingWasNormal: true
        )
        XCTAssertEqual(manager.tracks.count, 1)
    }

    func testInitialSpatialOutlierCannotPoisonLaterAgreeingEvidence() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        let timestamps: [TimeInterval] = [0, 0.2, 0.4, 0.6, 0.8]

        for (index, timestamp) in timestamps.enumerated() {
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(),
                calibration: calibration(cameraX: index == 1 ? 0.5 : 0),
                anchorManager: manager,
                timestamp: timestamp
            )
        }

        XCTAssertEqual(manager.tracks.count, 1)
        XCTAssertEqual(manager.tracks[0].stableTransform.columns.3.x, 0, accuracy: 0.1)
    }

    func testAlternatingSingleDetectionsCannotConvergeIntoMultipleAnchors() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let left = PlateQuadrilateral(
            topLeft: CGPoint(x: 0.05, y: 0.555), topRight: CGPoint(x: 0.31, y: 0.555),
            bottomRight: CGPoint(x: 0.31, y: 0.445), bottomLeft: CGPoint(x: 0.05, y: 0.445)
        )
        let right = PlateQuadrilateral(
            topLeft: CGPoint(x: 0.69, y: 0.555), topRight: CGPoint(x: 0.95, y: 0.555),
            bottomRight: CGPoint(x: 0.95, y: 0.445), bottomLeft: CGPoint(x: 0.69, y: 0.445)
        )

        for (index, quad) in [left, right, left, right, left, right, left, right].enumerated() {
            let timestamp = Double(index) * 0.1
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(depth: 1),
                calibration: wideCalibration(),
                anchorManager: manager,
                timestamp: timestamp
            )
        }

        XCTAssertTrue(manager.tracks.isEmpty, "Switching targets must reset convergence instead of maturing both")
    }

    func testExpiredSpatialCandidateReleasesOCRAndLeavesAnchorForReassociation() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        let initial = establishCandidates([quad], coordinator: coordinator, manager: manager, startingAt: 0)
        let expiredID = initial[0].id
        let persistentTrackID = manager.tracks[0].id
        XCTAssertEqual(coordinator.nextOCRCandidate(at: 0.4)?.id, expiredID)
        XCTAssertNil(coordinator.ingestOCR(
            [OCRObservation(text: "12BD34", confidence: 0.95, timestamp: 0.4)],
            candidateID: expiredID,
            anchorManager: manager
        ))
        _ = coordinator.ingest(
            detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: 0.6)],
            depthGrid: depthGrid(),
            calibration: calibration(),
            anchorManager: manager,
            timestamp: 0.6
        )
        XCTAssertEqual(coordinator.nextOCRCandidate(at: 0.6)?.id, expiredID)

        _ = coordinator.ingest(
            detections: [],
            depthGrid: depthGrid(),
            calibration: calibration(),
            anchorManager: manager,
            timestamp: 1.6
        )
        XCTAssertNil(coordinator.trackID(for: expiredID))
        XCTAssertEqual(manager.tracks.count, 1, "Losing the plate from view must preserve its measured world anchor")
        XCTAssertEqual(manager.tracks[0].id, persistentTrackID)
        XCTAssertNil(coordinator.ingestOCR(
            [OCRObservation(text: "12BD34", confidence: 0.95, timestamp: 1.6)],
            candidateID: expiredID,
            anchorManager: manager
        ))

        let replacement = establishCandidates([quad], coordinator: coordinator, manager: manager, startingAt: 1.7)
        XCTAssertNotEqual(replacement[0].id, expiredID)
        XCTAssertEqual(coordinator.nextOCRCandidate(at: 2.1)?.id, replacement[0].id)
        XCTAssertEqual(manager.tracks.count, 1, "Reobservation must reuse the persistent world anchor")
        XCTAssertEqual(manager.tracks[0].id, persistentTrackID)
        XCTAssertEqual(coordinator.trackID(for: replacement[0].id), persistentTrackID)
    }

    func testReobservationWithModerateDepthOffsetStillReusesSameCarAnchor() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        let initial = establishCandidates([quad], coordinator: coordinator, manager: manager, startingAt: 0)
        let originalTrackID = manager.tracks[0].id

        _ = coordinator.ingest(
            detections: [],
            depthGrid: depthGrid(),
            calibration: calibration(),
            anchorManager: manager,
            timestamp: 1.5
        )
        XCTAssertNil(coordinator.trackID(for: initial[0].id))

        let replacement = establishCandidates(
            [quad],
            coordinator: coordinator,
            manager: manager,
            startingAt: 1.6,
            calibration: calibration(cameraX: 0.4)
        )

        XCTAssertEqual(manager.tracks.count, 1)
        XCTAssertEqual(manager.tracks[0].id, originalTrackID)
        XCTAssertEqual(coordinator.trackID(for: replacement[0].id), originalTrackID)
    }

    func testConfirmedCenteredCandidateCannotBlockRetargetingToSecondCar() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        let first = establishCandidates([quad], coordinator: coordinator, manager: manager, startingAt: 0)
        confirmPlate(for: first[0].id, coordinator: coordinator, manager: manager, startingAt: 0.5)
        XCTAssertEqual(manager.tracks.count, 1)

        // A second car can enter the camera view. Continued spatial
        // monitoring rejects the old screen candidate without deleting its anchor.
        for timestamp in [0.8, 1.0, 1.2] {
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(),
                calibration: calibration(cameraX: 2),
                anchorManager: manager,
                timestamp: timestamp
            )
        }

        for timestamp in [1.4, 1.6, 1.8, 2.0, 2.2] {
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(),
                calibration: calibration(cameraX: 2),
                anchorManager: manager,
                timestamp: timestamp
            )
        }

        XCTAssertEqual(manager.tracks.count, 2)
    }

    func testDeliberatelyRemovedAnchorIsNotImmediatelyRecreatedFromItsLiveCandidate() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        let candidates = establishCandidates([quad], coordinator: coordinator, manager: manager, startingAt: 0)
        confirmPlate(for: candidates[0].id, coordinator: coordinator, manager: manager, startingAt: 0.5)
        let trackID = manager.tracks[0].id
        manager.remove(trackID: trackID)

        let updated = coordinator.ingest(
            detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: 0.9)],
            depthGrid: depthGrid(),
            calibration: calibration(),
            anchorManager: manager,
            timestamp: 0.9
        )

        XCTAssertTrue(manager.tracks.isEmpty)
        XCTAssertEqual(updated.first?.state, .rejected)
        XCTAssertNil(coordinator.nextOCRCandidate(at: 0.9))
    }

    func testRepeatedConflictAfterSpatialConvergenceRejectsCandidateButFreezesAnchor() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        let candidates = establishCandidates(
            [quad],
            coordinator: coordinator,
            manager: manager,
            startingAt: 0
        )
        let candidateID = candidates[0].id
        let establishedTrackID = manager.tracks[0].id
        XCTAssertEqual(coordinator.nextOCRCandidate(at: 0.4)?.id, candidateID)
        coordinator.cancelOCR(candidateID: candidateID)

        var updated: [PlateCandidate] = []
        for timestamp in [0.5, 0.6, 0.7] {
            updated = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(),
                calibration: calibration(cameraX: 0.3),
                anchorManager: manager,
                timestamp: timestamp
            )
            if timestamp < 0.7 {
                XCTAssertFalse(manager.tracks.isEmpty, "One noisy spatial estimate must not erase a stable anchor")
            }
        }

        XCTAssertEqual(updated.first(where: { $0.id == candidateID })?.state, .rejected)
        XCTAssertNil(coordinator.nextOCRCandidate(at: 0.7))
        XCTAssertEqual(manager.tracks.count, 1, "Later conflicting input must not erase an established world anchor")
        XCTAssertEqual(manager.tracks[0].id, establishedTrackID)
    }

    func testGradualSubthresholdMotionCannotAccumulateOCRAndCreateAnchor() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let quad = standardQuad()
        var candidates = establishCandidates([quad], coordinator: coordinator, manager: manager, startingAt: 0)
        let candidateID = candidates[0].id
        let establishedTrackID = manager.tracks[0].id
        XCTAssertEqual(coordinator.nextOCRCandidate(at: 0.4)?.id, candidateID)
        XCTAssertNil(coordinator.ingestOCR(
            [OCRObservation(text: "12BD34", confidence: 0.95, timestamp: 0.4)],
            candidateID: candidateID,
            anchorManager: manager
        ))

        candidates = coordinator.ingest(
            detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: 0.5)],
            depthGrid: depthGrid(),
            calibration: calibration(cameraX: 0.095),
            anchorManager: manager,
            timestamp: 0.5
        )
        XCTAssertNotEqual(candidates[0].state, .rejected)
        XCTAssertEqual(coordinator.nextOCRCandidate(at: 0.5)?.id, candidateID)
        XCTAssertNil(coordinator.ingestOCR(
            [OCRObservation(text: "12BD34", confidence: 0.95, timestamp: 0.5)],
            candidateID: candidateID,
            anchorManager: manager
        ))

        for timestamp in [0.6, 0.7, 0.8] {
            candidates = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(),
                calibration: calibration(cameraX: 0.19),
                anchorManager: manager,
                timestamp: timestamp
            )
        }
        XCTAssertEqual(candidates[0].state, .rejected)
        XCTAssertNil(coordinator.nextOCRCandidate(at: 0.8))
        XCTAssertNil(coordinator.ingestOCR(
            [OCRObservation(text: "12BD34", confidence: 0.95, timestamp: 0.8)],
            candidateID: candidateID,
            anchorManager: manager
        ))
        XCTAssertEqual(manager.tracks.count, 1, "A converged anchor must stay frozen after later candidate rejection")
        XCTAssertEqual(manager.tracks[0].id, establishedTrackID)
    }

    func testCameraTranslationAroundStationaryPlatePreservesWorldStationarityAndAllowsAnchor() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        var candidates: [PlateCandidate] = []
        let cameraPositions: [Float] = [0, 0.03, 0.06, 0.09, 0.12]

        for (index, cameraX) in cameraPositions.enumerated() {
            let timestamp = Double(index) * 0.1
            let quad = stationaryPlateQuad(cameraX: cameraX)
            candidates = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(),
                calibration: calibration(cameraX: cameraX),
                anchorManager: manager,
                timestamp: timestamp
            )
        }

        let candidateID = candidates[0].id
        XCTAssertNotEqual(candidates[0].state, .rejected)
        confirmPlate(
            for: candidateID,
            coordinator: coordinator,
            manager: manager,
            startingAt: 0.5,
            quadrilateral: stationaryPlateQuad(cameraX: 0.12),
            calibration: calibration(cameraX: 0.12)
        )
        XCTAssertEqual(manager.tracks.count, 1)
        XCTAssertEqual(manager.tracks[0].stableTransform.columns.3.x, 0, accuracy: 0.1)
    }

    private func confirmPlate(
        for candidateID: UUID,
        coordinator: AutomaticVehicleCoordinator,
        manager: AnchorManager,
        startingAt start: TimeInterval,
        quadrilateral: PlateQuadrilateral? = nil,
        calibration: CameraCalibration? = nil
    ) {
        let quadrilateral = quadrilateral ?? standardQuad()
        for index in 0..<3 {
            let timestamp = start + Double(index) * 0.1
            _ = coordinator.ingest(
                detections: [PlateDetection(quadrilateral: quadrilateral, confidence: 0.95, timestamp: timestamp)],
                depthGrid: depthGrid(),
                calibration: calibration ?? self.calibration(),
                anchorManager: manager,
                timestamp: timestamp
            )
            XCTAssertEqual(coordinator.nextOCRCandidate(at: timestamp)?.id, candidateID)
            _ = coordinator.ingestOCR(
                [OCRObservation(text: "12BD34", confidence: 0.95, timestamp: timestamp)],
                candidateID: candidateID,
                anchorManager: manager
            )
        }
    }

    private func establishCandidates(
        _ quadrilaterals: [PlateQuadrilateral],
        coordinator: AutomaticVehicleCoordinator,
        manager: AnchorManager,
        startingAt start: TimeInterval,
        calibration: CameraCalibration? = nil,
        depthGrid: DepthGrid? = nil
    ) -> [PlateCandidate] {
        var candidates: [PlateCandidate] = []
        for index in 0..<5 {
            let time = start + Double(index) * 0.1
            let detections = quadrilaterals.map {
                PlateDetection(quadrilateral: $0, confidence: 0.95, timestamp: time)
            }
            candidates = coordinator.ingest(
                detections: detections,
                depthGrid: depthGrid ?? self.depthGrid(),
                calibration: calibration ?? self.calibration(),
                anchorManager: manager,
                timestamp: time
            )
        }
        return candidates
    }

    private func standardQuad() -> PlateQuadrilateral {
        PlateQuadrilateral(
            topLeft: CGPoint(x: 0.2075, y: 0.62375), topRight: CGPoint(x: 0.7925, y: 0.62375),
            bottomRight: CGPoint(x: 0.7925, y: 0.37625), bottomLeft: CGPoint(x: 0.2075, y: 0.37625)
        )
    }

    private func stationaryPlateQuad(cameraX: Float) -> PlateQuadrilateral {
        let horizontalImageShift = CGFloat(-cameraX * 900 / 2 / 400)
        let quad = standardQuad()
        return PlateQuadrilateral(
            topLeft: CGPoint(x: quad.topLeft.x + horizontalImageShift, y: quad.topLeft.y),
            topRight: CGPoint(x: quad.topRight.x + horizontalImageShift, y: quad.topRight.y),
            bottomRight: CGPoint(x: quad.bottomRight.x + horizontalImageShift, y: quad.bottomRight.y),
            bottomLeft: CGPoint(x: quad.bottomLeft.x + horizontalImageShift, y: quad.bottomLeft.y)
        )
    }

    private func calibration(cameraX: Float = 0) -> CameraCalibration {
        var cameraToWorld = matrix_identity_float4x4
        cameraToWorld.columns.3.x = cameraX
        return CameraCalibration(
            intrinsics: simd_float3x3(SIMD3(900, 0, 0), SIMD3(0, 900, 0), SIMD3(200, 100, 1)),
            cameraToWorld: cameraToWorld,
            imageSize: SIMD2(400, 200)
        )
    }

    private func wideCalibration() -> CameraCalibration {
        CameraCalibration(
            intrinsics: simd_float3x3(SIMD3(200, 0, 0), SIMD3(0, 200, 0), SIMD3(200, 100, 1)),
            cameraToWorld: matrix_identity_float4x4,
            imageSize: SIMD2(400, 200)
        )
    }

    private func depthGrid(depth: Float = 2) -> DepthGrid {
        DepthGrid(
            width: 4,
            height: 4,
            depths: Array(repeating: depth, count: 16),
            confidences: Array(repeating: 2, count: 16)
        )
    }

    private func agreeingMesh(for quad: PlateQuadrilateral, depth: Float) -> [MeshSample] {
        func interpolate(_ first: CGPoint, _ second: CGPoint, _ amount: CGFloat) -> CGPoint {
            CGPoint(
                x: first.x + (second.x - first.x) * amount,
                y: first.y + (second.y - first.y) * amount
            )
        }
        let center = interpolate(
            interpolate(quad.topLeft, quad.bottomLeft, 0.5),
            interpolate(quad.topRight, quad.bottomRight, 0.5),
            0.5
        )
        return [
            MeshSample(imagePoint: center, worldPoint: SIMD3(0, 0, -depth)),
            MeshSample(imagePoint: interpolate(quad.topLeft, quad.topRight, 0.3), worldPoint: SIMD3(-0.08, 0.04, -depth)),
            MeshSample(imagePoint: interpolate(quad.topLeft, quad.topRight, 0.7), worldPoint: SIMD3(0.08, 0.04, -depth)),
            MeshSample(imagePoint: interpolate(quad.bottomLeft, quad.bottomRight, 0.7), worldPoint: SIMD3(0.08, -0.04, -depth)),
            MeshSample(imagePoint: interpolate(quad.bottomLeft, quad.bottomRight, 0.3), worldPoint: SIMD3(-0.08, -0.04, -depth))
        ]
    }
}

private struct RDWMock: RDWClientProtocol {
    func vehicle(for plate: DutchLicensePlate) async -> RDWLookupResult {
        .found(RDWVehicle(
            kenteken: plate.canonical,
            merk: "VOLVO",
            handelsbenaming: "XC40",
            voertuigsoort: "Personenauto",
            eersteKleur: "BLAUW",
            tweedeKleur: nil,
            datumEersteToelating: "20220314",
            catalogusprijs: nil,
            aantalCilinders: nil,
            cilinderinhoud: nil,
            massaLedigVoertuig: nil,
            massaRijklaar: nil,
            toegestaneMaximumMassaVoertuig: nil
        ))
    }
}
