import Foundation
import simd

struct CameraCalibration: Sendable {
    let intrinsics: simd_float3x3
    let cameraToWorld: simd_float4x4
    let imageSize: SIMD2<Int>
}

struct DepthGrid: Sendable {
    let width: Int
    let height: Int
    let depths: [Float]
    let confidences: [UInt8]

    func value(x: Int, y: Int) -> (depth: Float, confidence: UInt8)? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let index = y * width + x
        guard depths.indices.contains(index), confidences.indices.contains(index) else { return nil }
        return (depths[index], confidences[index])
    }
}

struct DepthSample: Equatable, Sendable {
    let imagePoint: SIMD2<Float>
    let depth: Float
    let confidence: UInt8
    let worldPoint: SIMD3<Float>
}

struct DepthSampler: Sendable {
    var minimumConfidence: UInt8 = 1
    var validDistance: ClosedRange<Float> = 0.4...12

    func sample(
        quadrilateral: PlateQuadrilateral,
        grid: DepthGrid,
        calibration: CameraCalibration
    ) -> [DepthSample] {
        guard grid.width > 0, grid.height > 0,
              calibration.imageSize.x > 0, calibration.imageSize.y > 0 else { return [] }
        let interior = interiorPoints(of: quadrilateral)
        let surrounding = surroundingPoints(of: quadrilateral)
        let vehicleRegion = vehicleRegionPoints(of: quadrilateral)
        // Preserve the plate center whenever it has usable depth. Expand to the
        // bumper and wider car body only when the tighter stencil is empty; this
        // prevents nearby cars from being pulled toward one shared centroid.
        for points in [interior, interior + surrounding, interior + surrounding + vehicleRegion] {
            let result = filteredSamples(at: points, grid: grid, calibration: calibration)
            if result.count >= 3 { return result }
        }
        return []
    }

    private func filteredSamples(
        at points: [CGPoint],
        grid: DepthGrid,
        calibration: CameraCalibration
    ) -> [DepthSample] {
        var visitedCells = Set<Int>()
        var samples: [DepthSample] = []
        for normalized in points {
            // Vision coordinates are normalized with a bottom-left origin.
            let imagePoint = SIMD2(
                Float(normalized.x) * Float(calibration.imageSize.x),
                (1 - Float(normalized.y)) * Float(calibration.imageSize.y)
            )
            let depthX = Int(imagePoint.x / Float(calibration.imageSize.x) * Float(grid.width))
            let depthY = Int(imagePoint.y / Float(calibration.imageSize.y) * Float(grid.height))
            let x = min(max(depthX, 0), grid.width - 1)
            let y = min(max(depthY, 0), grid.height - 1)
            let cell = y * grid.width + x
            guard visitedCells.insert(cell).inserted,
                  let value = grid.value(x: x, y: y),
                  value.confidence >= minimumConfidence,
                  value.depth.isFinite,
                  validDistance.contains(value.depth) else { continue }
            guard let world = backProject(
                imagePoint: imagePoint,
                depth: value.depth,
                calibration: calibration
            ) else { continue }
            samples.append(DepthSample(imagePoint: imagePoint, depth: value.depth, confidence: value.confidence, worldPoint: world))
        }
        guard samples.count >= 3 else { return [] }
        let median = samples.map(\.depth).sorted()[samples.count / 2]
        let deviations = samples.map { abs($0.depth - median) }.sorted()
        let mad = max(deviations[deviations.count / 2], 0.015)
        samples.removeAll { abs($0.depth - median) > max(0.08, 3.5 * mad) }
        return samples.count >= 3 ? samples : []
    }

    func backProject(
        imagePoint: SIMD2<Float>,
        depth: Float,
        calibration: CameraCalibration
    ) -> SIMD3<Float>? {
        let fx = calibration.intrinsics[0, 0]
        let fy = calibration.intrinsics[1, 1]
        let cx = calibration.intrinsics[2, 0]
        let cy = calibration.intrinsics[2, 1]
        guard imagePoint.x.isFinite,
              imagePoint.y.isFinite,
              depth.isFinite,
              depth > 0,
              fx.isFinite,
              fy.isFinite,
              fx > 0,
              fy > 0,
              cx.isFinite,
              cy.isFinite else { return nil }
        // ARKit camera space: +x right, +y up, camera looks down -z.
        let camera = SIMD4(
            (imagePoint.x - cx) * depth / fx,
            -(imagePoint.y - cy) * depth / fy,
            -depth,
            1
        )
        let world = calibration.cameraToWorld * camera
        guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { return nil }
        return SIMD3(world.x, world.y, world.z)
    }

    private func interiorPoints(of quad: PlateQuadrilateral) -> [CGPoint] {
        let left = midpoint(quad.topLeft, quad.bottomLeft)
        let right = midpoint(quad.topRight, quad.bottomRight)
        let center = quad.projectiveCenter ?? midpoint(left, right)
        return [
            center,
            interpolate(left, right, 0.2),
            interpolate(left, right, 0.8),
            interpolate(midpoint(quad.topLeft, quad.topRight), midpoint(quad.bottomLeft, quad.bottomRight), 0.2),
            interpolate(midpoint(quad.topLeft, quad.topRight), midpoint(quad.bottomLeft, quad.bottomRight), 0.8),
            bilinear(quad, u: 0.25, v: 0.25),
            bilinear(quad, u: 0.75, v: 0.25),
            bilinear(quad, u: 0.75, v: 0.75),
            bilinear(quad, u: 0.25, v: 0.75)
        ]
    }

    private func surroundingPoints(of quad: PlateQuadrilateral) -> [CGPoint] {
        let xs = [quad.topLeft.x, quad.topRight.x, quad.bottomRight.x, quad.bottomLeft.x]
        let ys = [quad.topLeft.y, quad.topRight.y, quad.bottomRight.y, quad.bottomLeft.y]
        guard let minimumX = xs.min(), let maximumX = xs.max(),
              let minimumY = ys.min(), let maximumY = ys.max() else { return [] }
        let width = maximumX - minimumX
        let height = maximumY - minimumY
        guard width > 0, height > 0 else { return [] }
        let horizontalPadding = max(width * 0.22, 0.008)
        let verticalPadding = max(height * 0.55, 0.008)
        let centerX = (minimumX + maximumX) / 2
        let centerY = (minimumY + maximumY) / 2
        let quarterX = width * 0.25
        let quarterY = height * 0.25
        func clamped(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        }
        return [
            CGPoint(x: centerX, y: maximumY + verticalPadding),
            CGPoint(x: centerX - quarterX, y: maximumY + verticalPadding),
            CGPoint(x: centerX + quarterX, y: maximumY + verticalPadding),
            CGPoint(x: centerX, y: minimumY - verticalPadding),
            CGPoint(x: centerX - quarterX, y: minimumY - verticalPadding),
            CGPoint(x: centerX + quarterX, y: minimumY - verticalPadding),
            CGPoint(x: minimumX - horizontalPadding, y: centerY),
            CGPoint(x: minimumX - horizontalPadding, y: centerY - quarterY),
            CGPoint(x: minimumX - horizontalPadding, y: centerY + quarterY),
            CGPoint(x: maximumX + horizontalPadding, y: centerY),
            CGPoint(x: maximumX + horizontalPadding, y: centerY - quarterY),
            CGPoint(x: maximumX + horizontalPadding, y: centerY + quarterY)
        ].map(clamped)
    }

    private func vehicleRegionPoints(of quad: PlateQuadrilateral) -> [CGPoint] {
        let xs = [quad.topLeft.x, quad.topRight.x, quad.bottomRight.x, quad.bottomLeft.x]
        let ys = [quad.topLeft.y, quad.topRight.y, quad.bottomRight.y, quad.bottomLeft.y]
        guard let minimumX = xs.min(), let maximumX = xs.max(),
              let minimumY = ys.min(), let maximumY = ys.max() else { return [] }
        let width = maximumX - minimumX
        let height = maximumY - minimumY
        guard width > 0, height > 0 else { return [] }
        let center = CGPoint(x: (minimumX + maximumX) / 2, y: (minimumY + maximumY) / 2)
        let offsets: [CGFloat] = [-2, -1.25, -0.65, 0, 0.65, 1.25, 2]
        return offsets.flatMap { vertical in
            offsets.map { horizontal in
                CGPoint(
                    x: min(max(center.x + horizontal * width, 0), 1),
                    y: min(max(center.y + vertical * height, 0), 1)
                )
            }
        }
    }

    private func bilinear(_ quad: PlateQuadrilateral, u: CGFloat, v: CGFloat) -> CGPoint {
        let top = interpolate(quad.topLeft, quad.topRight, u)
        let bottom = interpolate(quad.bottomLeft, quad.bottomRight, u)
        return interpolate(top, bottom, v)
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { interpolate(a, b, 0.5) }
    private func interpolate(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
