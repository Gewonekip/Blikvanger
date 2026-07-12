import CoreGraphics
import Foundation
import simd

struct AnchorProjection: Equatable, Sendable {
    let trackID: UUID
    let point: CGPoint
    let depth: Float
    let isVisible: Bool
    let isInFront: Bool
}

/// Indexes the ARAnchor transforms delivered with one camera frame. Projection
/// must never fall back to a model-space transform when that frame does not
/// contain the corresponding world anchor.
struct FrameAnchorTransformIndex: Sendable {
    private let transformsByIdentifier: [UUID: simd_float4x4]

    init(transformsByIdentifier: [UUID: simd_float4x4]) {
        self.transformsByIdentifier = transformsByIdentifier
    }

    func transform(for anchorIdentifier: UUID) -> simd_float4x4? {
        transformsByIdentifier[anchorIdentifier]
    }
}

struct AnchorProjectionService: Sendable {
    /// Projects a world point using a Metal-style clip transform where visible z is 0...w.
    func project(
        trackID: UUID,
        worldPoint: SIMD3<Float>,
        viewProjection: simd_float4x4,
        viewport: CGSize,
        cameraWorldPosition: SIMD3<Float> = .zero
    ) -> AnchorProjection {
        let clip = viewProjection * SIMD4(worldPoint.x, worldPoint.y, worldPoint.z, 1)
        guard clip.w > 0.0001 else {
            return AnchorProjection(
                trackID: trackID,
                point: .zero,
                depth: simd_distance(cameraWorldPosition, worldPoint),
                isVisible: false,
                isInFront: false
            )
        }
        let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
        let point = CGPoint(
            x: CGFloat((ndc.x + 1) * 0.5) * viewport.width,
            y: CGFloat((1 - ndc.y) * 0.5) * viewport.height
        )
        let inFront = ndc.z >= 0 && ndc.z <= 1
        let visible = inFront &&
            point.x >= 0 && point.x <= viewport.width &&
            point.y >= 0 && point.y <= viewport.height
        return AnchorProjection(
            trackID: trackID,
            point: point,
            depth: simd_distance(cameraWorldPosition, worldPoint),
            isVisible: visible,
            isInFront: inFront
        )
    }

    /// Keeps a readable annotation available when the measured car/plate base is
    /// visible but its gravity-aligned card attachment sits above the viewport.
    /// Card layout can then clamp the offscreen desired point into the safe area.
    func projectAnnotation(
        trackID: UUID,
        baseWorldPoint: SIMD3<Float>,
        attachmentWorldPoint: SIMD3<Float>,
        viewProjection: simd_float4x4,
        viewport: CGSize,
        cameraWorldPosition: SIMD3<Float> = .zero
    ) -> AnchorProjection {
        let base = project(
            trackID: trackID,
            worldPoint: baseWorldPoint,
            viewProjection: viewProjection,
            viewport: viewport,
            cameraWorldPosition: cameraWorldPosition
        )
        let attachment = project(
            trackID: trackID,
            worldPoint: attachmentWorldPoint,
            viewProjection: viewProjection,
            viewport: viewport,
            cameraWorldPosition: cameraWorldPosition
        )
        if attachment.isVisible { return attachment }
        guard base.isVisible else { return attachment }
        guard attachment.isInFront else { return base }
        return AnchorProjection(
            trackID: trackID,
            point: attachment.point,
            depth: base.depth,
            isVisible: true,
            isInFront: true
        )
    }
}
