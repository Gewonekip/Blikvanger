import ARKit
import Foundation
import RealityKit
import simd

struct MeshSample: Equatable, Sendable {
    let imagePoint: CGPoint
    let worldPoint: SIMD3<Float>
}

struct WorldRay: Equatable, Sendable {
    let origin: SIMD3<Float>
    let direction: SIMD3<Float>
}

struct CameraRayProjector: Sendable {
    func worldRay(for rawVisionPoint: CGPoint, calibration: CameraCalibration) -> WorldRay? {
        guard rawVisionPoint.x.isFinite, rawVisionPoint.y.isFinite,
              (0...1).contains(rawVisionPoint.x), (0...1).contains(rawVisionPoint.y),
              calibration.imageSize.x > 0, calibration.imageSize.y > 0 else { return nil }
        let fx = calibration.intrinsics[0, 0]
        let fy = calibration.intrinsics[1, 1]
        let cx = calibration.intrinsics[2, 0]
        let cy = calibration.intrinsics[2, 1]
        guard fx.isFinite, fy.isFinite, fx > 0, fy > 0 else { return nil }

        let u = Float(rawVisionPoint.x) * Float(calibration.imageSize.x)
        let v = (1 - Float(rawVisionPoint.y)) * Float(calibration.imageSize.y)
        let cameraDirection = simd_normalize(SIMD3(
            (u - cx) / fx,
            -(v - cy) / fy,
            -1
        ))
        let worldDirection4 = calibration.cameraToWorld * SIMD4(cameraDirection, 0)
        let worldDirection = SIMD3(worldDirection4.x, worldDirection4.y, worldDirection4.z)
        guard simd_length_squared(worldDirection) > 0.000_001 else { return nil }
        let translation = calibration.cameraToWorld.columns.3
        return WorldRay(
            origin: SIMD3(translation.x, translation.y, translation.z),
            direction: simd_normalize(worldDirection)
        )
    }
}

@MainActor
struct MeshEvidenceProvider {
    /// Intersects scene-understanding geometry with rays derived from the exact
    /// snapshot camera, never from ARView's later display/camera transform.
    func worldPoints(
        for quadrilateral: PlateQuadrilateral,
        calibration: CameraCalibration,
        in arView: ARView
    ) -> [MeshSample] {
        guard let frame = arView.session.currentFrame,
              case .normal = frame.camera.trackingState else { return [] }

        return interiorPoints(quadrilateral).compactMap { imagePoint in
            guard let ray = CameraRayProjector().worldRay(for: imagePoint, calibration: calibration),
                  let hit = arView.scene.raycast(
                    origin: ray.origin,
                    direction: ray.direction,
                    length: 12,
                    query: .nearest,
                    mask: .sceneUnderstanding,
                    relativeTo: nil
                  ).first else { return nil }
            return MeshSample(imagePoint: imagePoint, worldPoint: hit.position)
        }
    }

    private func interiorPoints(_ quad: PlateQuadrilateral) -> [CGPoint] {
        func interpolate(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        let left = interpolate(quad.topLeft, quad.bottomLeft, 0.5)
        let right = interpolate(quad.topRight, quad.bottomRight, 0.5)
        let top = interpolate(quad.topLeft, quad.topRight, 0.5)
        let bottom = interpolate(quad.bottomLeft, quad.bottomRight, 0.5)
        return [
            quad.projectiveCenter ?? interpolate(left, right, 0.5),
            interpolate(left, right, 0.25),
            interpolate(left, right, 0.75),
            interpolate(top, bottom, 0.25),
            interpolate(top, bottom, 0.75)
        ]
    }
}
