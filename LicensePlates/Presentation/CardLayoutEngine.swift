import CoreGraphics
import Foundation

struct CardLayoutItem: Equatable, Sendable {
    let id: UUID
    let desiredPoint: CGPoint
    let size: CGSize
    let depth: Float
}

struct CardLayoutResult: Equatable, Sendable {
    let id: UUID
    let anchorPoint: CGPoint
    let cardPoint: CGPoint

    var needsLeaderLine: Bool {
        hypot(anchorPoint.x - cardPoint.x, anchorPoint.y - cardPoint.y) > 8
    }
}

struct CardLayoutEngine: Sendable {
    var spacing: CGFloat = 10

    func layout(
        items: [CardLayoutItem],
        safeFrame: CGRect,
        excludedFrames: [CGRect] = []
    ) -> [CardLayoutResult] {
        var occupied: [CGRect] = []
        var results: [CardLayoutResult] = []

        let orderedItems = items.sorted {
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            return $0.id.uuidString < $1.id.uuidString
        }
        for item in orderedItems {
            let halfWidth = item.size.width / 2
            let halfHeight = item.size.height / 2
            guard safeFrame.width >= item.size.width,
                  safeFrame.height >= item.size.height else { continue }
            let clamped = CGPoint(
                x: min(max(item.desiredPoint.x, safeFrame.minX + halfWidth), safeFrame.maxX - halfWidth),
                y: min(max(item.desiredPoint.y, safeFrame.minY + halfHeight), safeFrame.maxY - halfHeight)
            )
            let candidates = candidatePoints(
                preferred: clamped,
                itemSize: item.size,
                safeFrame: safeFrame
            )
            guard let placement = candidates.lazy.compactMap({ point -> (CGPoint, CGRect)? in
                let frame = CGRect(
                    x: point.x - halfWidth,
                    y: point.y - halfHeight,
                    width: item.size.width,
                    height: item.size.height
                )
                let conflictsWithCard = occupied.contains {
                    $0.insetBy(dx: -spacing, dy: -spacing).intersects(frame)
                }
                let conflictsWithExclusion = excludedFrames.contains { $0.intersects(frame) }
                return conflictsWithCard || conflictsWithExclusion ? nil : (point, frame)
            }).first else {
                // If the current Dynamic Type size cannot fit another readable
                // card, omit the farthest overflow card instead of overlapping it.
                continue
            }
            let point = placement.0
            let frame = placement.1
            occupied.append(frame)
            results.append(CardLayoutResult(id: item.id, anchorPoint: item.desiredPoint, cardPoint: point))
        }
        return results
    }

    private func candidatePoints(
        preferred: CGPoint,
        itemSize: CGSize,
        safeFrame: CGRect
    ) -> [CGPoint] {
        let minimumX = safeFrame.minX + itemSize.width / 2
        let maximumX = safeFrame.maxX - itemSize.width / 2
        let minimumY = safeFrame.minY + itemSize.height / 2
        let maximumY = safeFrame.maxY - itemSize.height / 2

        func axisPositions(minimum: CGFloat, maximum: CGFloat, step: CGFloat) -> [CGFloat] {
            guard maximum >= minimum else { return [] }
            var values: [CGFloat] = []
            var value = minimum
            while value <= maximum + 0.5 {
                values.append(min(value, maximum))
                value += max(step, 1)
            }
            if let last = values.last, maximum - last > 0.5 {
                values.append(maximum)
            }
            return values
        }

        let xs = axisPositions(
            minimum: minimumX,
            maximum: maximumX,
            step: itemSize.width + spacing
        )
        let ys = axisPositions(
            minimum: minimumY,
            maximum: maximumY,
            step: itemSize.height + spacing
        )
        var points = [preferred]
        points.append(contentsOf: ys.flatMap { y in xs.map { x in CGPoint(x: x, y: y) } })
        var seen = Set<String>()
        return points
            .filter { seen.insert("\(Int($0.x.rounded())):\(Int($0.y.rounded()))").inserted }
            .sorted {
                let lhsDistance = hypot($0.x - preferred.x, $0.y - preferred.y)
                let rhsDistance = hypot($1.x - preferred.x, $1.y - preferred.y)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                if $0.y != $1.y { return $0.y < $1.y }
                return $0.x < $1.x
            }
    }
}
