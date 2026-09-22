import simd
import XCTest
@testable import Blikvanger

@MainActor
final class ScanGuidanceReducerTests: XCTestCase {
    func testNoDetectionWaitsBrieflyThenReturnsToReadyCopy() {
        let reducer = ScanGuidanceReducer()

        XCTAssertNil(reducer.message(
            diagnostics: AutomaticPipelineDiagnostics(),
            tracks: [],
            secondsSinceDetection: 0.4,
            readyMessage: "Ready"
        ))
        XCTAssertEqual(reducer.message(
            diagnostics: AutomaticPipelineDiagnostics(),
            tracks: [],
            secondsSinceDetection: 0.8,
            readyMessage: "Ready"
        ), "Ready")
    }

    func testGuidanceReflectsSavedConfirmedAndUnavailableLabels() {
        let reducer = ScanGuidanceReducer()
        var confirmed = track(state: .confirmed)
        confirmed.vehicle = VehicleSummary(plate: "12-BD-34", make: "VOLVO")

        XCTAssertEqual(reducer.message(
            diagnostics: AutomaticPipelineDiagnostics(),
            tracks: [confirmed],
            secondsSinceDetection: 1,
            readyMessage: "Ready"
        ), "Vehicle confirmed — point at another plate when ready")
        XCTAssertEqual(reducer.message(
            diagnostics: AutomaticPipelineDiagnostics(),
            tracks: [track(state: .unavailable)],
            secondsSinceDetection: 1,
            readyMessage: "Ready"
        ), "Vehicle saved — RDW is temporarily unavailable")
    }

    func testPendingLookupAlwaysShowsTheExactPlate() {
        var confirming = track(state: .confirming)
        confirming.displayName = "12-BD-34"
        confirming.rdwLookupPlateCanonical = "12BD34"
        XCTAssertEqual(
            PendingPlateLookupFormatter().text(for: [confirming]),
            "12-BD-34 recognized — preparing RDW lookup"
        )

        var loading = track(state: .loading)
        loading.displayName = "Wrong fallback"
        loading.rdwLookupPlateCanonical = "34BD56"
        XCTAssertEqual(
            PendingPlateLookupFormatter().text(for: [loading]),
            "Checking 34-BD-56 with RDW…"
        )
        XCTAssertEqual(
            ScanGuidanceReducer().message(
                diagnostics: AutomaticPipelineDiagnostics(detections: 1, candidates: 1),
                tracks: [loading],
                secondsSinceDetection: 0,
                readyMessage: "Ready"
            ),
            "Checking 34-BD-56 with RDW…"
        )
    }

    func testPendingLookupDisappearsAfterRDWCompletes() {
        var confirmed = track(state: .confirmed)
        confirmed.displayName = "12-BD-34"
        confirmed.rdwLookupPlateCanonical = "12BD34"

        XCTAssertNil(PendingPlateLookupFormatter().text(for: [confirmed]))
    }

    func testCardAndDetailsExplainRecognizedAndPendingRDWStates() {
        var loading = track(state: .loading)
        loading.displayName = "12-BD-34"
        loading.rdwLookupPlateCanonical = "12BD34"

        XCTAssertEqual(VehicleCardView.subtitle(for: loading), "Checking this plate with RDW…")
        XCTAssertEqual(
            VehicleDetailsStatusFormatter().text(for: .loading, plate: "12-BD-34"),
            "Checking plate 12-BD-34 in the public RDW dataset…"
        )
    }

    func testDetectionGuidanceProgressesFromHoldToDepthToReading() {
        let reducer = ScanGuidanceReducer()
        var diagnostics = AutomaticPipelineDiagnostics(detections: 1, candidates: 1)
        XCTAssertEqual(reducer.message(
            diagnostics: diagnostics,
            tracks: [],
            secondsSinceDetection: 0,
            readyMessage: "Ready"
        ), "Plate found — hold the iPhone steady")

        diagnostics.poseCandidates = 1
        XCTAssertEqual(reducer.message(
            diagnostics: diagnostics,
            tracks: [],
            secondsSinceDetection: 0,
            readyMessage: "Ready"
        ), "Plate found — move a little closer")

        diagnostics.maximumDepthSamples = 5
        diagnostics.acceptedPoseEstimates = 1
        diagnostics.anchoredCandidates = 1
        diagnostics.currentTargetCardState = .candidate
        XCTAssertEqual(reducer.message(
            diagnostics: diagnostics,
            tracks: [],
            secondsSinceDetection: 0,
            readyMessage: "Ready"
        ), "Vehicle found — reading its plate")
    }

    func testGuidanceDoesNotApplyAnOldAnchoredCandidateToTheCurrentDetection() {
        let diagnostics = AutomaticPipelineDiagnostics(
            detections: 1,
            candidates: 2,
            anchoredCandidates: 1
        )

        XCTAssertEqual(ScanGuidanceReducer().message(
            diagnostics: diagnostics,
            tracks: [track(state: .confirmed)],
            secondsSinceDetection: 0,
            readyMessage: "Ready"
        ), "Plate found — hold the iPhone steady")
    }

    func testGuidanceIdentifiesTheCurrentTargetAsAlreadyLabeled() {
        var diagnostics = AutomaticPipelineDiagnostics(detections: 1, candidates: 1)
        diagnostics.currentTargetCardState = .confirmed

        XCTAssertEqual(ScanGuidanceReducer().message(
            diagnostics: diagnostics,
            tracks: [track(state: .confirmed)],
            secondsSinceDetection: 0,
            readyMessage: "Ready"
        ), "Vehicle already labeled — point at another plate when ready")
    }

    func testMeasuredPlateWaitsForNormallyTrackedWorldEvidence() {
        let diagnostics = AutomaticPipelineDiagnostics(
            detections: 1,
            candidates: 1,
            maximumObservationCount: 4,
            poseCandidates: 1,
            maximumDepthSamples: 5,
            acceptedPoseEstimates: 1,
            maximumNormallyTrackedPoseSamples: 1
        )

        XCTAssertEqual(
            ScanGuidanceReducer().message(
                diagnostics: diagnostics,
                tracks: [],
                secondsSinceDetection: 0,
                readyMessage: "Ready"
            ),
            "Plate measured — move the iPhone slowly"
        )
    }

    func testCandidateDetailsExplainThatScanningPausesWithoutHidingRemoval() {
        let message = VehicleDetailsStatusFormatter().text(for: .candidate)

        XCTAssertTrue(message.contains("detection and reading pause"))
        XCTAssertTrue(message.contains("close them to continue"))
    }

    private func track(state: VehicleCardState) -> VehicleTrack {
        var track = VehicleTrack(
            displayName: "Scanning vehicle",
            transform: matrix_identity_float4x4
        )
        track.cardState = state
        return track
    }
}
