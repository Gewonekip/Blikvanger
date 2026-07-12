import CoreGraphics
import CoreImage
import Foundation
import ImageIO

struct PerspectiveCorrector: Sendable {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    func correct(
        image: CGImage,
        quadrilateral rawQuadrilateral: PlateQuadrilateral,
        orientation: CGImagePropertyOrientation = .up,
        maximumOutputSize: CGSize? = nil
    ) -> CGImage? {
        let oriented = CIImage(cgImage: image).oriented(orientation)
        let input = oriented.transformed(
            by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY)
        )
        let quadrilateral = ImageCoordinateMapper().rawQuadrilateralToVision(
            rawQuadrilateral,
            orientation: orientation
        )
        let width = input.extent.width
        let height = input.extent.height
        func point(_ normalized: CGPoint) -> CIVector {
            CIVector(x: normalized.x * width, y: normalized.y * height)
        }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(point(quadrilateral.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(quadrilateral.topRight), forKey: "inputTopRight")
        filter.setValue(point(quadrilateral.bottomRight), forKey: "inputBottomRight")
        filter.setValue(point(quadrilateral.bottomLeft), forKey: "inputBottomLeft")
        guard let output = filter.outputImage else { return nil }
        let rendered: CIImage
        if let maximumOutputSize,
           maximumOutputSize.width > 0,
           maximumOutputSize.height > 0 {
            let scale = min(
                1,
                maximumOutputSize.width / max(output.extent.width, 1),
                maximumOutputSize.height / max(output.extent.height, 1)
            )
            rendered = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            rendered = output
        }
        return Self.context.createCGImage(rendered, from: rendered.extent)
    }
}
