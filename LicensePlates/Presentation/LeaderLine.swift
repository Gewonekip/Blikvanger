import SwiftUI

struct LeaderLine: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        let control = CGPoint(x: start.x, y: (start.y + end.y) / 2)
        path.addQuadCurve(to: end, control: control)
        return path
    }
}
