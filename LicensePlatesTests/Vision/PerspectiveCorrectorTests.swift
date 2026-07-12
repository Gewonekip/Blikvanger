import CoreGraphics
import CoreImage
import ImageIO
import XCTest
@testable import LicensePlates

final class PerspectiveCorrectorTests: XCTestCase {
    func testPortraitRightCorrectionProducesUprightWidePlateCrop() throws {
        let image = try XCTUnwrap(makeAsymmetricImage())
        let orientedQuad = PlateQuadrilateral(
            topLeft: CGPoint(x: 0.1, y: 0.55),
            topRight: CGPoint(x: 0.9, y: 0.55),
            bottomRight: CGPoint(x: 0.9, y: 0.45),
            bottomLeft: CGPoint(x: 0.1, y: 0.45)
        )
        let rawQuad = ImageCoordinateMapper().visionQuadrilateralToRaw(orientedQuad, orientation: .right)

        let upright = try XCTUnwrap(PerspectiveCorrector().correct(
            image: image,
            quadrilateral: rawQuad,
            orientation: .right
        ))
        XCTAssertEqual(upright.width, 80)
        XCTAssertEqual(upright.height, 20)
        XCTAssertGreaterThan(Double(upright.width) / Double(upright.height), 3.5)

        let left = try averageColor(
            in: upright,
            rect: CGRect(x: 4, y: 3, width: 30, height: 14)
        )
        let right = try averageColor(
            in: upright,
            rect: CGRect(x: 46, y: 3, width: 30, height: 14)
        )
        XCTAssertGreaterThan(
            left.red,
            left.blue + 80,
            "The red end of the raw vertical plate must become the left end of the upright crop"
        )
        XCTAssertGreaterThan(
            right.blue,
            right.red + 80,
            "The blue end of the raw vertical plate must become the right end of the upright crop"
        )
    }

    private func makeAsymmetricImage() -> CGImage? {
        let width = 200
        let height = 100
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldAntialias(false)
        // Under EXIF `.right`, this raw vertical band becomes the horizontal
        // plate rectangle used by the test. Its two colored ends prove that the
        // correct pixels were cropped in the correct orientation.
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 90, y: 10, width: 20, height: 40))
        context.setFillColor(CGColor(red: 0, green: 0.2, blue: 1, alpha: 1))
        context.fill(CGRect(x: 90, y: 50, width: 20, height: 40))
        return context.makeImage()
    }

    private func averageColor(in image: CGImage, rect: CGRect) throws -> PixelColor {
        let input = CIImage(cgImage: image)
        let sampleRect = rect.intersection(input.extent)
        XCTAssertFalse(sampleRect.isNull)
        let filter = try XCTUnwrap(CIFilter(name: "CIAreaAverage"))
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: sampleRect), forKey: kCIInputExtentKey)
        let output = try XCTUnwrap(filter.outputImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            CIContext(options: [.cacheIntermediates: false]).render(
                output,
                toBitmap: buffer.baseAddress!,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }
        return PixelColor(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]))
    }
}

private struct PixelColor {
    let red: Int
    let green: Int
    let blue: Int
}
