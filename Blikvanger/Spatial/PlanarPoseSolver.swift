import Foundation
import simd

struct PlanarPoseSolution: Sendable {
    let worldTransform: simd_float4x4
    let distance: Float
    let reprojectionError: Float
    let scaleMismatch: Float
    let orthogonalityError: Float
    let physicalSize: PlatePhysicalSize
}

/// Four-corner calibrated planar pose using homography decomposition.
/// The solve uses computer-vision camera coordinates (+x right, +y down, +z forward)
/// and converts the result to ARKit camera coordinates (+x right, +y up, -z forward).
struct PlanarPoseSolver: Sendable {
    func solve(
        quadrilateral: PlateQuadrilateral,
        calibration: CameraCalibration,
        physicalSize: PlatePhysicalSize
    ) -> PlanarPoseSolution? {
        let size = physicalSize.meters
        let objectPoints: [SIMD2<Double>] = [
            SIMD2(-Double(size.x) / 2, -Double(size.y) / 2),
            SIMD2(Double(size.x) / 2, -Double(size.y) / 2),
            SIMD2(Double(size.x) / 2, Double(size.y) / 2),
            SIMD2(-Double(size.x) / 2, Double(size.y) / 2)
        ]
        let imagePoints = [
            pixelPoint(quadrilateral.topLeft, imageSize: calibration.imageSize),
            pixelPoint(quadrilateral.topRight, imageSize: calibration.imageSize),
            pixelPoint(quadrilateral.bottomRight, imageSize: calibration.imageSize),
            pixelPoint(quadrilateral.bottomLeft, imageSize: calibration.imageSize)
        ]
        guard polygonArea(imagePoints) > 64,
              let homography = solveHomography(object: objectPoints, image: imagePoints) else { return nil }

        let fx = Double(calibration.intrinsics[0, 0])
        let fy = Double(calibration.intrinsics[1, 1])
        let cx = Double(calibration.intrinsics[2, 0])
        let cy = Double(calibration.intrinsics[2, 1])
        guard fx > 0, fy > 0 else { return nil }

        var b1 = SIMD3(
            (homography[0] - cx * homography[6]) / fx,
            (homography[3] - cy * homography[6]) / fy,
            homography[6]
        )
        var b2 = SIMD3(
            (homography[1] - cx * homography[7]) / fx,
            (homography[4] - cy * homography[7]) / fy,
            homography[7]
        )
        var b3 = SIMD3(
            (homography[2] - cx) / fx,
            (homography[5] - cy) / fy,
            1
        )
        let norm1 = simd_length(b1)
        let norm2 = simd_length(b2)
        guard norm1 > 1e-9, norm2 > 1e-9 else { return nil }
        let orthogonalityError = abs(simd_dot(b1 / norm1, b2 / norm2))
        guard orthogonalityError < 0.35 else { return nil }
        var scale = 2 / (norm1 + norm2)
        if b3.z * scale < 0 {
            b1 = -b1
            b2 = -b2
            b3 = -b3
            scale = -scale
        }

        let r1 = simd_normalize(b1)
        let orthogonalB2 = b2 - simd_dot(b2, r1) * r1
        guard simd_length(orthogonalB2) > 1e-9 else { return nil }
        let r2 = simd_normalize(orthogonalB2)
        let translationCV = b3 * abs(scale)
        guard translationCV.z > 0.2, translationCV.z < 20 else { return nil }
        let rigidError = rigidReprojectionError(
            r1: r1,
            r2: r2,
            translation: translationCV,
            object: objectPoints,
            image: imagePoints,
            fx: fx,
            fy: fy,
            cx: cx,
            cy: cy
        )
        guard rigidError.isFinite else { return nil }

        func cvToAR(_ value: SIMD3<Double>, direction: Bool = true) -> SIMD4<Float> {
            SIMD4(Float(value.x), Float(-value.y), Float(-value.z), direction ? 0 : 1)
        }
        let cameraToWorld = calibration.cameraToWorld
        let worldRight4 = cameraToWorld * cvToAR(r1)
        // Object Y is down; local/world label Y is up.
        let worldUp4 = cameraToWorld * cvToAR(-r2)
        let worldPosition4 = cameraToWorld * cvToAR(translationCV, direction: false)
        let worldRight = simd_normalize(SIMD3(worldRight4.x, worldRight4.y, worldRight4.z))
        let worldUp = simd_normalize(SIMD3(worldUp4.x, worldUp4.y, worldUp4.z))
        let worldNormal = simd_normalize(simd_cross(worldRight, worldUp))
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4(worldRight, 0)
        transform.columns.1 = SIMD4(worldUp, 0)
        transform.columns.2 = SIMD4(worldNormal, 0)
        transform.columns.3 = SIMD4(worldPosition4.x, worldPosition4.y, worldPosition4.z, 1)

        return PlanarPoseSolution(
            worldTransform: transform,
            distance: Float(translationCV.z),
            reprojectionError: rigidError,
            scaleMismatch: Float(abs(norm1 - norm2) / max(norm1, norm2)),
            orthogonalityError: Float(orthogonalityError),
            physicalSize: physicalSize
        )
    }

    private func pixelPoint(_ point: CGPoint, imageSize: SIMD2<Int>) -> SIMD2<Double> {
        SIMD2(Double(point.x) * Double(imageSize.x), (1 - Double(point.y)) * Double(imageSize.y))
    }

    private func polygonArea(_ points: [SIMD2<Double>]) -> Double {
        abs(points.indices.reduce(0) { partial, index in
            let next = points[(index + 1) % points.count]
            return partial + points[index].x * next.y - next.x * points[index].y
        }) / 2
    }

    private func solveHomography(object: [SIMD2<Double>], image: [SIMD2<Double>]) -> [Double]? {
        var matrix = Array(repeating: Array(repeating: Double.zero, count: 9), count: 8)
        for index in 0..<4 {
            let x = object[index].x
            let y = object[index].y
            let u = image[index].x
            let v = image[index].y
            matrix[index * 2] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            matrix[index * 2 + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        guard let solved = gaussianSolve(matrix) else { return nil }
        return solved + [1]
    }

    /// Solves an 8×8 augmented system with scaled partial pivoting.
    private func gaussianSolve(_ input: [[Double]]) -> [Double]? {
        var matrix = input
        let count = matrix.count
        for column in 0..<count {
            guard let pivot = (column..<count).max(by: {
                abs(matrix[$0][column]) < abs(matrix[$1][column])
            }), abs(matrix[pivot][column]) > 1e-10 else { return nil }
            if pivot != column { matrix.swapAt(pivot, column) }
            let divisor = matrix[column][column]
            for value in column...count { matrix[column][value] /= divisor }
            for row in 0..<count where row != column {
                let factor = matrix[row][column]
                guard factor != 0 else { continue }
                for value in column...count {
                    matrix[row][value] -= factor * matrix[column][value]
                }
            }
        }
        return matrix.map { $0[count] }
    }

    private func rigidReprojectionError(
        r1: SIMD3<Double>,
        r2: SIMD3<Double>,
        translation: SIMD3<Double>,
        object: [SIMD2<Double>],
        image: [SIMD2<Double>],
        fx: Double,
        fy: Double,
        cx: Double,
        cy: Double
    ) -> Float {
        var total = Double.zero
        for (objectPoint, imagePoint) in zip(object, image) {
            let camera = r1 * objectPoint.x + r2 * objectPoint.y + translation
            guard camera.z > 0.05 else { return .infinity }
            let u = fx * camera.x / camera.z + cx
            let v = fy * camera.y / camera.z + cy
            total += hypot(u - imagePoint.x, v - imagePoint.y)
        }
        return Float(total / Double(object.count))
    }
}
