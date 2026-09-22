import simd
import XCTest
@testable import Blikvanger

final class DepthAndPoseTests: XCTestCase {
    private let quad = PlateQuadrilateral(
        topLeft: CGPoint(x: 0.25, y: 0.6),
        topRight: CGPoint(x: 0.75, y: 0.6),
        bottomRight: CGPoint(x: 0.75, y: 0.4),
        bottomLeft: CGPoint(x: 0.25, y: 0.4)
    )

    func testDepthMappingConfidenceOutlierRejectionAndBackProjection() throws {
        var depths = Array(repeating: Float(2), count: 64)
        depths[37] = 8 // One sampled edge cell is a depth outlier.
        var confidences = Array(repeating: UInt8(2), count: 64)
        confidences[27] = 0 // A different sampled cell has unusable confidence.
        let grid = DepthGrid(width: 8, height: 8, depths: depths, confidences: confidences)
        var poseIntrinsics = intrinsics()
        poseIntrinsics[0, 0] = 800
        poseIntrinsics[1, 1] = 800
        let calibration = CameraCalibration(intrinsics: poseIntrinsics, cameraToWorld: matrix_identity_float4x4, imageSize: SIMD2(400, 200))

        let samples = DepthSampler().sample(quadrilateral: quad, grid: grid, calibration: calibration)
        XCTAssertGreaterThanOrEqual(samples.count, 3)
        XCTAssertTrue(samples.allSatisfy { $0.depth == 2 })
        let backProjected = try XCTUnwrap(DepthSampler().backProject(
            imagePoint: SIMD2(200, 100),
            depth: 2,
            calibration: calibration
        ))
        XCTAssertEqual(backProjected, SIMD3(0, 0, -2))
    }

    func testDepthSamplerRejectsInvalidIntrinsicsWithoutProducingNonfiniteWorldPoints() {
        let invalidCalibration = CameraCalibration(
            intrinsics: simd_float3x3(
                SIMD3(0, 0, 0),
                SIMD3(0, .infinity, 0),
                SIMD3(200, 100, 1)
            ),
            cameraToWorld: matrix_identity_float4x4,
            imageSize: SIMD2(400, 200)
        )
        let grid = DepthGrid(
            width: 8,
            height: 8,
            depths: Array(repeating: 2, count: 64),
            confidences: Array(repeating: 2, count: 64)
        )

        XCTAssertTrue(DepthSampler().sample(
            quadrilateral: quad,
            grid: grid,
            calibration: invalidCalibration
        ).isEmpty)
        XCTAssertNil(DepthSampler().backProject(
            imagePoint: SIMD2(200, 100),
            depth: 2,
            calibration: invalidCalibration
        ))
    }

    func testSyntheticPlanarPoseAndFusionRejectJump() {
        var poseIntrinsics = intrinsics()
        poseIntrinsics[0, 0] = 800
        poseIntrinsics[1, 1] = 800
        let calibration = CameraCalibration(intrinsics: poseIntrinsics, cameraToWorld: matrix_identity_float4x4, imageSize: SIMD2(400, 200))
        let points = [SIMD3<Float>(-0.1, 0, -2), SIMD3(0, 0, -2), SIMD3(0.1, 0, -2)]
        let samples = points.map { DepthSample(imagePoint: .zero, depth: 2, confidence: 2, worldPoint: $0) }
        let pose = PlatePoseEstimator().estimate(quadrilateral: quad, calibration: calibration, depthSamples: samples)
        guard let pose else { return XCTFail("Expected a synthetic pose") }
        XCTAssertEqual(pose.worldTransform.columns.3.z, -2, accuracy: 0.001)

        var transforms = [pose.worldTransform, pose.worldTransform, pose.worldTransform]
        transforms[1].columns.3.x = 0.03
        var jump = pose.worldTransform
        jump.columns.3.x = 2
        transforms.append(jump)
        let fused = PoseFusion().stableTransform(from: transforms.enumerated().map { PoseSample(worldTransform: $0.element, confidence: 1, timestamp: Double($0.offset)) })
        XCTAssertNotNil(fused)
        XCTAssertLessThan(fused!.columns.3.x, 0.05)
        XCTAssertFalse(PoseFusion().estimatorsAgree(pose.worldTransform, jump))
    }

    func testPoseFusionRejectsOrientationJumpAtTheSamePosition() {
        let identity = matrix_identity_float4x4
        let rotated = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
        let samples = [identity, identity, rotated].enumerated().map {
            PoseSample(worldTransform: $0.element, confidence: 1, timestamp: Double($0.offset))
        }
        XCTAssertNil(PoseFusion().stableTransform(from: samples))
        XCTAssertFalse(PoseFusion().estimatorsAgree(identity, rotated))
    }

    func testDepthCentroidFallbackUsesCoherentMeasuredWorldPosition() throws {
        let calibration = CameraCalibration(
            intrinsics: intrinsics(),
            cameraToWorld: matrix_identity_float4x4,
            imageSize: SIMD2(400, 200)
        )
        let samples = [
            SIMD3<Float>(-0.08, 0.01, -2.02),
            SIMD3<Float>(0, 0, -2),
            SIMD3<Float>(0.08, -0.01, -1.98),
            SIMD3<Float>(0.02, 0.02, -2.01)
        ].map {
            DepthSample(imagePoint: .zero, depth: -$0.z, confidence: 2, worldPoint: $0)
        }
        let estimate = try XCTUnwrap(DepthCentroidPoseEstimator().estimate(
            quadrilateral: scaleConsistentQuad(),
            calibration: calibration,
            depthSamples: samples
        ))
        XCTAssertEqual(estimate.worldTransform.columns.3.x, 0, accuracy: 0.001)
        XCTAssertEqual(estimate.worldTransform.columns.3.z, -2.01, accuracy: 0.001)
        XCTAssertFalse(estimate.meshAgreement)
    }

    func testDepthCentroidFallbackRejectsRectangleWithImpossiblePhysicalScale() {
        let calibration = CameraCalibration(
            intrinsics: intrinsics(),
            cameraToWorld: matrix_identity_float4x4,
            imageSize: SIMD2(400, 200)
        )
        let samples = [
            SIMD3<Float>(-0.08, 0, -2),
            SIMD3<Float>(0, 0, -2),
            SIMD3<Float>(0.08, 0, -2),
            SIMD3<Float>(0.02, 0.02, -2)
        ].map {
            DepthSample(imagePoint: .zero, depth: 2, confidence: 2, worldPoint: $0)
        }

        XCTAssertNil(DepthCentroidPoseEstimator().estimate(
            quadrilateral: quad,
            calibration: calibration,
            depthSamples: samples
        ))
    }

    func testDepthCentroidFallbackRejectsUniformlyTinyYellowStickerScale() {
        let calibration = CameraCalibration(
            intrinsics: intrinsics(),
            cameraToWorld: matrix_identity_float4x4,
            imageSize: SIMD2(400, 200)
        )
        let samples = [
            SIMD3<Float>(-0.03, 0, -2),
            SIMD3<Float>(0, 0, -2),
            SIMD3<Float>(0.03, 0, -2),
            SIMD3<Float>(0, 0.01, -2)
        ].map {
            DepthSample(imagePoint: .zero, depth: 2, confidence: 2, worldPoint: $0)
        }
        let tiny = PlateQuadrilateral(
            topLeft: CGPoint(x: 0.48375, y: 0.506875),
            topRight: CGPoint(x: 0.51625, y: 0.506875),
            bottomRight: CGPoint(x: 0.51625, y: 0.493125),
            bottomLeft: CGPoint(x: 0.48375, y: 0.493125)
        )

        XCTAssertNil(DepthCentroidPoseEstimator().estimate(
            quadrilateral: tiny,
            calibration: calibration,
            depthSamples: samples
        ))
    }

    func testThreeLowConfidenceDepthSamplesCannotProduceStrictPose() {
        let calibration = CameraCalibration(
            intrinsics: intrinsics(),
            cameraToWorld: matrix_identity_float4x4,
            imageSize: SIMD2(400, 200)
        )
        let samples = [
            SIMD3<Float>(-0.1, 0, -2),
            SIMD3<Float>(0, 0, -2),
            SIMD3<Float>(0.1, 0, -2)
        ].map {
            DepthSample(imagePoint: .zero, depth: 2, confidence: 0, worldPoint: $0)
        }

        XCTAssertNil(PlatePoseEstimator().estimate(
            quadrilateral: scaleConsistentQuad(),
            calibration: calibration,
            depthSamples: samples
        ))
    }

    func testStrictPoseUsesPlateCenterRayInsteadOfOffsetSupportCentroid() throws {
        var poseIntrinsics = intrinsics()
        poseIntrinsics[0, 0] = 800
        poseIntrinsics[1, 1] = 800
        let calibration = CameraCalibration(
            intrinsics: poseIntrinsics,
            cameraToWorld: matrix_identity_float4x4,
            imageSize: SIMD2(400, 200)
        )
        let offsetSupport = [
            SIMD3<Float>(0.20, -0.02, -2),
            SIMD3<Float>(0.25, 0, -2),
            SIMD3<Float>(0.30, 0.02, -2)
        ].map {
            DepthSample(imagePoint: .zero, depth: 2, confidence: 2, worldPoint: $0)
        }

        let estimate = try XCTUnwrap(PlatePoseEstimator().estimate(
            quadrilateral: quad,
            calibration: calibration,
            depthSamples: offsetSupport
        ))

        XCTAssertEqual(estimate.worldTransform.columns.3.x, 0, accuracy: 0.001)
        XCTAssertEqual(estimate.worldTransform.columns.3.z, -2, accuracy: 0.001)
    }

    func testProjectiveCenterOfSkewedPlateDiffersFromCornerAverage() throws {
        let calibration = skewedCalibration()
        let quadrilateral = skewedStandardPlateQuad(calibration: calibration)
        let projectiveCenter = try XCTUnwrap(quadrilateral.projectiveCenter)
        let cornerAverage = [
            quadrilateral.topLeft,
            quadrilateral.topRight,
            quadrilateral.bottomRight,
            quadrilateral.bottomLeft
        ].reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x / 4, y: $0.y + $1.y / 4)
        }

        XCTAssertGreaterThan(hypot(projectiveCenter.x - cornerAverage.x, projectiveCenter.y - cornerAverage.y), 0.001)
        XCTAssertEqual(projectiveCenter.x, 0.68, accuracy: 0.001)
        XCTAssertEqual(projectiveCenter.y, 0.38, accuracy: 0.001)
    }

    func testStrictAndFallbackPoseUseSameProjectiveCenterForSkewedPlate() throws {
        let calibration = skewedCalibration()
        let quadrilateral = skewedStandardPlateQuad(calibration: calibration)
        let center = try XCTUnwrap(quadrilateral.projectiveCenter)
        let imagePoint = SIMD2(
            Float(center.x) * Float(calibration.imageSize.x),
            (1 - Float(center.y)) * Float(calibration.imageSize.y)
        )
        let expected = try XCTUnwrap(DepthSampler().backProject(
            imagePoint: imagePoint,
            depth: 2,
            calibration: calibration
        ))
        let offsetSupport = [
            expected + SIMD3<Float>(0.12, -0.02, 0),
            expected + SIMD3<Float>(0.16, 0, 0),
            expected + SIMD3<Float>(0.20, 0.02, 0)
        ].map {
            DepthSample(imagePoint: .zero, depth: 2, confidence: 2, worldPoint: $0)
        }

        let strict = try XCTUnwrap(PlatePoseEstimator().estimate(
            quadrilateral: quadrilateral,
            calibration: calibration,
            depthSamples: offsetSupport
        ))
        let fallback = try XCTUnwrap(DepthCentroidPoseEstimator().estimate(
            quadrilateral: quadrilateral,
            calibration: calibration,
            depthSamples: offsetSupport
        ))
        let strictPosition = SIMD3(
            strict.worldTransform.columns.3.x,
            strict.worldTransform.columns.3.y,
            strict.worldTransform.columns.3.z
        )
        let fallbackPosition = SIMD3(
            fallback.worldTransform.columns.3.x,
            fallback.worldTransform.columns.3.y,
            fallback.worldTransform.columns.3.z
        )

        XCTAssertLessThan(simd_distance(strictPosition, expected), 0.001)
        XCTAssertLessThan(simd_distance(fallbackPosition, expected), 0.001)
        XCTAssertLessThan(simd_distance(strictPosition, fallbackPosition), 0.001)
    }

    private func scaleConsistentQuad() -> PlateQuadrilateral {
        PlateQuadrilateral(
            topLeft: CGPoint(x: 0.435, y: 0.5275),
            topRight: CGPoint(x: 0.565, y: 0.5275),
            bottomRight: CGPoint(x: 0.565, y: 0.4725),
            bottomLeft: CGPoint(x: 0.435, y: 0.4725)
        )
    }

    private func intrinsics() -> simd_float3x3 {
        simd_float3x3(
            SIMD3(200, 0, 0),
            SIMD3(0, 200, 0),
            SIMD3(200, 100, 1)
        )
    }

    private func skewedCalibration() -> CameraCalibration {
        CameraCalibration(
            intrinsics: simd_float3x3(
                SIMD3(800, 0, 0),
                SIMD3(0, 800, 0),
                SIMD3(200, 100, 1)
            ),
            cameraToWorld: matrix_identity_float4x4,
            imageSize: SIMD2(400, 200)
        )
    }

    private func skewedStandardPlateQuad(calibration: CameraCalibration) -> PlateQuadrilateral {
        let yaw = Float.pi / 6
        let pitch = Float.pi / 12
        let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        let down = SIMD3<Float>(sin(yaw) * sin(pitch), cos(pitch), cos(yaw) * sin(pitch))
        let translation = SIMD3<Float>(0.18, 0.06, 2)
        let halfWidth = PlatePhysicalSize.standard.meters.x / 2
        let halfHeight = PlatePhysicalSize.standard.meters.y / 2

        func project(x: Float, y: Float) -> CGPoint {
            let camera = right * x + down * y + translation
            let u = calibration.intrinsics[0, 0] * camera.x / camera.z + calibration.intrinsics[2, 0]
            let v = calibration.intrinsics[1, 1] * camera.y / camera.z + calibration.intrinsics[2, 1]
            return CGPoint(
                x: CGFloat(u / Float(calibration.imageSize.x)),
                y: CGFloat(1 - v / Float(calibration.imageSize.y))
            )
        }

        return PlateQuadrilateral(
            topLeft: project(x: -halfWidth, y: -halfHeight),
            topRight: project(x: halfWidth, y: -halfHeight),
            bottomRight: project(x: halfWidth, y: halfHeight),
            bottomLeft: project(x: -halfWidth, y: halfHeight)
        )
    }
}
