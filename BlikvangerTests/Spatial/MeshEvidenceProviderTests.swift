import simd
import XCTest
@testable import Blikvanger

final class MeshEvidenceProviderTests: XCTestCase {
    func testWorldRayUsesSnapshotIntrinsicsAndCameraTransform() throws {
        var cameraToWorld = matrix_identity_float4x4
        cameraToWorld.columns.3 = SIMD4(1, 2, 3, 1)
        let calibration = CameraCalibration(
            intrinsics: simd_float3x3(
                SIMD3(800, 0, 0),
                SIMD3(0, 800, 0),
                SIMD3(200, 100, 1)
            ),
            cameraToWorld: cameraToWorld,
            imageSize: SIMD2(400, 200)
        )

        let center = try XCTUnwrap(CameraRayProjector().worldRay(
            for: CGPoint(x: 0.5, y: 0.5),
            calibration: calibration
        ))
        XCTAssertEqual(center.origin, SIMD3(1, 2, 3))
        XCTAssertEqual(center.direction.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(center.direction.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(center.direction.z, -1, accuracy: 0.000_001)

        let right = try XCTUnwrap(CameraRayProjector().worldRay(
            for: CGPoint(x: 0.75, y: 0.5),
            calibration: calibration
        ))
        XCTAssertGreaterThan(right.direction.x, 0)
        XCTAssertLessThan(right.direction.z, 0)
        XCTAssertEqual(simd_length(right.direction), 1, accuracy: 0.000_001)
    }

    func testWorldRayRejectsInvalidCoordinatesAndCalibration() {
        let invalidCalibration = CameraCalibration(
            intrinsics: simd_float3x3(),
            cameraToWorld: matrix_identity_float4x4,
            imageSize: SIMD2(0, 0)
        )
        XCTAssertNil(CameraRayProjector().worldRay(
            for: CGPoint(x: 0.5, y: 0.5),
            calibration: invalidCalibration
        ))
        XCTAssertNil(CameraRayProjector().worldRay(
            for: CGPoint(x: 1.2, y: 0.5),
            calibration: invalidCalibration
        ))
    }
}
