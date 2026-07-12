import simd
import XCTest
@testable import LicensePlates

final class PlanarPoseSolverTests: XCTestCase {
    func testFourCornerPoseRecoversStandardPlateDistance() {
        let calibration = calibration()
        let quad = projectedFrontFacingQuad(size: .standard, distance: 2, calibration: calibration)
        let solution = PlanarPoseSolver().solve(
            quadrilateral: quad,
            calibration: calibration,
            physicalSize: .standard
        )
        XCTAssertNotNil(solution)
        XCTAssertEqual(solution!.distance, 2, accuracy: 0.01)
        XCTAssertLessThan(solution!.reprojectionError, 0.001)
        XCTAssertLessThan(solution!.scaleMismatch, 0.001)
    }

    func testSelectsLegalAlternativeByDepthAndRejectsConflictingMesh() {
        let calibration = calibration()
        let quad = projectedFrontFacingQuad(size: .motorcycle, distance: 2, calibration: calibration)
        let depth = [
            SIMD3<Float>(-0.08, 0, -2), SIMD3(0, 0, -2), SIMD3(0.08, 0, -2)
        ].map { DepthSample(imagePoint: .zero, depth: 2, confidence: 2, worldPoint: $0) }
        let agreeingMesh = [
            MeshSample(imagePoint: CGPoint(x: 0.4, y: 0.4), worldPoint: SIMD3(-0.04, -0.03, -2)),
            MeshSample(imagePoint: CGPoint(x: 0.6, y: 0.4), worldPoint: SIMD3(0.04, -0.03, -2)),
            MeshSample(imagePoint: CGPoint(x: 0.6, y: 0.6), worldPoint: SIMD3(0.04, 0.03, -2)),
            MeshSample(imagePoint: CGPoint(x: 0.4, y: 0.6), worldPoint: SIMD3(-0.04, 0.03, -2)),
            MeshSample(imagePoint: CGPoint(x: 0.5, y: 0.5), worldPoint: SIMD3(0, 0, -2))
        ]
        let estimate = PlatePoseEstimator().estimate(
            quadrilateral: quad,
            calibration: calibration,
            depthSamples: depth,
            meshWorldPoints: agreeingMesh
        )
        XCTAssertEqual(estimate?.physicalSize, .motorcycle)
        XCTAssertEqual(estimate?.meshAgreement, true)

        let conflict = agreeingMesh.map {
            MeshSample(imagePoint: $0.imagePoint, worldPoint: $0.worldPoint + SIMD3(1, 0, 0))
        }
        XCTAssertNil(PlatePoseEstimator().estimate(
            quadrilateral: quad,
            calibration: calibration,
            depthSamples: depth,
            meshWorldPoints: conflict
        ))
    }

    func testMeshAgreementRejectsDuplicateRaysDegenerateSpanNonplanarityAndWrongNormal() {
        let calibration = calibration()
        let quad = projectedFrontFacingQuad(size: .standard, distance: 2, calibration: calibration)
        let depth = [
            SIMD3<Float>(-0.08, 0, -2), SIMD3(0, 0, -2), SIMD3(0.08, 0, -2)
        ].map { DepthSample(imagePoint: .zero, depth: 2, confidence: 2, worldPoint: $0) }
        let imagePoints = [
            CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.4),
            CGPoint(x: 0.6, y: 0.6), CGPoint(x: 0.4, y: 0.6)
        ]

        let duplicateRays = [
            SIMD3<Float>(-0.05, -0.03, -2), SIMD3(0.05, -0.03, -2),
            SIMD3(0.05, 0.03, -2), SIMD3(-0.05, 0.03, -2)
        ].map { MeshSample(imagePoint: imagePoints[0], worldPoint: $0) }
        XCTAssertNil(PlatePoseEstimator().estimate(
            quadrilateral: quad,
            calibration: calibration,
            depthSamples: depth,
            meshWorldPoints: duplicateRays
        ))

        let collinear = zip(imagePoints, [-0.06, -0.02, 0.02, 0.06] as [Float]).map {
            MeshSample(imagePoint: $0.0, worldPoint: SIMD3($0.1, 0, -2))
        }
        XCTAssertNil(PlatePoseEstimator().estimate(
            quadrilateral: quad,
            calibration: calibration,
            depthSamples: depth,
            meshWorldPoints: collinear
        ))

        let insufficientSpan = zip(imagePoints, [
            SIMD3<Float>(-0.008, -0.008, -2), SIMD3(0.008, -0.008, -2),
            SIMD3(0.008, 0.008, -2), SIMD3(-0.008, 0.008, -2)
        ]).map { MeshSample(imagePoint: $0.0, worldPoint: $0.1) }
        XCTAssertNil(PlatePoseEstimator().estimate(
            quadrilateral: quad,
            calibration: calibration,
            depthSamples: depth,
            meshWorldPoints: insufficientSpan
        ))

        let nonplanarPoints = [
            SIMD3<Float>(-0.06, -0.04, -2.12), SIMD3(0.06, -0.04, -1.88),
            SIMD3(0.06, 0.04, -2.12), SIMD3(-0.06, 0.04, -1.88)
        ]
        let nonplanar = zip(imagePoints, nonplanarPoints).map {
            MeshSample(imagePoint: $0.0, worldPoint: $0.1)
        }
        XCTAssertNil(PlatePoseEstimator().estimate(
            quadrilateral: quad,
            calibration: calibration,
            depthSamples: depth,
            meshWorldPoints: nonplanar
        ))

        let wrongNormalPoints = [
            SIMD3<Float>(0, -0.05, -2.06), SIMD3(0, -0.05, -1.94),
            SIMD3(0, 0.05, -1.94), SIMD3(0, 0.05, -2.06)
        ]
        let wrongNormal = zip(imagePoints, wrongNormalPoints).map {
            MeshSample(imagePoint: $0.0, worldPoint: $0.1)
        }
        XCTAssertNil(PlatePoseEstimator().estimate(
            quadrilateral: quad,
            calibration: calibration,
            depthSamples: depth,
            meshWorldPoints: wrongNormal
        ))
    }

    func testCameraToWorldTranslationIsApplied() throws {
        var cameraToWorld = matrix_identity_float4x4
        cameraToWorld.columns.3 = SIMD4(1, 2, 3, 1)
        let calibration = CameraCalibration(
            intrinsics: intrinsics(),
            cameraToWorld: cameraToWorld,
            imageSize: SIMD2(400, 200)
        )
        let quad = projectedFrontFacingQuad(size: .standard, distance: 2, calibration: calibration)
        let solution = PlanarPoseSolver().solve(quadrilateral: quad, calibration: calibration, physicalSize: .standard)
        let transform = try XCTUnwrap(solution?.worldTransform)
        XCTAssertEqual(transform.columns.3.x, 1, accuracy: 0.01)
        XCTAssertEqual(transform.columns.3.y, 2, accuracy: 0.01)
        XCTAssertEqual(transform.columns.3.z, 1, accuracy: 0.01)
    }

    func testRejectsEqualScaleShearThatIsNotARigidPlatePose() {
        let sheared = PlateQuadrilateral(
            topLeft: CGPoint(x: 82.8 / 400, y: 1 - 82.4 / 200),
            topRight: CGPoint(x: 290.8 / 400, y: 1 - 82.4 / 200),
            bottomRight: CGPoint(x: 317.2 / 400, y: 1 - 117.6 / 200),
            bottomLeft: CGPoint(x: 109.2 / 400, y: 1 - 117.6 / 200)
        )
        XCTAssertNil(PlanarPoseSolver().solve(
            quadrilateral: sheared,
            calibration: calibration(),
            physicalSize: .standard
        ))
    }

    func testTiltedOffAxisRigidPlateRecoversPoseAndRigidReprojection() throws {
        let calibration = calibration()
        let angleY = Double.pi / 6
        let angleX = Double.pi / 18
        let r1 = SIMD3<Double>(cos(angleY), 0, -sin(angleY))
        let r2 = SIMD3<Double>(sin(angleY) * sin(angleX), cos(angleX), cos(angleY) * sin(angleX))
        let translation = SIMD3<Double>(0.3, 0.1, 2.5)
        let quad = projectedQuad(
            size: .standard,
            r1: r1,
            r2: r2,
            translation: translation,
            calibration: calibration
        )
        let solution = try XCTUnwrap(PlanarPoseSolver().solve(
            quadrilateral: quad,
            calibration: calibration,
            physicalSize: .standard
        ))
        XCTAssertEqual(solution.distance, 2.5, accuracy: 0.03)
        XCTAssertLessThan(solution.reprojectionError, 0.5)
        XCTAssertLessThan(solution.orthogonalityError, 0.01)
        XCTAssertEqual(solution.worldTransform.columns.3.x, 0.3, accuracy: 0.03)
        XCTAssertEqual(solution.worldTransform.columns.3.y, -0.1, accuracy: 0.03)
    }

    func testStationaryWorldPlateRecoversSamePoseAfterCameraTranslationAndRotation() throws {
        var plateToWorld = matrix_identity_float4x4
        plateToWorld.columns.3 = SIMD4(0.1, 0.05, -2.5, 1)

        let firstCalibration = calibration(cameraToWorld: matrix_identity_float4x4)
        var movedCamera = simd_float4x4(simd_quatf(angle: 0.09, axis: SIMD3(0, 1, 0)))
        movedCamera.columns.3 = SIMD4(0.25, 0.03, 0.08, 1)
        let secondCalibration = calibration(cameraToWorld: movedCamera)

        let first = try XCTUnwrap(PlanarPoseSolver().solve(
            quadrilateral: projectedWorldQuad(size: .standard, plateToWorld: plateToWorld, calibration: firstCalibration),
            calibration: firstCalibration,
            physicalSize: .standard
        ))
        let second = try XCTUnwrap(PlanarPoseSolver().solve(
            quadrilateral: projectedWorldQuad(size: .standard, plateToWorld: plateToWorld, calibration: secondCalibration),
            calibration: secondCalibration,
            physicalSize: .standard
        ))

        let expectedPosition = SIMD3<Float>(0.1, 0.05, -2.5)
        let firstPosition = SIMD3(first.worldTransform.columns.3.x, first.worldTransform.columns.3.y, first.worldTransform.columns.3.z)
        let secondPosition = SIMD3(second.worldTransform.columns.3.x, second.worldTransform.columns.3.y, second.worldTransform.columns.3.z)
        XCTAssertLessThan(simd_distance(firstPosition, expectedPosition), 0.015)
        XCTAssertLessThan(simd_distance(secondPosition, expectedPosition), 0.015)
        XCTAssertLessThan(simd_distance(firstPosition, secondPosition), 0.015)

        let firstRotation = simd_quatf(rotationMatrix(of: first.worldTransform))
        let secondRotation = simd_quatf(rotationMatrix(of: second.worldTransform))
        let angularDifference = 2 * acos(min(1, abs(simd_dot(firstRotation.vector, secondRotation.vector))))
        XCTAssertLessThan(angularDifference, 0.01)
    }

    private func calibration() -> CameraCalibration {
        CameraCalibration(intrinsics: intrinsics(), cameraToWorld: matrix_identity_float4x4, imageSize: SIMD2(400, 200))
    }

    private func calibration(cameraToWorld: simd_float4x4) -> CameraCalibration {
        CameraCalibration(intrinsics: intrinsics(), cameraToWorld: cameraToWorld, imageSize: SIMD2(400, 200))
    }

    private func intrinsics() -> simd_float3x3 {
        simd_float3x3(SIMD3(800, 0, 0), SIMD3(0, 800, 0), SIMD3(200, 100, 1))
    }

    private func rotationMatrix(of transform: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
    }

    private func projectedFrontFacingQuad(
        size: PlatePhysicalSize,
        distance: Float,
        calibration: CameraCalibration
    ) -> PlateQuadrilateral {
        let halfWidth = size.meters.x / 2
        let halfHeight = size.meters.y / 2
        func visionPoint(x: Float, y: Float) -> CGPoint {
            let u = calibration.intrinsics[0, 0] * x / distance + calibration.intrinsics[2, 0]
            let v = calibration.intrinsics[1, 1] * y / distance + calibration.intrinsics[2, 1]
            return CGPoint(
                x: CGFloat(u / Float(calibration.imageSize.x)),
                y: CGFloat(1 - v / Float(calibration.imageSize.y))
            )
        }
        return PlateQuadrilateral(
            topLeft: visionPoint(x: -halfWidth, y: -halfHeight),
            topRight: visionPoint(x: halfWidth, y: -halfHeight),
            bottomRight: visionPoint(x: halfWidth, y: halfHeight),
            bottomLeft: visionPoint(x: -halfWidth, y: halfHeight)
        )
    }

    private func projectedQuad(
        size: PlatePhysicalSize,
        r1: SIMD3<Double>,
        r2: SIMD3<Double>,
        translation: SIMD3<Double>,
        calibration: CameraCalibration
    ) -> PlateQuadrilateral {
        let halfWidth = Double(size.meters.x) / 2
        let halfHeight = Double(size.meters.y) / 2
        func point(_ x: Double, _ y: Double) -> CGPoint {
            let camera = r1 * x + r2 * y + translation
            let u = Double(calibration.intrinsics[0, 0]) * camera.x / camera.z + Double(calibration.intrinsics[2, 0])
            let v = Double(calibration.intrinsics[1, 1]) * camera.y / camera.z + Double(calibration.intrinsics[2, 1])
            return CGPoint(
                x: u / Double(calibration.imageSize.x),
                y: 1 - v / Double(calibration.imageSize.y)
            )
        }
        return PlateQuadrilateral(
            topLeft: point(-halfWidth, -halfHeight),
            topRight: point(halfWidth, -halfHeight),
            bottomRight: point(halfWidth, halfHeight),
            bottomLeft: point(-halfWidth, halfHeight)
        )
    }

    private func projectedWorldQuad(
        size: PlatePhysicalSize,
        plateToWorld: simd_float4x4,
        calibration: CameraCalibration
    ) -> PlateQuadrilateral {
        let halfWidth = size.meters.x / 2
        let halfHeight = size.meters.y / 2
        let worldToCamera = calibration.cameraToWorld.inverse

        func point(_ x: Float, _ y: Float) -> CGPoint {
            let world = plateToWorld * SIMD4(x, y, 0, 1)
            let camera = worldToCamera * world
            let depth = -camera.z
            let u = calibration.intrinsics[0, 0] * camera.x / depth + calibration.intrinsics[2, 0]
            let v = calibration.intrinsics[2, 1] - calibration.intrinsics[1, 1] * camera.y / depth
            return CGPoint(
                x: CGFloat(u / Float(calibration.imageSize.x)),
                y: CGFloat(1 - v / Float(calibration.imageSize.y))
            )
        }

        return PlateQuadrilateral(
            topLeft: point(-halfWidth, halfHeight),
            topRight: point(halfWidth, halfHeight),
            bottomRight: point(halfWidth, -halfHeight),
            bottomLeft: point(-halfWidth, -halfHeight)
        )
    }
}
