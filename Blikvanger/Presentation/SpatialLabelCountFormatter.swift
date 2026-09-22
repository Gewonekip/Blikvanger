import Foundation

struct SpatialLabelCountFormatter: Sendable {
    func text(total: Int) -> String {
        let total = max(0, total)
        return switch total {
        case 0: "No vehicles"
        case 1: "1 vehicle"
        default: "\(total) vehicles"
        }
    }
}
