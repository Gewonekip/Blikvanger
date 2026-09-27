import ARKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

enum DepthSource: String, Equatable, Sendable {
    case smoothedSceneDepth
    case sceneDepth
}

/// Immutable image/depth data copied from one ARFrame before crossing from the
/// ARSession delegate queue to Vision actors. The unchecked conformance is
/// limited to the immutable CGImage reference; no live CVPixelBuffer or ARFrame
/// escapes this snapshot.
struct ARFrameSnapshot: @unchecked Sendable {
    let image: CGImage
    let depthGrid: DepthGrid
    let calibration: CameraCalibration
    let timestamp: TimeInterval
    let visionOrientation: CGImagePropertyOrientation
    let trackingWasNormal: Bool
    let depthSource: DepthSource
    let generation: UInt64
    let droppedFrames: Int

    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    init(
        image: CGImage,
        depthGrid: DepthGrid,
        calibration: CameraCalibration,
        timestamp: TimeInterval,
        visionOrientation: CGImagePropertyOrientation,
        trackingWasNormal: Bool = true,
        depthSource: DepthSource = .sceneDepth,
        generation: UInt64,
        droppedFrames: Int
    ) {
        self.image = image
        self.depthGrid = depthGrid
        self.calibration = calibration
        self.timestamp = timestamp
        self.visionOrientation = visionOrientation
        self.trackingWasNormal = trackingWasNormal
        self.depthSource = depthSource
        self.generation = generation
        self.droppedFrames = droppedFrames
    }

    static func make(
        from frame: ARFrame,
        admission: FrameAdmission,
        visionOrientation: CGImagePropertyOrientation = .right
    ) -> ARFrameSnapshot? {
        // Prefer ARKit's temporally stabilized depth, but preserve which source
        // was used so downstream quality decisions never treat the two equally.
        let sceneDepth: ARDepthData
        let depthSource: DepthSource
        if let smoothedDepth = frame.smoothedSceneDepth {
            sceneDepth = smoothedDepth
            depthSource = .smoothedSceneDepth
        } else if let rawDepth = frame.sceneDepth {
            sceneDepth = rawDepth
            depthSource = .sceneDepth
        } else {
            return nil
        }
        let capturedImage = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: capturedImage)
        guard let image = imageContext.createCGImage(ciImage, from: ciImage.extent),
              let grid = copyDepth(depth: sceneDepth.depthMap, confidence: sceneDepth.confidenceMap) else { return nil }
        let resolution = frame.camera.imageResolution
        let trackingWasNormal: Bool
        if case .normal = frame.camera.trackingState {
            trackingWasNormal = true
        } else {
            trackingWasNormal = false
        }
        return ARFrameSnapshot(
            image: image,
            depthGrid: grid,
            calibration: CameraCalibration(
                intrinsics: frame.camera.intrinsics,
                cameraToWorld: frame.camera.transform,
                imageSize: SIMD2(Int(resolution.width), Int(resolution.height))
            ),
            timestamp: frame.timestamp,
            visionOrientation: visionOrientation,
            trackingWasNormal: trackingWasNormal,
            depthSource: depthSource,
            generation: admission.generation,
            droppedFrames: admission.droppedFrames
        )
    }

    private static func copyDepth(depth: CVPixelBuffer, confidence: CVPixelBuffer?) -> DepthGrid? {
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)
        let rowBytes = CVPixelBufferGetBytesPerRow(depth)
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        var values = Array(repeating: Float.nan, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width { values[y * width + x] = row[x] }
        }

        // A missing confidence map is unknown evidence, never implicitly high.
        var confidenceValues = Array(repeating: UInt8(0), count: width * height)
        if let confidence {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
            if let confidenceBase = CVPixelBufferGetBaseAddress(confidence) {
                let confidenceWidth = CVPixelBufferGetWidth(confidence)
                let confidenceHeight = CVPixelBufferGetHeight(confidence)
                let confidenceRows = CVPixelBufferGetBytesPerRow(confidence)
                for y in 0..<height {
                    let sourceY = min(y * confidenceHeight / max(height, 1), confidenceHeight - 1)
                    let row = confidenceBase.advanced(by: sourceY * confidenceRows).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        let sourceX = min(x * confidenceWidth / max(width, 1), confidenceWidth - 1)
                        confidenceValues[y * width + x] = row[sourceX]
                    }
                }
            }
        }
        return DepthGrid(width: width, height: height, depths: values, confidences: confidenceValues)
    }
}
