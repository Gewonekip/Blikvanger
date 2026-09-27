import Foundation

struct SpatialLabelCountFormatter: Sendable {
    func text(total: Int) -> String {
        let total = max(0, total)
        return switch total {
        case 0: AppStrings.text("No vehicles")
        case 1: AppStrings.text("1 vehicle")
        default: AppStrings.text("%@ vehicles", String(total))
        }
    }
}
