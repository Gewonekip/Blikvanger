import CoreImage
import Foundation

enum VisionWorkerFailure: String, Error, Equatable, Sendable {
    case rectangleDetection
    case textLocalization
    case cropPreparation
    case recognition
}

enum PlateDetectionOutcome: Sendable {
    case success([PlateDetection])
    case failed(VisionWorkerFailure)
}

actor PlateDetectionWorker {
    private let detector: any PlateDetecting
    private let textLocalizer: any PlateTextLocalizing
    private let appearanceScorer: any PlateAppearanceScoring
    private let mapper = ImageCoordinateMapper()
    private let geometry = PlateDetectionGeometry()
    private let perspectiveCorrector = PerspectiveCorrector()
    private let minimumContinuationOverlap: CGFloat = 0.06
    private let maximumContinuationScorePenalty: CGFloat = 0.30
    private let textLocalizationInterval: TimeInterval = 0.40
    private var previousSelection: PlateDetection?
    private var previousGeneration: UInt64?
    private var lastTextLocalizationTimestamp = -TimeInterval.infinity

    init(
        detector: any PlateDetecting = VisionPlateDetector(),
        textLocalizer: any PlateTextLocalizing = VisionPlateTextLocalizer(),
        appearanceScorer: any PlateAppearanceScoring = PlateAppearanceScorer()
    ) {
        self.detector = detector
        self.textLocalizer = textLocalizer
        self.appearanceScorer = appearanceScorer
    }

    func detectResult(snapshot: ARFrameSnapshot) -> PlateDetectionOutcome {
        guard !Task.isCancelled else { return .success([]) }
        if previousGeneration != snapshot.generation {
            previousSelection = nil
            previousGeneration = snapshot.generation
            lastTextLocalizationTimestamp = -.infinity
        }
        let rawRectangles: [PlateDetection]
        do {
            rawRectangles = try detector.detect(
                in: snapshot.image,
                orientation: snapshot.visionOrientation,
                timestamp: snapshot.timestamp
            )
        } catch {
            return .failed(.rectangleDetection)
        }
        guard !Task.isCancelled else { return .success([]) }
        // Vision already bounds this collection to 40 rectangles. Score every
        // geometrically legal rectangle so a small, distant plate anywhere in
        // the usable image cannot be starved by stronger bumper/window edges.
        var candidates = appearanceCandidates(from: rawRectangles, snapshot: snapshot)
        if candidates.isEmpty,
           snapshot.timestamp - lastTextLocalizationTimestamp >= textLocalizationInterval {
            lastTextLocalizationTimestamp = snapshot.timestamp
            let textRegions: [PlateDetection]
            do {
                textRegions = try textLocalizer.locate(
                    in: snapshot.image,
                    orientation: snapshot.visionOrientation,
                    timestamp: snapshot.timestamp
                )
            } catch {
                return .failed(.textLocalization)
            }
            guard !Task.isCancelled else { return .success([]) }
            candidates = appearanceCandidates(from: textRegions, snapshot: snapshot)
        }
        let best = candidates.min { isHigherPriority($0, than: $1, snapshot: snapshot) }
        let continuation = previousSelection.flatMap { previous -> AppearanceCandidate? in
            guard snapshot.timestamp - previous.timestamp <= 0.75 else { return nil }
            return candidates
                .filter {
                    intersectionOverUnion($0.detection.boundingBox, previous.boundingBox)
                        >= minimumContinuationOverlap
                }
                .max {
                    let lhsOverlap = intersectionOverUnion($0.detection.boundingBox, previous.boundingBox)
                    let rhsOverlap = intersectionOverUnion($1.detection.boundingBox, previous.boundingBox)
                    if lhsOverlap != rhsOverlap { return lhsOverlap < rhsOverlap }
                    return isHigherPriority($1, than: $0, snapshot: snapshot)
                }
        }
        let selectedCandidate: AppearanceCandidate?
        if let best, let continuation,
           platePriority(continuation, snapshot: snapshot)
            <= platePriority(best, snapshot: snapshot) + maximumContinuationScorePenalty {
            selectedCandidate = continuation
        } else {
            selectedCandidate = best
        }
        let selected = selectedCandidate?.detection
        if let selected {
            previousSelection = selected
        } else if let previousSelection,
                  snapshot.timestamp - previousSelection.timestamp > 0.75 {
            self.previousSelection = nil
        }
        guard let selected else { return .success([]) }
        return .success([PlateDetection(
            quadrilateral: mapper.visionQuadrilateralToRaw(
                selected.quadrilateral,
                orientation: snapshot.visionOrientation
            ),
            confidence: selected.confidence,
            timestamp: selected.timestamp
        )])
    }

    // Kept as a small convenience for deterministic unit tests. Production
    // code uses detectResult so an unavailable Vision request is not silently
    // indistinguishable from a frame containing no plate.
    func detect(snapshot: ARFrameSnapshot) -> [PlateDetection] {
        guard case .success(let detections) = detectResult(snapshot: snapshot) else { return [] }
        return detections
    }

    private func appearanceCandidates(
        from detections: [PlateDetection],
        snapshot: ARFrameSnapshot
    ) -> [AppearanceCandidate] {
        let rawPixelSize = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        return detections.compactMap { detection -> AppearanceCandidate? in
            guard !Task.isCancelled else { return nil }
            let box = detection.boundingBox
            guard detection.isValid,
                  box.minX >= 0,
                  box.minY >= 0,
                  box.maxX <= 1,
                  box.maxY <= 1,
                  geometry.accepts(
                    normalizedBoundingBox: box,
                    rawPixelSize: rawPixelSize,
                    orientation: snapshot.visionOrientation
                  ) else { return nil }
            let rawQuadrilateral = mapper.visionQuadrilateralToRaw(
                detection.quadrilateral,
                orientation: snapshot.visionOrientation
            )
            guard let crop = perspectiveCorrector.correct(
                image: snapshot.image,
                quadrilateral: rawQuadrilateral,
                orientation: snapshot.visionOrientation,
                maximumOutputSize: CGSize(width: 144, height: 64)
            ),
            let appearance = appearanceScorer.score(crop),
            appearance.isPlausibleCommonDutchPlate else { return nil }
            return AppearanceCandidate(detection: detection, appearance: appearance)
        }
    }

    private func geometryPriority(_ detection: PlateDetection, snapshot: ARFrameSnapshot) -> CGFloat {
        let box = detection.boundingBox
        let aspect = geometry.pixelAspectRatio(
            of: box,
            rawPixelSize: CGSize(width: snapshot.image.width, height: snapshot.image.height),
            orientation: snapshot.visionOrientation
        ) ?? 1
        let legalAspects: [CGFloat] = [520 / 110, 310 / 110, 340 / 210]
        let aspectDistance = legalAspects.map { abs(log(aspect / $0)) }.min() ?? 10
        let oversizedPenalty = max(0, box.width * box.height - 0.08) * 10
        return aspectDistance + oversizedPenalty - CGFloat(detection.confidence) * 0.12
    }

    private func isHigherPriority(
        _ lhs: AppearanceCandidate,
        than rhs: AppearanceCandidate,
        snapshot: ARFrameSnapshot
    ) -> Bool {
        let lhsPriority = platePriority(lhs, snapshot: snapshot)
        let rhsPriority = platePriority(rhs, snapshot: snapshot)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }

        return isHigherGeometryPriority(lhs.detection, than: rhs.detection, snapshot: snapshot)
    }

    private func platePriority(_ candidate: AppearanceCandidate, snapshot: ARFrameSnapshot) -> CGFloat {
        geometryPriority(candidate.detection, snapshot: snapshot) - candidate.appearance.rankingBonus
    }

    private func isHigherGeometryPriority(
        _ lhs: PlateDetection,
        than rhs: PlateDetection,
        snapshot: ARFrameSnapshot
    ) -> Bool {
        let lhsPriority = geometryPriority(lhs, snapshot: snapshot)
        let rhsPriority = geometryPriority(rhs, snapshot: snapshot)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }

        // Vision does not promise a stable observation order. Use geometric
        // tie-breakers so symmetric rectangles cannot alternate targets merely
        // because the request returned them in a different order.
        let lhsBox = lhs.boundingBox
        let rhsBox = rhs.boundingBox
        if lhsBox.minX != rhsBox.minX { return lhsBox.minX < rhsBox.minX }
        if lhsBox.minY != rhsBox.minY { return lhsBox.minY < rhsBox.minY }
        if lhsBox.width != rhsBox.width { return lhsBox.width < rhsBox.width }
        if lhsBox.height != rhsBox.height { return lhsBox.height < rhsBox.height }
        return lhs.confidence > rhs.confidence
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        guard unionArea.isFinite, unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
}

private struct AppearanceCandidate {
    let detection: PlateDetection
    let appearance: PlateAppearanceScore
}

actor PlateRecognitionWorker {
    private let recognizer: any PlateRecognizing

    init(recognizer: any PlateRecognizing = VisionPlateRecognizer()) {
        self.recognizer = recognizer
    }

    func recognizeResult(
        snapshot: ARFrameSnapshot,
        rawQuadrilateral: PlateQuadrilateral
    ) -> Result<[OCRObservation], VisionWorkerFailure> {
        guard !Task.isCancelled,
              let crop = PerspectiveCorrector().correct(
                image: snapshot.image,
                quadrilateral: rawQuadrilateral,
                orientation: snapshot.visionOrientation
              ) else { return .failure(.cropPreparation) }
        guard !Task.isCancelled else { return .success([]) }
        let prepared = PlateRecognitionPreprocessor().prepare(crop)
        do {
            return .success(try recognizer.recognize(in: prepared, timestamp: snapshot.timestamp))
        } catch {
            return .failure(.recognition)
        }
    }

    // Test convenience; the controller uses recognizeResult to preserve the
    // distinction between no OCR result and an unavailable OCR operation.
    func recognize(snapshot: ARFrameSnapshot, rawQuadrilateral: PlateQuadrilateral) -> [OCRObservation] {
        guard case .success(let observations) = recognizeResult(
            snapshot: snapshot,
            rawQuadrilateral: rawQuadrilateral
        ) else { return [] }
        return observations
    }
}

/// Upscales only genuinely small plate crops and applies mild luminance
/// contrast. This does not invent detail, but it gives Vision a stable input
/// scale and makes faint black-on-reflective-yellow glyph edges less brittle.
struct PlateRecognitionPreprocessor: Sendable {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    var minimumPreparedWidth: CGFloat = 384
    var targetWidth: CGFloat = 512
    var maximumScale: CGFloat = 4

    func prepare(_ image: CGImage) -> CGImage {
        guard image.width > 0,
              image.height > 0,
              CGFloat(image.width) < minimumPreparedWidth else { return image }
        let scale = min(maximumScale, max(1, targetWidth / CGFloat(image.width)))
        guard scale > 1,
              let lanczos = CIFilter(name: "CILanczosScaleTransform") else { return image }
        let input = CIImage(cgImage: image)
        lanczos.setValue(input, forKey: kCIInputImageKey)
        lanczos.setValue(scale, forKey: kCIInputScaleKey)
        lanczos.setValue(1, forKey: kCIInputAspectRatioKey)
        guard var output = lanczos.outputImage else { return image }

        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(output, forKey: kCIInputImageKey)
            controls.setValue(0.25, forKey: kCIInputSaturationKey)
            controls.setValue(1.16, forKey: kCIInputContrastKey)
            if let adjusted = controls.outputImage {
                output = adjusted
            }
        }
        let extent = output.extent.integral
        guard extent.width > 0,
              extent.height > 0,
              let rendered = Self.context.createCGImage(output, from: extent) else { return image }
        return rendered
    }
}
