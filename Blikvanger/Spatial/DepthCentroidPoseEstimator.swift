import Foundation
import simd

/// Translation-only depth pose for a plate-like yellow rectangle with coherent
/// LiDAR samples. The hybrid UI needs a stable measured world attachment point;
/// a strict four-corner planar orientation is useful refinement, but should not
/// prevent placement when reflective plate material perturbs its corners/depth.
struct DepthCentroidPoseEstimator: Sendable {
    func estimate(
        quadrilateral: PlateQuadrilateral,
        calibration: CameraCalibration,
        depthSamples: [DepthSample]
    ) -> PlatePoseEstimate? {
        let valid = depthSamples.filter {
            $0.depth.isFinite
                && (0.4...12).contains($0.depth)
                && $0.worldPoint.x.isFinite
                && $0.worldPoint.y.isFinite
                && $0.worldPoint.z.isFinite
        }
        guard valid.count >= 3 else { return nil }

        let sortedDepths = valid.map(\.depth).sorted()
        let distance = sortedDepths[sortedDepths.count / 2]
        let tolerance = max(0.12, distance * 0.08)
        let inliers = valid.filter { abs($0.depth - distance) <= tolerance }
        let containsMediumOrHighConfidence = inliers.contains { $0.confidence >= 1 }
        guard inliers.count >= (containsMediumOrHighConfidence ? 3 : 5) else { return nil }

        let centroid = inliers.map(\.worldPoint).reduce(.zero, +) / Float(inliers.count)
        let maximumRadius = inliers.map { simd_distance($0.worldPoint, centroid) }.max() ?? .infinity
        guard maximumRadius <= max(0.45, distance * 0.22),
              let physicalSize = plausiblePhysicalSize(
                quadrilateral: quadrilateral,
                calibration: calibration,
                distance: distance
              ) else { return nil }

        guard let center = quadrilateral.projectiveCenter else { return nil }
        let centerImagePoint = SIMD2(
            Float(center.x) * Float(calibration.imageSize.x),
            (1 - Float(center.y)) * Float(calibration.imageSize.y)
        )
        guard let centerWorldPoint = DepthSampler().backProject(
            imagePoint: centerImagePoint,
            depth: distance,
            calibration: calibration
        ),
        simd_distance(centerWorldPoint, centroid) <= max(0.5, distance * 0.25) else { return nil }

        var transform = matrix_identity_float4x4
        // Surrounding bumper/body samples may provide the only reliable depth,
        // but they must not drag the attachment sideways. Use their robust median
        // distance along the detected plate center ray for the final translation.
        transform.columns.3 = SIMD4(centerWorldPoint, 1)
        let meanConfidence = inliers.reduce(Float.zero) { $0 + Float($1.confidence) / 2 } / Float(inliers.count)
        let maximumResidual = inliers.map { abs($0.depth - distance) }.max() ?? tolerance
        let coherence = max(0.35, 1 - maximumResidual / tolerance)
        return PlatePoseEstimate(
            worldTransform: transform,
            distance: distance,
            confidence: min(0.82, max(0.2, meanConfidence * coherence)),
            physicalSize: physicalSize,
            meshAgreement: false,
            source: .depthOnly
        )
    }

    private func plausiblePhysicalSize(
        quadrilateral: PlateQuadrilateral,
        calibration: CameraCalibration,
        distance: Float
    ) -> PlatePhysicalSize? {
        let imageSize = calibration.imageSize
        guard imageSize.x > 0, imageSize.y > 0 else { return nil }
        func pixels(_ point: CGPoint) -> SIMD2<Float> {
            SIMD2(Float(point.x) * Float(imageSize.x), Float(point.y) * Float(imageSize.y))
        }
        let topWidth = simd_distance(pixels(quadrilateral.topLeft), pixels(quadrilateral.topRight))
        let bottomWidth = simd_distance(pixels(quadrilateral.bottomLeft), pixels(quadrilateral.bottomRight))
        let leftHeight = simd_distance(pixels(quadrilateral.topLeft), pixels(quadrilateral.bottomLeft))
        let rightHeight = simd_distance(pixels(quadrilateral.topRight), pixels(quadrilateral.bottomRight))
        let width = (topWidth + bottomWidth) / 2
        let height = (leftHeight + rightHeight) / 2
        let focalLength = (calibration.intrinsics[0, 0] + calibration.intrinsics[1, 1]) / 2
        guard width.isFinite,
              height.isFinite,
              width > 1,
              height > 1,
              focalLength.isFinite,
              focalLength > 0,
              distance.isFinite,
              distance > 0 else { return nil }

        return PlatePhysicalSize.allCases.compactMap { size -> (size: PlatePhysicalSize, score: Float)? in
            let expectedWidth = focalLength * size.meters.x / distance
            let expectedHeight = focalLength * size.meters.y / distance
            guard expectedWidth > 0, expectedHeight > 0 else { return nil }
            let widthRatio = width / expectedWidth
            let heightRatio = height / expectedHeight
            // Off-axis viewing foreshortens a dimension, while depth noise and
            // loose rectangle edges can enlarge it modestly. A car window or
            // picture frame is typically many times the legal plate scale.
            guard (0.30...1.45).contains(widthRatio),
                  (0.30...1.55).contains(heightRatio),
                  max(widthRatio, heightRatio) >= 0.65 else { return nil }
            let score = abs(log(widthRatio)) + abs(log(heightRatio)) * 0.8
            return (size, score)
        }
        .min { $0.score < $1.score }?
        .size
    }
}
