import Foundation
import simd

struct PoseFusion: Sendable {
    var minimumSamples = 3
    var maximumSpread: Float = 0.18
    var maximumAngularSpread: Float = .pi / 12

    func stableTransform(from samples: [PoseSample]) -> simd_float4x4? {
        guard samples.count >= minimumSamples else { return nil }
        let positions = samples.map { SIMD3($0.worldTransform.columns.3.x, $0.worldTransform.columns.3.y, $0.worldTransform.columns.3.z) }
        let median = SIMD3(
            componentMedian(positions.map(\.x)),
            componentMedian(positions.map(\.y)),
            componentMedian(positions.map(\.z))
        )
        let positionInliers = zip(samples, positions).filter {
            $0.0.confidence.isFinite && simd_distance($0.1, median) <= maximumSpread
        }.map(\.0)
        let requiredInliers = max(minimumSamples, Int(ceil(Double(samples.count) * 0.7)))
        guard positionInliers.count >= requiredInliers else { return nil }

        let quaternions = positionInliers.map { rotation(of: $0.worldTransform) }
        guard let referenceIndex = quaternions.indices.max(by: { lhs, rhs in
            neighborCount(of: quaternions[lhs], among: quaternions) <
                neighborCount(of: quaternions[rhs], among: quaternions)
        }) else { return nil }
        let reference = quaternions[referenceIndex]
        let inliers = zip(positionInliers, quaternions).filter {
            angularDistance($0.1, reference) <= maximumAngularSpread
        }
        guard inliers.count >= requiredInliers else { return nil }

        let totalWeight = inliers.reduce(Float.zero) { $0 + max($1.0.confidence, 0.01) }
        let position = inliers.reduce(SIMD3<Float>.zero) { partial, item in
            let sample = item.0
            let p = SIMD3(sample.worldTransform.columns.3.x, sample.worldTransform.columns.3.y, sample.worldTransform.columns.3.z)
            return partial + p * max(sample.confidence, 0.01)
        } / totalWeight
        let quaternionVector = inliers.reduce(SIMD4<Float>.zero) { partial, item in
            let sample = item.0
            let quaternion = item.1
            let aligned = simd_dot(quaternion.vector, reference.vector) < 0
                ? -quaternion.vector
                : quaternion.vector
            return partial + aligned * max(sample.confidence, 0.01)
        }
        guard simd_length_squared(quaternionVector) > 0.000_001 else { return nil }
        let orientation = simd_quatf(vector: simd_normalize(quaternionVector))
        var result = simd_float4x4(orientation)
        result.columns.3 = SIMD4(position, 1)
        return result
    }

    func estimatorsAgree(
        _ a: simd_float4x4,
        _ b: simd_float4x4,
        tolerance: Float = 0.25,
        angularTolerance: Float = .pi / 9
    ) -> Bool {
        let pa = SIMD3(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let pb = SIMD3(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        return simd_distance(pa, pb) <= tolerance &&
            angularDistance(rotation(of: a), rotation(of: b)) <= angularTolerance
    }

    private func componentMedian(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func neighborCount(of quaternion: simd_quatf, among quaternions: [simd_quatf]) -> Int {
        quaternions.count { angularDistance($0, quaternion) <= maximumAngularSpread }
    }

    private func angularDistance(_ lhs: simd_quatf, _ rhs: simd_quatf) -> Float {
        let cosine = min(1, max(0, abs(simd_dot(lhs.vector, rhs.vector))))
        return 2 * acos(cosine)
    }

    private func rotation(of transform: simd_float4x4) -> simd_quatf {
        simd_quatf(simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        ))
    }
}
