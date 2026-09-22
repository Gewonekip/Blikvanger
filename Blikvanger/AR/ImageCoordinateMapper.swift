import CoreGraphics
import Foundation
import ImageIO

struct ImageCoordinateMapper: Sendable {
    /// Converts a Vision normalized point (bottom-left origin) from an EXIF-oriented
    /// image back to the raw ARFrame captured-image coordinates (also bottom-left).
    func visionPointToRaw(_ point: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        switch orientation {
        case .up:
            point
        case .down:
            CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .right:
            CGPoint(x: 1 - point.y, y: point.x)
        case .left:
            CGPoint(x: point.y, y: 1 - point.x)
        case .upMirrored:
            CGPoint(x: 1 - point.x, y: point.y)
        case .downMirrored:
            CGPoint(x: point.x, y: 1 - point.y)
        case .rightMirrored:
            CGPoint(x: point.y, y: point.x)
        case .leftMirrored:
            CGPoint(x: 1 - point.y, y: 1 - point.x)
        @unknown default:
            point
        }
    }

    func visionQuadrilateralToRaw(
        _ quadrilateral: PlateQuadrilateral,
        orientation: CGImagePropertyOrientation
    ) -> PlateQuadrilateral {
        PlateQuadrilateral(
            topLeft: visionPointToRaw(quadrilateral.topLeft, orientation: orientation),
            topRight: visionPointToRaw(quadrilateral.topRight, orientation: orientation),
            bottomRight: visionPointToRaw(quadrilateral.bottomRight, orientation: orientation),
            bottomLeft: visionPointToRaw(quadrilateral.bottomLeft, orientation: orientation)
        )
    }

    /// Inverse of `visionPointToRaw`; useful when a raw-frame quadrilateral must
    /// be applied to an EXIF-oriented image for OCR.
    func rawPointToVision(_ point: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        switch orientation {
        case .up:
            point
        case .down:
            CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .right:
            CGPoint(x: point.y, y: 1 - point.x)
        case .left:
            CGPoint(x: 1 - point.y, y: point.x)
        case .upMirrored:
            CGPoint(x: 1 - point.x, y: point.y)
        case .downMirrored:
            CGPoint(x: point.x, y: 1 - point.y)
        case .rightMirrored:
            CGPoint(x: point.y, y: point.x)
        case .leftMirrored:
            CGPoint(x: 1 - point.y, y: 1 - point.x)
        @unknown default:
            point
        }
    }

    func rawQuadrilateralToVision(
        _ quadrilateral: PlateQuadrilateral,
        orientation: CGImagePropertyOrientation
    ) -> PlateQuadrilateral {
        PlateQuadrilateral(
            topLeft: rawPointToVision(quadrilateral.topLeft, orientation: orientation),
            topRight: rawPointToVision(quadrilateral.topRight, orientation: orientation),
            bottomRight: rawPointToVision(quadrilateral.bottomRight, orientation: orientation),
            bottomLeft: rawPointToVision(quadrilateral.bottomLeft, orientation: orientation)
        )
    }

    /// Converts a raw captured-image Vision point (bottom-left origin) into view points.
    func rawVisionPointToScreen(
        _ point: CGPoint,
        displayTransform: CGAffineTransform,
        viewportSize: CGSize
    ) -> CGPoint {
        let rawTopLeft = CGPoint(x: point.x, y: 1 - point.y)
        let viewNormalized = rawTopLeft.applying(displayTransform)
        return CGPoint(
            x: viewNormalized.x * viewportSize.width,
            y: viewNormalized.y * viewportSize.height
        )
    }
}
