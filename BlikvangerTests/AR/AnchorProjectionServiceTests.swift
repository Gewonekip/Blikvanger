import simd
import XCTest
@testable import Blikvanger

final class AnchorProjectionServiceTests: XCTestCase {
    func testFrameAnchorTransformIndexUsesCurrentFrameTransformAndHidesAbsence() {
        let presentIdentifier = UUID()
        let absentIdentifier = UUID()
        var adjustedByARKit = matrix_identity_float4x4
        adjustedByARKit.columns.3 = SIMD4(1.2, 0.4, -2.5, 1)
        let index = FrameAnchorTransformIndex(
            transformsByIdentifier: [presentIdentifier: adjustedByARKit]
        )

        let resolved = index.transform(for: presentIdentifier)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved!.columns.3.x, 1.2, accuracy: 0.0001)
        XCTAssertEqual(resolved!.columns.3.z, -2.5, accuracy: 0.0001)
        XCTAssertNil(index.transform(for: absentIdentifier))
    }

    func testProjectsCenterAndPreservesWorldPointUnderCameraMotion() {
        let service = AnchorProjectionService()
        let id = UUID()
        let viewport = CGSize(width: 400, height: 800)
        let first = service.project(
            trackID: id,
            worldPoint: SIMD3(0, 0, 0.5),
            viewProjection: matrix_identity_float4x4,
            viewport: viewport
        )
        XCTAssertEqual(first.point.x, 200, accuracy: 0.001)
        XCTAssertEqual(first.point.y, 400, accuracy: 0.001)
        XCTAssertEqual(first.depth, 0.5, accuracy: 0.001)
        XCTAssertTrue(first.isVisible)

        var movedCameraProjection = matrix_identity_float4x4
        movedCameraProjection.columns.3.x = 0.5
        let moved = service.project(
            trackID: id,
            worldPoint: SIMD3(0, 0, 0.5),
            viewProjection: movedCameraProjection,
            viewport: viewport,
            cameraWorldPosition: SIMD3(0.25, 0, 0)
        )
        XCTAssertEqual(moved.trackID, id)
        XCTAssertNotEqual(first.point.x, moved.point.x)
        XCTAssertEqual(moved.depth, Float(hypot(0.25, 0.5)), accuracy: 0.001)
    }

    func testHidesBehindCameraAndOutsideViewport() {
        let service = AnchorProjectionService()
        var behind = matrix_identity_float4x4
        behind.columns.3.w = -2
        XCTAssertFalse(service.project(
            trackID: UUID(),
            worldPoint: .zero,
            viewProjection: behind,
            viewport: CGSize(width: 100, height: 100)
        ).isVisible)

        XCTAssertFalse(service.project(
            trackID: UUID(),
            worldPoint: SIMD3(3, 0, 0.5),
            viewProjection: matrix_identity_float4x4,
            viewport: CGSize(width: 100, height: 100)
        ).isVisible)
    }

    func testVisibleBaseKeepsRaisedOffscreenAnnotationEligibleForClamping() {
        let service = AnchorProjectionService()
        let projection = service.projectAnnotation(
            trackID: UUID(),
            baseWorldPoint: SIMD3(0, 0, 0.5),
            attachmentWorldPoint: SIMD3(0, 2, 0.5),
            viewProjection: matrix_identity_float4x4,
            viewport: CGSize(width: 400, height: 800)
        )

        XCTAssertTrue(projection.isVisible)
        XCTAssertTrue(projection.isInFront)
        XCTAssertLessThan(projection.point.y, 0, "Layout should receive and clamp the true raised attachment")
    }

    func testAnnotationStillHidesWhenBaseAndAttachmentAreBehindCamera() {
        var behind = matrix_identity_float4x4
        behind.columns.3.w = -2

        let projection = AnchorProjectionService().projectAnnotation(
            trackID: UUID(),
            baseWorldPoint: .zero,
            attachmentWorldPoint: SIMD3(0, 0.75, 0),
            viewProjection: behind,
            viewport: CGSize(width: 400, height: 800)
        )

        XCTAssertFalse(projection.isVisible)
        XCTAssertFalse(projection.isInFront)
    }
}
