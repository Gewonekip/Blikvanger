import CoreGraphics
import Foundation
import ImageIO
import Vision

protocol PlateDetecting: Sendable {
    func detect(in image: CGImage, orientation: CGImagePropertyOrientation, timestamp: TimeInterval) throws -> [PlateDetection]
}

protocol PlateTextLocalizing: Sendable {
    func locate(in image: CGImage, orientation: CGImagePropertyOrientation, timestamp: TimeInterval) throws -> [PlateDetection]
}

struct VisionPlateDetector: PlateDetecting {
    func detect(in image: CGImage, orientation: CGImagePropertyOrientation = .up, timestamp: TimeInterval) throws -> [PlateDetection] {
        let request = VNDetectRectanglesRequest()
        // Rectangle confidence is not plate confidence. Keep this first stage
        // recall-oriented and let plate geometry, depth, mesh, and OCR reject
        // incidental rectangles later in the pipeline.
        request.maximumObservations = 40
        request.minimumConfidence = 0.35
        request.minimumAspectRatio = 0.12
        request.maximumAspectRatio = 0.95
        request.minimumSize = 0.006
        request.quadratureTolerance = 35
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        try handler.perform([request])
        let detections = (request.results ?? []).map { rectangle in
            PlateDetection(
                quadrilateral: PlateQuadrilateral(
                    topLeft: rectangle.topLeft,
                    topRight: rectangle.topRight,
                    bottomRight: rectangle.bottomRight,
                    bottomLeft: rectangle.bottomLeft
                ),
                confidence: rectangle.confidence,
                timestamp: timestamp
            )
        }
        return PlateDetectionGeometry().filterAndSuppress(
            detections,
            rawPixelSize: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
            orientation: orientation
        )
    }
}

/// Secondary recall path for distant plates whose characters are readable but whose
/// outer yellow edge is not returned by Vision's generic rectangle detector.
/// Domain validation and crop appearance happen before a localized region can
/// enter the temporal, spatial, OCR, or RDW pipeline.
struct VisionPlateTextLocalizer: PlateTextLocalizing {
    var minimumConfidence: Float = 0.30

    func locate(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval
    ) throws -> [PlateDetection] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.006
        request.recognitionLanguages = ["nl-NL", "en-US"]
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])

        let detections = (request.results ?? []).compactMap { observation -> PlateDetection? in
            guard let candidate = observation.topCandidates(3)
                .filter({
                    $0.confidence >= minimumConfidence
                        && DutchLicensePlate.recognizedPlate(in: $0.string) != nil
                })
                .max(by: { $0.confidence < $1.confidence }),
                let box = PlateTextLocalizationGeometry().expandedPlateBox(
                    around: observation.boundingBox
                ) else { return nil }
            return PlateDetection(
                quadrilateral: PlateQuadrilateral(
                    topLeft: CGPoint(x: box.minX, y: box.maxY),
                    topRight: CGPoint(x: box.maxX, y: box.maxY),
                    bottomRight: CGPoint(x: box.maxX, y: box.minY),
                    bottomLeft: CGPoint(x: box.minX, y: box.minY)
                ),
                confidence: candidate.confidence,
                timestamp: timestamp
            )
        }
        return PlateDetectionGeometry().filterAndSuppress(
            detections,
            rawPixelSize: CGSize(width: image.width, height: image.height),
            orientation: orientation
        )
    }
}

struct PlateTextLocalizationGeometry: Sendable {
    var horizontalPaddingFraction: CGFloat = 0.10
    var verticalPaddingFraction: CGFloat = 0.35

    func expandedPlateBox(around textBox: CGRect) -> CGRect? {
        guard textBox.minX.isFinite,
              textBox.minY.isFinite,
              textBox.width.isFinite,
              textBox.height.isFinite,
              textBox.width > 0,
              textBox.height > 0 else { return nil }
        let expanded = textBox.insetBy(
            dx: -textBox.width * horizontalPaddingFraction,
            dy: -textBox.height * verticalPaddingFraction
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !expanded.isNull, expanded.width > 0, expanded.height > 0 else { return nil }
        return expanded
    }
}

/// Pure image-geometry filtering kept separate from Vision so its orientation
/// behavior can be tested deterministically. Vision observations are normalized
/// in the EXIF-oriented image; normalized width and height therefore cannot be
/// divided directly when that image is not square.
struct PlateDetectionGeometry: Sendable {
    var acceptedPixelAspectRatio: ClosedRange<CGFloat> = 1.2...7
    var duplicateIntersectionOverUnion: CGFloat = 0.45
    var duplicateContainment: CGFloat = 0.82

    func orientedPixelSize(
        rawPixelSize: CGSize,
        orientation: CGImagePropertyOrientation
    ) -> CGSize {
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            CGSize(width: rawPixelSize.height, height: rawPixelSize.width)
        case .up, .down, .upMirrored, .downMirrored:
            rawPixelSize
        @unknown default:
            rawPixelSize
        }
    }

    func pixelAspectRatio(
        of normalizedBoundingBox: CGRect,
        rawPixelSize: CGSize,
        orientation: CGImagePropertyOrientation
    ) -> CGFloat? {
        let size = orientedPixelSize(rawPixelSize: rawPixelSize, orientation: orientation)
        let pixelWidth = normalizedBoundingBox.width * size.width
        let pixelHeight = normalizedBoundingBox.height * size.height
        guard pixelWidth.isFinite,
              pixelHeight.isFinite,
              pixelWidth > 0,
              pixelHeight > 0 else { return nil }
        return pixelWidth / pixelHeight
    }

    func accepts(
        normalizedBoundingBox: CGRect,
        rawPixelSize: CGSize,
        orientation: CGImagePropertyOrientation
    ) -> Bool {
        guard let ratio = pixelAspectRatio(
            of: normalizedBoundingBox,
            rawPixelSize: rawPixelSize,
            orientation: orientation
        ) else { return false }
        return acceptedPixelAspectRatio.contains(ratio)
    }

    func filterAndSuppress(
        _ detections: [PlateDetection],
        rawPixelSize: CGSize,
        orientation: CGImagePropertyOrientation
    ) -> [PlateDetection] {
        let candidates = detections.enumerated().compactMap { index, detection -> RankedDetection? in
            guard let aspectRatio = pixelAspectRatio(
                of: detection.boundingBox,
                rawPixelSize: rawPixelSize,
                orientation: orientation
            ), acceptedPixelAspectRatio.contains(aspectRatio) else { return nil }
            return RankedDetection(
                sourceIndex: index,
                detection: detection,
                aspectDistance: legalAspectDistance(aspectRatio)
            )
        }
        .sorted {
            if $0.detection.confidence != $1.detection.confidence {
                return $0.detection.confidence > $1.detection.confidence
            }
            if $0.aspectDistance != $1.aspectDistance {
                return $0.aspectDistance < $1.aspectDistance
            }
            let lhsArea = area($0.detection.boundingBox)
            let rhsArea = area($1.detection.boundingBox)
            if lhsArea != rhsArea { return lhsArea > rhsArea }
            return $0.sourceIndex < $1.sourceIndex
        }

        var retained: [RankedDetection] = []
        for candidate in candidates where !retained.contains(where: {
            representsSameRectangle(candidate.detection.boundingBox, $0.detection.boundingBox)
        }) {
            retained.append(candidate)
        }
        return retained.sorted { $0.sourceIndex < $1.sourceIndex }.map(\.detection)
    }

    private func legalAspectDistance(_ ratio: CGFloat) -> CGFloat {
        let legalRatios: [CGFloat] = [520 / 110, 340 / 210, 310 / 110]
        return legalRatios.map { abs(log(ratio / $0)) }.min() ?? .infinity
    }

    private func representsSameRectangle(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return false }
        let intersectionArea = area(intersection)
        guard intersectionArea > 0 else { return false }
        let lhsArea = area(lhs)
        let rhsArea = area(rhs)
        let unionArea = lhsArea + rhsArea - intersectionArea
        let smallerArea = min(lhsArea, rhsArea)
        let largerArea = max(lhsArea, rhsArea)
        let scaleSimilarity = largerArea > 0 ? smallerArea / largerArea : 0
        // A plate holder or bumper recess can tightly contain the yellow plate.
        // Preserve meaningfully different scales for the appearance stage; only
        // suppress near-equal rectangles that represent the same physical edge.
        // Keep even moderately different edges so the yellow-appearance stage,
        // rather than generic rectangle confidence, can choose between a plate,
        // its holder, and a bumper recess. Suppress only near-identical results.
        guard scaleSimilarity >= 0.94 else { return false }
        return (unionArea > 0 && intersectionArea / unionArea >= duplicateIntersectionOverUnion)
            || (smallerArea > 0 && intersectionArea / smallerArea >= duplicateContainment)
    }

    private func area(_ rectangle: CGRect) -> CGFloat {
        max(0, rectangle.width) * max(0, rectangle.height)
    }
}

private struct RankedDetection {
    let sourceIndex: Int
    let detection: PlateDetection
    let aspectDistance: CGFloat
}
