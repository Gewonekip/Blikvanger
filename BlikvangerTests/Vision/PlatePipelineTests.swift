import ImageIO
import simd
import XCTest
@testable import Blikvanger

final class PlatePipelineTests: XCTestCase {
    private let quad = PlateQuadrilateral(
        topLeft: CGPoint(x: 0.2, y: 0.6), topRight: CGPoint(x: 0.8, y: 0.6),
        bottomRight: CGPoint(x: 0.8, y: 0.4), bottomLeft: CGPoint(x: 0.2, y: 0.4)
    )

    func testPlateAspectFilteringUsesOrientedPixelsForPortraitCameraFrames() throws {
        let geometry = PlateDetectionGeometry()
        let rawLandscapeSize = CGSize(width: 1_920, height: 1_440)
        let orientedPortraitSize = geometry.orientedPixelSize(
            rawPixelSize: rawLandscapeSize,
            orientation: .right
        )
        XCTAssertEqual(orientedPortraitSize, CGSize(width: 1_440, height: 1_920))

        let legalSizes: [(width: CGFloat, height: CGFloat)] = [
            (520, 110), // Standard one-line plate
            (310, 110), // Compact one-line plate
            (340, 210)  // Two-line plate
        ]
        for size in legalSizes {
            let box = CGRect(
                x: 0.2,
                y: 0.4,
                width: size.width / orientedPortraitSize.width,
                height: size.height / orientedPortraitSize.height
            )
            XCTAssertTrue(geometry.accepts(
                normalizedBoundingBox: box,
                rawPixelSize: rawLandscapeSize,
                orientation: .right
            ), "Expected \(size.width)x\(size.height) plate to pass")
            XCTAssertEqual(
                try XCTUnwrap(geometry.pixelAspectRatio(
                    of: box,
                    rawPixelSize: rawLandscapeSize,
                    orientation: .right
                )),
                size.width / size.height,
                accuracy: 0.000_001
            )
        }
    }

    func testStandardPortraitPlateWouldFailTheOldNormalizedRatioCheck() {
        let rawLandscapeSize = CGSize(width: 1_920, height: 1_440)
        let orientedPortraitSize = CGSize(width: 1_440, height: 1_920)
        let standardPlate = CGRect(
            x: 0.2,
            y: 0.4,
            width: 520 / orientedPortraitSize.width,
            height: 110 / orientedPortraitSize.height
        )

        XCTAssertGreaterThan(standardPlate.width / standardPlate.height, 6.2)
        XCTAssertTrue(PlateDetectionGeometry().accepts(
            normalizedBoundingBox: standardPlate,
            rawPixelSize: rawLandscapeSize,
            orientation: .right
        ))
    }

    func testMeaningfullyNestedPlateAndHolderRectanglesBothReachAppearanceStage() {
        let outer = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.2, y: 0.45, width: 0.4, height: 0.1125)),
            confidence: 0.9,
            timestamp: 1
        )
        let inner = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.22, y: 0.46, width: 0.36, height: 0.09)),
            confidence: 0.9,
            timestamp: 1
        )

        let filtered = PlateDetectionGeometry().filterAndSuppress(
            [outer, inner],
            rawPixelSize: CGSize(width: 1_920, height: 1_440),
            orientation: .right
        )

        XCTAssertEqual(filtered, [outer, inner])
    }

    func testNearEqualDuplicateRectanglesAreSuppressedDeterministically() {
        let first = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.2, y: 0.45, width: 0.4, height: 0.1125)),
            confidence: 0.9,
            timestamp: 1
        )
        let duplicate = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.205, y: 0.452, width: 0.395, height: 0.11)),
            confidence: 0.85,
            timestamp: 1
        )

        let filtered = PlateDetectionGeometry().filterAndSuppress(
            [first, duplicate],
            rawPixelSize: CGSize(width: 1_920, height: 1_440),
            orientation: .right
        )

        XCTAssertEqual(filtered, [first])
    }

    func testModeratelyDifferentHolderEdgeSurvivesForAppearanceScoring() {
        let holder = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.2, y: 0.45, width: 0.4, height: 0.1125)),
            confidence: 0.95,
            timestamp: 1
        )
        let yellowBoundary = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.21, y: 0.454, width: 0.38, height: 0.105)),
            confidence: 0.82,
            timestamp: 1
        )

        let filtered = PlateDetectionGeometry().filterAndSuppress(
            [holder, yellowBoundary],
            rawPixelSize: CGSize(width: 1_920, height: 1_440),
            orientation: .right
        )

        XCTAssertEqual(filtered, [holder, yellowBoundary])
    }

    func testDetectionWorkerUsesPlateEvidenceWithoutCenterBias() async throws {
        let centeredPlate = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.185, y: 0.45, width: 0.63, height: 0.10)),
            confidence: 0.82,
            timestamp: 1
        )
        let offCenterPlate = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.01, y: 0.45, width: 0.63, height: 0.10)),
            confidence: 0.99,
            timestamp: 1
        )
        let centeredNonPlate = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.30, y: 0.40, width: 0.40, height: 0.20)),
            confidence: 0.99,
            timestamp: 1
        )
        let worker = plateDetectionWorker(
            detections: [offCenterPlate, centeredNonPlate, centeredPlate]
        )

        let selected = await worker.detect(snapshot: try snapshot(timestamp: 1))

        XCTAssertEqual(selected.count, 1, "One camera frame must not seed several car tracks")
        XCTAssertEqual(
            selected[0].quadrilateral,
            ImageCoordinateMapper().visionQuadrilateralToRaw(offCenterPlate.quadrilateral, orientation: .right)
        )
    }

    func testDetectionWorkerEmitsNoCandidateWhenDetectorFindsNothing() async throws {
        let worker = plateDetectionWorker(detections: [])

        let selected = await worker.detect(snapshot: try snapshot(timestamp: 1))

        XCTAssertTrue(selected.isEmpty)
    }

    func testDetectionWorkerRejectsIllegalAspectAndOutOfBoundsRectangles() async throws {
        let illegalAspect = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)),
            confidence: 0.99,
            timestamp: 1
        )
        let outsideImage = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.82, y: 0.62, width: 0.315, height: 0.05)),
            confidence: 0.99,
            timestamp: 1
        )
        let worker = plateDetectionWorker(detections: [illegalAspect, outsideImage])

        let selected = await worker.detect(snapshot: try snapshot(timestamp: 1))

        XCTAssertTrue(selected.isEmpty)
    }

    func testDetectionWorkerAcceptsVisiblePlateOutsideFormerAimGuide() async throws {
        let visiblePlate = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.615, y: 0.645, width: 0.190, height: 0.030)),
            confidence: 0.70,
            timestamp: 1
        )
        let worker = plateDetectionWorker(detections: [visiblePlate])

        let selected = await worker.detect(snapshot: try snapshot(timestamp: 1))

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(
            selected[0].quadrilateral,
            ImageCoordinateMapper().visionQuadrilateralToRaw(
                visiblePlate.quadrilateral,
                orientation: .right
            )
        )
    }

    func testNinthLegalCandidateStillReachesAppearanceScoring() async throws {
        let detections = (0..<9).map { index in
            PlateDetection(
                quadrilateral: quadrilateral(for: CGRect(
                    x: 0.03 + CGFloat(index % 3) * 0.31,
                    y: 0.18 + CGFloat(index / 3) * 0.25,
                    width: 0.19,
                    height: 0.03
                )),
                confidence: 0.95 - Float(index) * 0.02,
                timestamp: 1
            )
        }
        let worker = PlateDetectionWorker(
            detector: StubPlateDetector(detections: detections),
            textLocalizer: EmptyPlateTextLocalizer(),
            appearanceScorer: NthPlausibleAppearanceScorer(plausibleCall: 9)
        )

        let selected = await worker.detect(snapshot: try snapshot(timestamp: 1))

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(
            selected[0].quadrilateral,
            ImageCoordinateMapper().visionQuadrilateralToRaw(
                detections[8].quadrilateral,
                orientation: .right
            )
        )
    }

    func testTextLocalizationFallbackSeedsReadablePlateWithoutRectangleProposal() async throws {
        let localized = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.615, y: 0.645, width: 0.190, height: 0.030)),
            confidence: 0.82,
            timestamp: 1
        )
        let worker = PlateDetectionWorker(
            detector: StubPlateDetector(detections: []),
            textLocalizer: StubPlateTextLocalizer(detections: [localized]),
            appearanceScorer: AlwaysPlausibleAppearanceScorer()
        )

        let selected = await worker.detect(snapshot: try snapshot(timestamp: 1))

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(
            selected[0].quadrilateral,
            ImageCoordinateMapper().visionQuadrilateralToRaw(localized.quadrilateral, orientation: .right)
        )
    }

    func testTextLocalizationExpansionIncludesPlateFieldAndClipsToImage() throws {
        let geometry = PlateTextLocalizationGeometry()
        let photoText = try XCTUnwrap(geometry.expandedPlateBox(
            around: CGRect(x: 0.621, y: 0.653, width: 0.180, height: 0.022)
        ))
        let edgeText = try XCTUnwrap(geometry.expandedPlateBox(
            around: CGRect(x: 0.92, y: 0.96, width: 0.08, height: 0.035)
        ))

        XCTAssertLessThan(photoText.minX, 0.621)
        XCTAssertGreaterThan(photoText.maxX, 0.801)
        XCTAssertLessThan(photoText.minY, 0.653)
        XCTAssertGreaterThan(photoText.maxY, 0.675)
        XCTAssertEqual(edgeText.maxX, 1, accuracy: 0.000_001)
        XCTAssertEqual(edgeText.maxY, 1, accuracy: 0.000_001)
    }

    func testDetectionWorkerTieBreakDoesNotDependOnVisionResultOrder() async throws {
        let left = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.1225, y: 0.475, width: 0.315, height: 0.05)),
            confidence: 0.9,
            timestamp: 1
        )
        let right = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.5625, y: 0.475, width: 0.315, height: 0.05)),
            confidence: 0.9,
            timestamp: 1
        )
        let firstWorker = plateDetectionWorker(detections: [left, right])
        let reversedWorker = plateDetectionWorker(detections: [right, left])

        let first = await firstWorker.detect(snapshot: try snapshot(timestamp: 1))
        let reversed = await reversedWorker.detect(snapshot: try snapshot(timestamp: 1))

        XCTAssertEqual(first, reversed)
        XCTAssertEqual(first.count, 1)
    }

    func testDetectionWorkerKeepsOverlappingTargetUntilGenerationReset() async throws {
        let firstA = quadrilateral(for: CGRect(x: 0.185, y: 0.45, width: 0.63, height: 0.10))
        let continuedA = quadrilateral(for: CGRect(x: 0.195, y: 0.45, width: 0.63, height: 0.10))
        let challengerB = quadrilateral(for: CGRect(x: 0.22, y: 0.455, width: 0.56, height: 0.09))
        let detector = SequencedPlateDetector(frames: [
            [(firstA, 0.95), (challengerB, 0.80)],
            [(continuedA, 0.72), (challengerB, 0.99)],
            [(continuedA, 0.72), (challengerB, 0.99)]
        ])
        let worker = PlateDetectionWorker(
            detector: detector,
            appearanceScorer: AlwaysPlausibleAppearanceScorer()
        )

        _ = await worker.detect(snapshot: try snapshot(timestamp: 1, generation: 1))
        let continued = await worker.detect(snapshot: try snapshot(timestamp: 1.2, generation: 1))
        let reset = await worker.detect(snapshot: try snapshot(timestamp: 1.4, generation: 2))

        XCTAssertEqual(
            continued[0].quadrilateral,
            ImageCoordinateMapper().visionQuadrilateralToRaw(continuedA, orientation: .right)
        )
        XCTAssertEqual(
            reset[0].quadrilateral,
            ImageCoordinateMapper().visionQuadrilateralToRaw(challengerB, orientation: .right)
        )
    }

    private func quadrilateral(for rectangle: CGRect) -> PlateQuadrilateral {
        PlateQuadrilateral(
            topLeft: CGPoint(x: rectangle.minX, y: rectangle.maxY),
            topRight: CGPoint(x: rectangle.maxX, y: rectangle.maxY),
            bottomRight: CGPoint(x: rectangle.maxX, y: rectangle.minY),
            bottomLeft: CGPoint(x: rectangle.minX, y: rectangle.minY)
        )
    }

    private func snapshot(timestamp: TimeInterval, generation: UInt64 = 1) throws -> ARFrameSnapshot {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 400,
            height: 300,
            bitsPerComponent: 8,
            bytesPerRow: 400 * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        let image = try XCTUnwrap(context.makeImage())
        return ARFrameSnapshot(
            image: image,
            depthGrid: DepthGrid(
                width: 2,
                height: 2,
                depths: Array(repeating: 2, count: 4),
                confidences: Array(repeating: 2, count: 4)
            ),
            calibration: CameraCalibration(
                intrinsics: matrix_identity_float3x3,
                cameraToWorld: matrix_identity_float4x4,
                imageSize: SIMD2(400, 300)
            ),
            timestamp: timestamp,
            visionOrientation: .right,
            generation: generation,
            droppedFrames: 0
        )
    }

    private func plateDetectionWorker(detections: [PlateDetection]) -> PlateDetectionWorker {
        PlateDetectionWorker(
            detector: StubPlateDetector(detections: detections),
            textLocalizer: EmptyPlateTextLocalizer(),
            appearanceScorer: AlwaysPlausibleAppearanceScorer()
        )
    }

    func testTrackerPreservesIdentityRejectsOneFrameAndExpiresCandidate() {
        var tracker = PlateTracker()
        let first = tracker.ingest([PlateDetection(quadrilateral: quad, confidence: 0.9, timestamp: 0)], timestamp: 0)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].state, .detected)
        let id = first[0].id

        _ = tracker.ingest([PlateDetection(quadrilateral: quad, confidence: 0.9, timestamp: 0.1)], timestamp: 0.1)
        let third = tracker.ingest([PlateDetection(quadrilateral: quad, confidence: 0.9, timestamp: 0.2)], timestamp: 0.2)
        XCTAssertEqual(third[0].id, id)
        XCTAssertEqual(third[0].state, .spatiallyEstimating)

        XCTAssertTrue(tracker.ingest([], timestamp: 1.2).isEmpty)
        XCTAssertEqual(tracker.expiredCandidateIDs, Set([id]))
    }

    func testTrackerDoesNotCountRepeatedAnalysisOfTheSameFrame() {
        var tracker = PlateTracker()
        let detection = PlateDetection(quadrilateral: quad, confidence: 0.9, timestamp: 1)

        _ = tracker.ingest([detection], timestamp: 1)
        let repeated = tracker.ingest([detection], timestamp: 1)

        XCTAssertEqual(repeated[0].observationCount, 1)
        XCTAssertEqual(repeated[0].consecutiveObservationCount, 1)
        XCTAssertEqual(repeated[0].state, .detected)
    }

    func testTrackerToleratesTwoEmptyFramesThenResetsAfterThirdMiss() {
        var tracker = PlateTracker()
        let first = tracker.ingest(
            [PlateDetection(quadrilateral: quad, confidence: 0.9, timestamp: 0)],
            timestamp: 0
        )[0]
        _ = tracker.ingest(
            [PlateDetection(quadrilateral: quad, confidence: 0.9, timestamp: 0.1)],
            timestamp: 0.1
        )
        tracker.addPose(
            PoseSample(worldTransform: matrix_identity_float4x4, confidence: 1, timestamp: 0.1),
            to: first.id
        )

        let firstMiss = tracker.ingest([], timestamp: 0.2)

        XCTAssertEqual(firstMiss[0].observationCount, 2)
        XCTAssertEqual(firstMiss[0].consecutiveObservationCount, 2)
        XCTAssertEqual(firstMiss[0].missedObservationCount, 1)
        XCTAssertEqual(firstMiss[0].poseSamples.count, 1)

        let secondMiss = tracker.ingest([], timestamp: 0.3)
        XCTAssertEqual(secondMiss[0].consecutiveObservationCount, 2)
        XCTAssertEqual(secondMiss[0].missedObservationCount, 2)
        XCTAssertEqual(secondMiss[0].poseSamples.count, 1)

        let thirdMiss = tracker.ingest([], timestamp: 0.4)
        XCTAssertEqual(thirdMiss[0].consecutiveObservationCount, 0)
        XCTAssertEqual(thirdMiss[0].missedObservationCount, 3)
        XCTAssertTrue(thirdMiss[0].poseSamples.isEmpty)
        XCTAssertEqual(thirdMiss[0].state, .detected)
    }

    func testTrackerReacquiresSmallMotionAfterOneEmptyFrame() {
        var tracker = PlateTracker()
        let first = tracker.ingest(
            [PlateDetection(quadrilateral: quad, confidence: 0.9, timestamp: 0)],
            timestamp: 0
        )[0]
        _ = tracker.ingest([], timestamp: 0.1)
        let moved = PlateQuadrilateral(
            topLeft: CGPoint(x: 0.24, y: 0.6), topRight: CGPoint(x: 0.84, y: 0.6),
            bottomRight: CGPoint(x: 0.84, y: 0.4), bottomLeft: CGPoint(x: 0.24, y: 0.4)
        )

        let reacquired = tracker.ingest(
            [PlateDetection(quadrilateral: moved, confidence: 0.9, timestamp: 0.2)],
            timestamp: 0.2
        )

        XCTAssertEqual(reacquired.count, 1)
        XCTAssertEqual(reacquired[0].id, first.id)
        XCTAssertEqual(reacquired[0].consecutiveObservationCount, 2)
        XCTAssertEqual(reacquired[0].missedObservationCount, 0)
    }

    @MainActor
    func testCoordinatorRejectsDetectionsStampedForAnotherFrame() {
        let manager = AnchorManager()
        let coordinator = AutomaticVehicleCoordinator()
        let calibration = CameraCalibration(
            intrinsics: simd_float3x3(
                SIMD3(900, 0, 0),
                SIMD3(0, 900, 0),
                SIMD3(200, 100, 1)
            ),
            cameraToWorld: matrix_identity_float4x4,
            imageSize: SIMD2(400, 200)
        )
        let depth = DepthGrid(
            width: 4,
            height: 4,
            depths: Array(repeating: 2, count: 16),
            confidences: Array(repeating: 2, count: 16)
        )
        let original = PlateDetection(quadrilateral: quad, confidence: 0.95, timestamp: 0)
        _ = coordinator.ingest(
            detections: [original],
            depthGrid: depth,
            calibration: calibration,
            anchorManager: manager,
            timestamp: 0
        )

        var candidates: [PlateCandidate] = []
        for timestamp in [0.1, 0.2, 0.3, 0.4] {
            candidates = coordinator.ingest(
                detections: [original],
                depthGrid: depth,
                calibration: calibration,
                anchorManager: manager,
                timestamp: timestamp
            )
        }

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].observationCount, 1)
        XCTAssertEqual(candidates[0].lastSeen, 0, accuracy: 0.000_001)
        XCTAssertTrue(candidates[0].poseSamples.isEmpty)
        XCTAssertNil(coordinator.nextOCRCandidate(at: 0.4))
        XCTAssertTrue(manager.tracks.isEmpty)
    }

    func testTrackerBoundsCandidateAndPerCandidateHistory() {
        var tracker = PlateTracker()
        tracker.maximumCandidates = 2
        let detections = [0.05, 0.4, 0.75].map { x in
            PlateDetection(
                quadrilateral: PlateQuadrilateral(
                    topLeft: CGPoint(x: x, y: 0.6), topRight: CGPoint(x: x + 0.2, y: 0.6),
                    bottomRight: CGPoint(x: x + 0.2, y: 0.4), bottomLeft: CGPoint(x: x, y: 0.4)
                ),
                confidence: 0.9,
                timestamp: 0
            )
        }
        let capped = tracker.ingest(detections, timestamp: 0)
        XCTAssertEqual(capped.count, 2)
        XCTAssertEqual(tracker.evictedCandidateIDs.count, 1)

        tracker.maximumCandidates = 24
        let trackedDetection = PlateDetection(quadrilateral: capped[0].latestQuadrilateral!, confidence: 0.9, timestamp: 0)
        for index in 1...20 {
            let time = Double(index) * 0.02
            _ = tracker.ingest(
                [PlateDetection(quadrilateral: trackedDetection.quadrilateral, confidence: 0.9, timestamp: time)],
                timestamp: time
            )
            tracker.addPose(
                PoseSample(worldTransform: matrix_identity_float4x4, confidence: 1, timestamp: time),
                to: capped[0].id
            )
        }
        let bounded = tracker.candidate(id: capped[0].id)
        XCTAssertEqual(bounded?.quadrilateralHistory.count, 12)
        XCTAssertEqual(bounded?.poseSamples.count, 10)
    }

    func testCharacterConsensusRequiresMultipleFramesAndIgnoresTransientMisread() {
        let observations = [
            OCRObservation(text: "12BD34", confidence: 0.92, timestamp: 0.0),
            OCRObservation(text: "12BF34", confidence: 0.45, timestamp: 0.1),
            OCRObservation(text: "12BD34", confidence: 0.94, timestamp: 0.2),
            OCRObservation(text: "12BD34", confidence: 0.91, timestamp: 0.3)
        ]
        XCTAssertEqual(PlateConsensus().confirmedPlate(from: observations)?.formatted, "12-BD-34")
        XCTAssertNil(PlateConsensus().confirmedPlate(from: [observations[0]]))
    }

    func testDistantSplitTextFragmentsAssembleLeftToRight() {
        let fragments = [
            PlateTextFragment(
                boundingBox: CGRect(x: 0.70, y: 0.2, width: 0.18, height: 0.6),
                candidates: [PlateTextCandidate(text: "34", confidence: 0.72)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.12, y: 0.2, width: 0.18, height: 0.6),
                candidates: [PlateTextCandidate(text: "12", confidence: 0.75)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.41, y: 0.2, width: 0.18, height: 0.6),
                candidates: [PlateTextCandidate(text: "BD", confidence: 0.70)]
            )
        ]

        let observations = PlateTextAssembler().observations(from: fragments, timestamp: 1)

        XCTAssertTrue(observations.contains { $0.text == "12BD34" })
        XCTAssertEqual(
            Set(observations.compactMap { DutchLicensePlate.recognizedPlate(in: $0.text)?.canonical }),
            ["12BD34"]
        )
    }

    func testFragmentAssemblyCanSkipLogoAndHandleRaisedDuplicateCode() {
        let fragments = [
            PlateTextFragment(
                boundingBox: CGRect(x: 0.01, y: 0.2, width: 0.08, height: 0.3),
                candidates: [PlateTextCandidate(text: "NL", confidence: 0.99)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.18, y: 0.2, width: 0.18, height: 0.6),
                candidates: [PlateTextCandidate(text: "12", confidence: 0.68)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.39, y: 0.68, width: 0.05, height: 0.2),
                candidates: [PlateTextCandidate(text: "1", confidence: 0.55)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.46, y: 0.2, width: 0.18, height: 0.6),
                candidates: [PlateTextCandidate(text: "BD", confidence: 0.70)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.72, y: 0.2, width: 0.18, height: 0.6),
                candidates: [PlateTextCandidate(text: "34", confidence: 0.69)]
            )
        ]

        let observations = PlateTextAssembler().observations(from: fragments, timestamp: 1)

        XCTAssertTrue(observations.contains { $0.text == "12BD34" })
        XCTAssertEqual(
            Set(observations.compactMap { DutchLicensePlate.recognizedPlate(in: $0.text)?.canonical }),
            ["12BD34"]
        )
    }

    func testCountryMarkFilterPreservesFullHeightLegitimateNLGroup() {
        let fragments = [
            PlateTextFragment(
                boundingBox: CGRect(x: 0.05, y: 0.2, width: 0.18, height: 0.6),
                candidates: [PlateTextCandidate(text: "NL", confidence: 0.76)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.38, y: 0.2, width: 0.18, height: 0.6),
                candidates: [PlateTextCandidate(text: "12", confidence: 0.75)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.70, y: 0.2, width: 0.18, height: 0.6),
                candidates: [PlateTextCandidate(text: "BD", confidence: 0.74)]
            )
        ]

        let observations = PlateTextAssembler().observations(from: fragments, timestamp: 1)

        XCTAssertTrue(observations.contains { $0.text == "NL12BD" })
        XCTAssertEqual(DutchLicensePlate.recognizedPlate(in: "NL12BD")?.canonical, "NL12BD")
    }

    func testFragmentAssemblyDoesNotJoinHorizontallyNestedObservations() {
        let fragments = [
            PlateTextFragment(
                boundingBox: CGRect(x: 0.10, y: 0.2, width: 0.30, height: 0.6),
                candidates: [PlateTextCandidate(text: "12", confidence: 0.82)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.25, y: 0.2, width: 0.30, height: 0.6),
                candidates: [PlateTextCandidate(text: "BD", confidence: 0.80)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.70, y: 0.2, width: 0.18, height: 0.6),
                candidates: [PlateTextCandidate(text: "34", confidence: 0.81)]
            )
        ]

        let observations = PlateTextAssembler().observations(from: fragments, timestamp: 1)

        XCTAssertFalse(observations.contains { $0.text == "12BD34" })
        XCTAssertTrue(observations.allSatisfy {
            DutchLicensePlate.recognizedPlate(in: $0.text) == nil
        })
    }

    func testFragmentAssemblyAllowsSlightAdjacentGlyphBoxOverlap() {
        let fragments = [
            PlateTextFragment(
                boundingBox: CGRect(x: 0.10, y: 0.2, width: 0.22, height: 0.6),
                candidates: [PlateTextCandidate(text: "12", confidence: 0.82)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.30, y: 0.2, width: 0.20, height: 0.6),
                candidates: [PlateTextCandidate(text: "BD", confidence: 0.80)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.49, y: 0.2, width: 0.22, height: 0.6),
                candidates: [PlateTextCandidate(text: "34", confidence: 0.81)]
            )
        ]

        let observations = PlateTextAssembler().observations(from: fragments, timestamp: 1)

        XCTAssertTrue(observations.contains { $0.text == "12BD34" })
    }

    func testFragmentAssemblyDoesNotJoinVerticallySeparatedRows() {
        let fragments = [
            PlateTextFragment(
                boundingBox: CGRect(x: 0.12, y: 0.62, width: 0.18, height: 0.24),
                candidates: [PlateTextCandidate(text: "12", confidence: 0.82)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.41, y: 0.12, width: 0.18, height: 0.24),
                candidates: [PlateTextCandidate(text: "BD", confidence: 0.80)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.70, y: 0.62, width: 0.18, height: 0.24),
                candidates: [PlateTextCandidate(text: "34", confidence: 0.81)]
            )
        ]

        let observations = PlateTextAssembler().observations(from: fragments, timestamp: 1)

        XCTAssertFalse(observations.contains { $0.text == "12BD34" })
        XCTAssertTrue(observations.allSatisfy {
            DutchLicensePlate.recognizedPlate(in: $0.text) == nil
        })
    }

    func testFragmentAssemblyCannotUseTallFirstBoxToBridgeSeparateRows() {
        let fragments = [
            PlateTextFragment(
                boundingBox: CGRect(x: 0.08, y: 0.12, width: 0.18, height: 0.76),
                candidates: [PlateTextCandidate(text: "12", confidence: 0.82)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.38, y: 0.62, width: 0.18, height: 0.22),
                candidates: [PlateTextCandidate(text: "BD", confidence: 0.80)]
            ),
            PlateTextFragment(
                boundingBox: CGRect(x: 0.68, y: 0.14, width: 0.18, height: 0.22),
                candidates: [PlateTextCandidate(text: "34", confidence: 0.81)]
            )
        ]

        let observations = PlateTextAssembler().observations(from: fragments, timestamp: 1)

        XCTAssertFalse(observations.contains { $0.text == "12BD34" })
        XCTAssertTrue(observations.allSatisfy {
            DutchLicensePlate.recognizedPlate(in: $0.text) == nil
        })
    }

    func testThreeConsistentModerateConfidenceFramesConfirmDistantPlate() {
        let observations = (0..<3).map {
            OCRObservation(text: "12BD34", confidence: 0.44, timestamp: Double($0) * 0.1)
        }

        XCTAssertEqual(PlateConsensus().confirmedPlate(from: observations)?.canonical, "12BD34")
        XCTAssertNil(PlateConsensus().confirmedPlate(from: Array(observations.prefix(2))))
    }

    func testConflictingModerateConfidenceFramesRemainUnconfirmed() {
        let observations = [
            OCRObservation(text: "12BD34", confidence: 0.45, timestamp: 0),
            OCRObservation(text: "12BF34", confidence: 0.46, timestamp: 0.1),
            OCRObservation(text: "12BD34", confidence: 0.45, timestamp: 0.2)
        ]

        XCTAssertNil(PlateConsensus().confirmedPlate(from: observations))
    }

    func testDuplicateCodeOCRVariantsReachTemporalConsensus() {
        let observations = [
            OCRObservation(text: "121-BD-34", confidence: 0.75, timestamp: 0),
            OCRObservation(text: "12¹-BD-34", confidence: 0.72, timestamp: 0.1),
            OCRObservation(text: "12-1BD-34", confidence: 0.73, timestamp: 0.2)
        ]

        XCTAssertEqual(PlateConsensus().confirmedPlate(from: observations)?.canonical, "12BD34")
    }

    func testVisionAlternativesFromOneTimestampCountAsOneFrame() {
        let alternatives = [
            OCRObservation(text: "12BD34", confidence: 0.94, timestamp: 1.0),
            OCRObservation(text: "12B034", confidence: 0.72, timestamp: 1.0),
            OCRObservation(text: "I2BD34", confidence: 0.61, timestamp: 1.0)
        ]
        XCTAssertNil(PlateConsensus().confirmedPlate(from: alternatives))
    }

    func testAmbiguousGlyphsAreNeverSilentlyCorrectedToFitSyntax() {
        let ambiguousMisreads = [
            "O2BD34", // 0/O
            "I2BD34", // 1/I
            "Z2BD34", // 2/Z
            "S2BD34", // 5/S
            "G2BD34", // 6/G
            "B2BD34"  // 8/B
        ]

        for text in ambiguousMisreads {
            let observations = (0..<3).map {
                OCRObservation(text: text, confidence: 0.96, timestamp: Double($0) * 0.1)
            }
            XCTAssertNil(PlateConsensus().confirmedPlate(from: observations), text)
        }
    }

    func testRepeatedValidSidecodeIsPreservedInsteadOfReinterpretingAnAmbiguousGlyph() {
        let observations = (0..<3).map {
            OCRObservation(text: "1ZBD34", confidence: 0.96, timestamp: Double($0) * 0.1)
        }
        XCTAssertEqual(PlateConsensus().confirmedPlate(from: observations)?.canonical, "1ZBD34")
    }

    func testAmbiguousConflictStaysUnconfirmedButLowConfidenceTransientReadDoesNotWin() {
        let unresolved = [
            OCRObservation(text: "10BD34", confidence: 0.92, timestamp: 0.0),
            OCRObservation(text: "1OBD34", confidence: 0.91, timestamp: 0.1),
            OCRObservation(text: "10BD34", confidence: 0.93, timestamp: 0.2),
            OCRObservation(text: "1OBD34", confidence: 0.90, timestamp: 0.3),
            OCRObservation(text: "10BD34", confidence: 0.94, timestamp: 0.4)
        ]
        XCTAssertNil(PlateConsensus().confirmedPlate(from: unresolved))

        let confirmed = [
            OCRObservation(text: "10BD34", confidence: 0.93, timestamp: 0.0),
            OCRObservation(text: "1OBD34", confidence: 0.25, timestamp: 0.1),
            OCRObservation(text: "10BD34", confidence: 0.94, timestamp: 0.2),
            OCRObservation(text: "10BD34", confidence: 0.95, timestamp: 0.3)
        ]
        XCTAssertEqual(PlateConsensus().confirmedPlate(from: confirmed)?.canonical, "10BD34")
    }

    func testCharacterVotesCannotSynthesizeAPlateNeverReadAsAWhole() {
        let observations = [
            OCRObservation(text: "12BF34", confidence: 0.91, timestamp: 0.0),
            OCRObservation(text: "12GD34", confidence: 0.92, timestamp: 0.1),
            OCRObservation(text: "12BD35", confidence: 0.93, timestamp: 0.2),
            OCRObservation(text: "12BD44", confidence: 0.94, timestamp: 0.3)
        ]
        XCTAssertNil(PlateConsensus().confirmedPlate(from: observations))
    }
}

private struct StubPlateDetector: PlateDetecting {
    let detections: [PlateDetection]

    func detect(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval
    ) throws -> [PlateDetection] {
        detections
    }
}

private struct AlwaysPlausibleAppearanceScorer: PlateAppearanceScoring {
    func score(_ image: CGImage) -> PlateAppearanceScore? {
        PlateAppearanceScore(
            yellowFraction: 0.7,
            darkFraction: 0.18,
            darkBandCoverage: 1,
            darkRowCoverage: 1,
            luminanceDeviation: 0.2
        )
    }
}

private struct EmptyPlateTextLocalizer: PlateTextLocalizing {
    func locate(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval
    ) throws -> [PlateDetection] {
        []
    }
}

private struct StubPlateTextLocalizer: PlateTextLocalizing {
    let detections: [PlateDetection]

    func locate(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval
    ) throws -> [PlateDetection] {
        detections
    }
}

private final class NthPlausibleAppearanceScorer: @unchecked Sendable, PlateAppearanceScoring {
    private let lock = NSLock()
    private let plausibleCall: Int
    private var calls = 0

    init(plausibleCall: Int) {
        self.plausibleCall = plausibleCall
    }

    func score(_ image: CGImage) -> PlateAppearanceScore? {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        let plausible = calls == plausibleCall
        return PlateAppearanceScore(
            yellowFraction: plausible ? 0.7 : 0,
            darkFraction: plausible ? 0.18 : 0,
            darkBandCoverage: plausible ? 1 : 0,
            darkRowCoverage: plausible ? 1 : 0,
            luminanceDeviation: plausible ? 0.2 : 0
        )
    }
}

private final class SequencedPlateDetector: @unchecked Sendable, PlateDetecting {
    private let lock = NSLock()
    private var frames: [[(PlateQuadrilateral, Float)]]

    init(frames: [[(PlateQuadrilateral, Float)]]) {
        self.frames = frames
    }

    func detect(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval
    ) throws -> [PlateDetection] {
        lock.lock()
        defer { lock.unlock() }
        let frame = frames.isEmpty ? [] : frames.removeFirst()
        return frame.map {
            PlateDetection(quadrilateral: $0.0, confidence: $0.1, timestamp: timestamp)
        }
    }
}
