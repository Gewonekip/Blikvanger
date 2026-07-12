import CoreGraphics
import Foundation

struct PlateDetection: Equatable, Sendable {
    let quadrilateral: PlateQuadrilateral
    let confidence: Float
    let timestamp: TimeInterval

    var boundingBox: CGRect {
        let points = [quadrilateral.topLeft, quadrilateral.topRight, quadrilateral.bottomRight, quadrilateral.bottomLeft]
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minimumX = xs.min() ?? 0
        let maximumX = xs.max() ?? 0
        let minimumY = ys.min() ?? 0
        let maximumY = ys.max() ?? 0
        return CGRect(x: minimumX, y: minimumY, width: maximumX - minimumX, height: maximumY - minimumY)
    }

    var isValid: Bool {
        let points = [quadrilateral.topLeft, quadrilateral.topRight, quadrilateral.bottomRight, quadrilateral.bottomLeft]
        let box = boundingBox
        return confidence.isFinite
            && timestamp.isFinite
            && points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
            && box.width.isFinite
            && box.height.isFinite
            && box.width > 0
            && box.height > 0
    }
}

struct PlateCandidate: Identifiable, Sendable {
    let id: UUID
    var state: TrackLifecycle
    var quadrilateralHistory: [PlateQuadrilateral]
    var poseSamples: [PoseSample]
    var firstSeen: TimeInterval
    var lastSeen: TimeInterval
    var observationCount: Int
    var consecutiveObservationCount: Int
    var missedObservationCount: Int

    var latestQuadrilateral: PlateQuadrilateral? {
        quadrilateralHistory.last
    }
}

extension PlateQuadrilateral {
    /// The image of a planar rectangle's physical center is the intersection of
    /// its diagonals. Averaging the four corners is only equivalent for a
    /// parallelogram and drifts toward the larger edge under perspective.
    var projectiveCenter: CGPoint? {
        let firstOrigin = topLeft
        let firstDirection = CGPoint(
            x: bottomRight.x - topLeft.x,
            y: bottomRight.y - topLeft.y
        )
        let secondOrigin = topRight
        let secondDirection = CGPoint(
            x: bottomLeft.x - topRight.x,
            y: bottomLeft.y - topRight.y
        )
        let denominator = cross(firstDirection, secondDirection)
        guard denominator.isFinite, abs(denominator) > 0.000_001 else { return nil }

        let originDelta = CGPoint(
            x: secondOrigin.x - firstOrigin.x,
            y: secondOrigin.y - firstOrigin.y
        )
        let firstAmount = cross(originDelta, secondDirection) / denominator
        let secondAmount = cross(originDelta, firstDirection) / denominator
        guard firstAmount.isFinite,
              secondAmount.isFinite,
              (-0.1...1.1).contains(firstAmount),
              (-0.1...1.1).contains(secondAmount) else { return nil }

        let center = CGPoint(
            x: firstOrigin.x + firstDirection.x * firstAmount,
            y: firstOrigin.y + firstDirection.y * firstAmount
        )
        return center.x.isFinite && center.y.isFinite ? center : nil
    }

    private func cross(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        lhs.x * rhs.y - lhs.y * rhs.x
    }
}
