import Foundation
import simd

enum PlatePhysicalSize: CaseIterable, Equatable, Sendable {
    case standard
    case motorcycle
    case compact

    var meters: SIMD2<Float> {
        switch self {
        case .standard: SIMD2(0.520, 0.110)
        case .motorcycle: SIMD2(0.340, 0.210)
        case .compact: SIMD2(0.310, 0.110)
        }
    }
}

struct PlatePoseEstimate: Sendable {
    let worldTransform: simd_float4x4
    let distance: Float
    let confidence: Float
    let physicalSize: PlatePhysicalSize
    let meshAgreement: Bool
    let source: PoseSource
}

enum PoseSource: String, Equatable, Sendable {
    case planarDepth
    case meshFused
    case depthOnly
}

struct PlatePoseEstimator: Sendable {
    func estimate(
        quadrilateral: PlateQuadrilateral,
        calibration: CameraCalibration,
        depthSamples: [DepthSample],
        meshWorldPoints: [MeshSample] = [],
        allowedSizes: [PlatePhysicalSize] = PlatePhysicalSize.allCases
    ) -> PlatePoseEstimate? {
        let mediumOrHighConfidenceSamples = depthSamples.count { $0.confidence >= 1 }
        guard depthSamples.count >= 3,
              mediumOrHighConfidenceSamples >= 3 || depthSamples.count >= 5 else { return nil }
        let centroid = depthSamples.map(\.worldPoint).reduce(.zero, +) / Float(depthSamples.count)
        let distances = depthSamples.map(\.depth).sorted()
        let distance = distances[distances.count / 2]
        guard (0.4...12).contains(distance),
              let centerPoint = quadrilateral.projectiveCenter else { return nil }
        let centerImagePoint = SIMD2(
            Float(centerPoint.x) * Float(calibration.imageSize.x),
            (1 - Float(centerPoint.y)) * Float(calibration.imageSize.y)
        )
        guard let depthCenterPosition = DepthSampler().backProject(
            imagePoint: centerImagePoint,
            depth: distance,
            calibration: calibration
        ),
        simd_distance(depthCenterPosition, centroid) < max(0.5, distance * 0.25) else { return nil }

        let solutions = allowedSizes.compactMap {
            PlanarPoseSolver().solve(
                quadrilateral: quadrilateral,
                calibration: calibration,
                physicalSize: $0
            )
        }
        guard let planar = solutions.min(by: {
            score($0, depthDistance: distance) < score($1, depthDistance: distance)
        }) else { return nil }
        let distanceDisagreement = abs(planar.distance - distance)
        guard distanceDisagreement < max(0.35, distance * 0.18),
              planar.scaleMismatch < 0.3,
              planar.orthogonalityError < 0.18,
              planar.reprojectionError < 5 else { return nil }

        let planarPosition = SIMD3(
            planar.worldTransform.columns.3.x,
            planar.worldTransform.columns.3.y,
            planar.worldTransform.columns.3.z
        )
        guard simd_distance(planarPosition, depthCenterPosition) < max(0.4, distance * 0.2) else { return nil }

        let planarNormal = simd_normalize(SIMD3(
            planar.worldTransform.columns.2.x,
            planar.worldTransform.columns.2.y,
            planar.worldTransform.columns.2.z
        ))
        let meshPlane: MeshPlane?
        if meshWorldPoints.isEmpty {
            meshPlane = nil
        } else {
            guard let validated = validatedMeshPlane(
                samples: meshWorldPoints,
                depthCentroid: depthCenterPosition,
                planarPosition: planarPosition,
                planarNormal: planarNormal
            ) else { return nil }
            meshPlane = validated
        }
        let meshAgrees = meshPlane != nil

        let fusedPosition: SIMD3<Float>
        if let meshPlane,
           let ray = CameraRayProjector().worldRay(for: centerPoint, calibration: calibration),
           let meshCenter = intersection(ray: ray, plane: meshPlane),
           simd_distance(meshCenter, depthCenterPosition) <= max(0.35, distance * 0.16),
           simd_distance(meshCenter, planarPosition) <= max(0.4, distance * 0.18) {
            fusedPosition = meshCenter * 0.7 + depthCenterPosition * 0.2 + planarPosition * 0.1
        } else {
            guard meshPlane == nil else { return nil }
            // Use the robust median axial depth on the detected plate-center ray,
            // so surrounding support samples cannot drag the attachment sideways.
            // The planar solve still supplies orientation and gates quality.
            fusedPosition = depthCenterPosition
        }
        var transform = planar.worldTransform
        transform.columns.3 = SIMD4(fusedPosition, 1)
        let confidence = max(
            0,
            min(1, 1 - distanceDisagreement / max(distance, 0.1) - planar.scaleMismatch * 0.5)
        )
        return PlatePoseEstimate(
            worldTransform: transform,
            distance: distance,
            confidence: confidence,
            physicalSize: planar.physicalSize,
            meshAgreement: meshAgrees,
            source: meshAgrees ? .meshFused : .planarDepth
        )
    }

    private func score(_ solution: PlanarPoseSolution, depthDistance: Float) -> Float {
        abs(solution.distance - depthDistance) / max(depthDistance, 0.1) +
            solution.scaleMismatch * 0.7 + solution.orthogonalityError * 0.8 + solution.reprojectionError / 100
    }

    private struct MeshPlane {
        let centroid: SIMD3<Float>
        let normal: SIMD3<Float>
    }

    private func validatedMeshPlane(
        samples: [MeshSample],
        depthCentroid: SIMD3<Float>,
        planarPosition: SIMD3<Float>,
        planarNormal: SIMD3<Float>
    ) -> MeshPlane? {
        var distinct: [MeshSample] = []
        for sample in samples where sample.worldPoint.x.isFinite && sample.worldPoint.y.isFinite && sample.worldPoint.z.isFinite {
            guard !distinct.contains(where: {
                hypot($0.imagePoint.x - sample.imagePoint.x, $0.imagePoint.y - sample.imagePoint.y) < 0.004
            }) else { continue }
            distinct.append(sample)
        }
        guard distinct.count >= 3 else { return nil }
        let points = distinct.map(\.worldPoint)
        let centroid = points.reduce(.zero, +) / Float(points.count)
        guard simd_distance(centroid, depthCentroid) <= 0.28,
              simd_distance(centroid, planarPosition) <= 0.4 else { return nil }

        var bestCross = SIMD3<Float>.zero
        for first in 0..<(points.count - 2) {
            for second in (first + 1)..<(points.count - 1) {
                for third in (second + 1)..<points.count {
                    let candidate = simd_cross(points[second] - points[first], points[third] - points[first])
                    if simd_length_squared(candidate) > simd_length_squared(bestCross) {
                        bestCross = candidate
                    }
                }
            }
        }
        guard simd_length(bestCross) >= 0.001 else { return nil }
        let normal = simd_normalize(bestCross)
        guard abs(simd_dot(normal, planarNormal)) >= 0.75 else { return nil }
        let maximumPlaneResidual = points.map { abs(simd_dot($0 - centroid, normal)) }.max() ?? .infinity
        guard maximumPlaneResidual <= 0.06 else { return nil }

        let maximumSpan = points.indices.flatMap { first in
            points.indices.filter { $0 > first }.map { simd_distance(points[first], points[$0]) }
        }.max() ?? 0
        guard maximumSpan >= 0.04 else { return nil }

        let planarResidual = points.map { abs(simd_dot($0 - planarPosition, planarNormal)) }.max() ?? .infinity
        guard planarResidual <= 0.18 else { return nil }
        return MeshPlane(centroid: centroid, normal: normal)
    }

    private func intersection(ray: WorldRay, plane: MeshPlane) -> SIMD3<Float>? {
        let denominator = simd_dot(ray.direction, plane.normal)
        guard abs(denominator) > 0.05 else { return nil }
        let distance = simd_dot(plane.centroid - ray.origin, plane.normal) / denominator
        guard distance.isFinite, (0.4...12).contains(distance) else { return nil }
        return ray.origin + ray.direction * distance
    }
}
