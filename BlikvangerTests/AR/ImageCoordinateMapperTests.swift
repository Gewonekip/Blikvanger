import ImageIO
import XCTest
@testable import Blikvanger

final class ImageCoordinateMapperTests: XCTestCase {
    func testPortraitRightOrientationMapsVisionBackToRawImage() {
        let mapper = ImageCoordinateMapper()
        let right = mapper.visionPointToRaw(CGPoint(x: 0.2, y: 0.7), orientation: .right)
        XCTAssertEqual(right.x, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(right.y, 0.2, accuracy: 0.000_001)
        let left = mapper.visionPointToRaw(CGPoint(x: 0.2, y: 0.7), orientation: .left)
        XCTAssertEqual(left.x, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(left.y, 0.8, accuracy: 0.000_001)
    }

    func testAllOrientationMappingsRemainNormalized() {
        let mapper = ImageCoordinateMapper()
        let orientations: [CGImagePropertyOrientation] = [
            .up, .down, .left, .right, .upMirrored, .downMirrored, .leftMirrored, .rightMirrored
        ]
        for orientation in orientations {
            let result = mapper.visionPointToRaw(CGPoint(x: 0.13, y: 0.82), orientation: orientation)
            XCTAssertTrue((0...1).contains(result.x))
            XCTAssertTrue((0...1).contains(result.y))
        }
    }

    func testEveryOrientationRoundTripsBetweenVisionAndRawCoordinates() {
        let mapper = ImageCoordinateMapper()
        let point = CGPoint(x: 0.13, y: 0.82)
        let orientations: [CGImagePropertyOrientation] = [
            .up, .down, .left, .right, .upMirrored, .downMirrored, .leftMirrored, .rightMirrored
        ]
        for orientation in orientations {
            let raw = mapper.visionPointToRaw(point, orientation: orientation)
            let roundTrip = mapper.rawPointToVision(raw, orientation: orientation)
            XCTAssertEqual(roundTrip.x, point.x, accuracy: 0.000_001)
            XCTAssertEqual(roundTrip.y, point.y, accuracy: 0.000_001)
        }
    }

    func testRawVisionToScreenConvertsBottomLeftToTopLeft() {
        let result = ImageCoordinateMapper().rawVisionPointToScreen(
            CGPoint(x: 0.25, y: 0.75),
            displayTransform: .identity,
            viewportSize: CGSize(width: 400, height: 800)
        )
        XCTAssertEqual(result.x, 100, accuracy: 0.001)
        XCTAssertEqual(result.y, 200, accuracy: 0.001)
    }
}
