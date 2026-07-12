import CoreGraphics
import ImageIO
import simd
import XCTest
@testable import LicensePlates

final class PlateAppearanceScorerTests: XCTestCase {
    func testYellowFieldWithDistributedDarkCharactersIsPlausible() throws {
        let image = try XCTUnwrap(makePlateImage(
            background: CGColor(red: 1, green: 0.78, blue: 0.04, alpha: 1),
            includesCharacters: true
        ))

        let score = try XCTUnwrap(PlateAppearanceScorer().score(image))

        XCTAssertTrue(score.isPlausibleCommonDutchPlate)
        XCTAssertGreaterThan(score.yellowFraction, 0.45)
        XCTAssertGreaterThanOrEqual(score.darkBandCoverage, 0.5)
    }

    func testGrayFrameWithTheSameDarkPatternIsRejected() throws {
        let image = try XCTUnwrap(makePlateImage(
            background: CGColor(red: 0.48, green: 0.50, blue: 0.52, alpha: 1),
            includesCharacters: true
        ))

        let score = try XCTUnwrap(PlateAppearanceScorer().score(image))

        XCTAssertFalse(score.isPlausibleCommonDutchPlate)
        XCTAssertLessThan(score.yellowFraction, 0.02)
    }

    func testShadowedAndReflectivePaleYellowPlatesRemainPlausible() throws {
        let shadowed = try XCTUnwrap(makePlateImage(
            background: CGColor(red: 0.52, green: 0.39, blue: 0.03, alpha: 1),
            includesCharacters: true
        ))
        let reflective = try XCTUnwrap(makePlateImage(
            background: CGColor(red: 1, green: 0.92, blue: 0.50, alpha: 1),
            includesCharacters: true
        ))

        XCTAssertTrue(try XCTUnwrap(PlateAppearanceScorer().score(shadowed)).isPlausibleCommonDutchPlate)
        XCTAssertTrue(try XCTUnwrap(PlateAppearanceScorer().score(reflective)).isPlausibleCommonDutchPlate)
    }

    func testBeigeAndLimeSignsAreRejectedDespiteDarkMarkings() throws {
        let beige = try XCTUnwrap(makePlateImage(
            background: CGColor(red: 0.70, green: 0.60, blue: 0.42, alpha: 1),
            includesCharacters: true
        ))
        let lime = try XCTUnwrap(makePlateImage(
            background: CGColor(red: 0.52, green: 1, blue: 0.05, alpha: 1),
            includesCharacters: true
        ))

        XCTAssertFalse(try XCTUnwrap(PlateAppearanceScorer().score(beige)).isPlausibleCommonDutchPlate)
        XCTAssertFalse(try XCTUnwrap(PlateAppearanceScorer().score(lime)).isPlausibleCommonDutchPlate)
    }

    func testSolidYellowRectangleWithoutCharacterStructureIsRejected() throws {
        let image = try XCTUnwrap(makePlateImage(
            background: CGColor(red: 1, green: 0.78, blue: 0.04, alpha: 1),
            includesCharacters: false
        ))

        let score = try XCTUnwrap(PlateAppearanceScorer().score(image))

        XCTAssertFalse(score.isPlausibleCommonDutchPlate)
        XCTAssertEqual(score.darkFraction, 0, accuracy: 0.001)
    }

    func testYellowFieldWithOneDarkStripeIsNotMistakenForCharacters() throws {
        let image = try XCTUnwrap(makeYellowStripeImage())

        let score = try XCTUnwrap(PlateAppearanceScorer().score(image))

        XCTAssertFalse(score.isPlausibleCommonDutchPlate)
        XCTAssertLessThan(score.darkRowCoverage, 0.75)
    }

    func testPortraitWorkerAcceptsYellowPlatePixelsAndRejectsIndoorGrayRectangle() async throws {
        let orientedPlate = PlateDetection(
            quadrilateral: PlateQuadrilateral(
                topLeft: CGPoint(x: 0.1, y: 0.55),
                topRight: CGPoint(x: 0.9, y: 0.55),
                bottomRight: CGPoint(x: 0.9, y: 0.45),
                bottomLeft: CGPoint(x: 0.1, y: 0.45)
            ),
            confidence: 0.95,
            timestamp: 1
        )
        let detector = AppearanceDetector(detection: orientedPlate)
        let yellowWorker = PlateDetectionWorker(detector: detector)
        let grayWorker = PlateDetectionWorker(detector: detector)

        let yellow = await yellowWorker.detect(snapshot: try portraitSnapshot(
            plateColor: CGColor(red: 1, green: 0.78, blue: 0.04, alpha: 1)
        ))
        let gray = await grayWorker.detect(snapshot: try portraitSnapshot(
            plateColor: CGColor(red: 0.48, green: 0.50, blue: 0.52, alpha: 1)
        ))

        XCTAssertEqual(yellow.count, 1)
        XCTAssertTrue(gray.isEmpty, "An indoor frame or window must not seed a spatial candidate")
    }

    func testWorkerChoosesOffCenterYellowPlateOverNeutralBumperInEitherOrder() async throws {
        let plate = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.58, y: 0.62, width: 0.25, height: 0.05)),
            confidence: 0.58,
            timestamp: 1
        )
        let bumper = PlateDetection(
            quadrilateral: quadrilateral(for: CGRect(x: 0.28, y: 0.38, width: 0.44, height: 0.12)),
            confidence: 0.99,
            timestamp: 1
        )
        let snapshot = try carSnapshot(plateBox: plate.boundingBox, bumperBox: bumper.boundingBox)
        let forward = PlateDetectionWorker(detector: AppearanceDetections(detections: [bumper, plate]))
        let reversed = PlateDetectionWorker(detector: AppearanceDetections(detections: [plate, bumper]))

        let first = await forward.detect(snapshot: snapshot)
        let second = await reversed.detect(snapshot: snapshot)

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(first[0].quadrilateral, plate.quadrilateral)
        XCTAssertEqual(second[0].quadrilateral, plate.quadrilateral)
    }

    func testSmallRecognitionCropIsUpscaledWithinTheBoundedScale() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 96,
            height: 24,
            bitsPerComponent: 8,
            bytesPerRow: 96 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())

        let prepared = PlateRecognitionPreprocessor().prepare(image)

        XCTAssertEqual(prepared.width, 384)
        XCTAssertEqual(prepared.height, 96)
    }

    private func makePlateImage(background: CGColor, includesCharacters: Bool) -> CGImage? {
        let width = 180
        let height = 54
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard includesCharacters else { return context.makeImage() }

        context.setFillColor(CGColor(gray: 0.03, alpha: 1))
        for x in stride(from: 18, through: 150, by: 27) {
            context.fill(CGRect(x: x, y: 12, width: 10, height: 30))
        }
        return context.makeImage()
    }

    private func makeYellowStripeImage() -> CGImage? {
        let width = 180
        let height = 54
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0.78, blue: 0.04, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.03, alpha: 1))
        context.fill(CGRect(x: 8, y: 25, width: 164, height: 4))
        return context.makeImage()
    }

    private func quadrilateral(for rectangle: CGRect) -> PlateQuadrilateral {
        PlateQuadrilateral(
            topLeft: CGPoint(x: rectangle.minX, y: rectangle.maxY),
            topRight: CGPoint(x: rectangle.maxX, y: rectangle.maxY),
            bottomRight: CGPoint(x: rectangle.maxX, y: rectangle.minY),
            bottomLeft: CGPoint(x: rectangle.minX, y: rectangle.minY)
        )
    }

    private func carSnapshot(plateBox: CGRect, bumperBox: CGRect) throws -> ARFrameSnapshot {
        let width = 400
        let height = 300
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.12, green: 0.14, blue: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let bumperPixels = pixelRect(bumperBox, width: width, height: height)
        context.setFillColor(CGColor(red: 0.46, green: 0.48, blue: 0.50, alpha: 1))
        context.fill(bumperPixels)
        context.setFillColor(CGColor(gray: 0.04, alpha: 1))
        for index in 0..<6 {
            let x = bumperPixels.minX + 14 + CGFloat(index) * 27
            context.fill(CGRect(x: x, y: bumperPixels.midY - 5, width: 8, height: 10))
        }

        let platePixels = pixelRect(plateBox, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 0.78, blue: 0.04, alpha: 1))
        context.fill(platePixels)
        context.setFillColor(CGColor(gray: 0.02, alpha: 1))
        for index in 0..<6 {
            let characterWidth = max(3, platePixels.width * 0.055)
            let x = platePixels.minX + platePixels.width * (0.12 + CGFloat(index) * 0.14)
            context.fill(CGRect(
                x: x,
                y: platePixels.minY + platePixels.height * 0.18,
                width: characterWidth,
                height: platePixels.height * 0.64
            ))
        }
        let image = try XCTUnwrap(context.makeImage())
        return ARFrameSnapshot(
            image: image,
            depthGrid: DepthGrid(
                width: 2,
                height: 2,
                depths: Array(repeating: 2, count: 4),
                confidences: Array(repeating: 2, count: 4)
            ),
            calibration: CameraCalibration(
                intrinsics: matrix_identity_float3x3,
                cameraToWorld: matrix_identity_float4x4,
                imageSize: SIMD2(width, height)
            ),
            timestamp: 1,
            visionOrientation: .up,
            generation: 1,
            droppedFrames: 0
        )
    }

    private func pixelRect(_ normalized: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(
            x: normalized.minX * CGFloat(width),
            y: normalized.minY * CGFloat(height),
            width: normalized.width * CGFloat(width),
            height: normalized.height * CGFloat(height)
        )
    }

    private func portraitSnapshot(plateColor: CGColor) throws -> ARFrameSnapshot {
        let width = 200
        let height = 100
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.18, green: 0.20, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(plateColor)
        context.fill(CGRect(x: 90, y: 10, width: 20, height: 80))
        context.setFillColor(CGColor(gray: 0.03, alpha: 1))
        for y in stride(from: 18, through: 78, by: 12) {
            context.fill(CGRect(x: 94, y: y, width: 12, height: 5))
        }
        let image = try XCTUnwrap(context.makeImage())
        return ARFrameSnapshot(
            image: image,
            depthGrid: DepthGrid(
                width: 2,
                height: 2,
                depths: Array(repeating: 2, count: 4),
                confidences: Array(repeating: 2, count: 4)
            ),
            calibration: CameraCalibration(
                intrinsics: matrix_identity_float3x3,
                cameraToWorld: matrix_identity_float4x4,
                imageSize: SIMD2(width, height)
            ),
            timestamp: 1,
            visionOrientation: .right,
            generation: 1,
            droppedFrames: 0
        )
    }
}

private struct AppearanceDetector: PlateDetecting {
    let detection: PlateDetection

    func detect(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval
    ) throws -> [PlateDetection] {
        [detection]
    }
}

private struct AppearanceDetections: PlateDetecting {
    let detections: [PlateDetection]

    func detect(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval
    ) throws -> [PlateDetection] {
        detections
    }
}
