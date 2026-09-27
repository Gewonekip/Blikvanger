import SwiftUI

struct VehicleCardView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let track: VehicleTrack
    let distance: Float
    let layoutSize: CGSize

    init(track: VehicleTrack, distance: Float, layoutSize: CGSize = CGSize(width: 180, height: 64)) {
        self.track = track
        self.distance = distance
        self.layoutSize = layoutSize
    }

    var body: some View {
        HStack(spacing: dynamicTypeSize.isAccessibilitySize ? 12 : 10) {
            Circle()
                .fill(stateColor)
                .frame(
                    width: dynamicTypeSize.isAccessibilitySize ? 12 : 9,
                    height: dynamicTypeSize.isAccessibilitySize ? 12 : 9
                )
                .shadow(color: stateColor.opacity(0.8), radius: 5)
            VStack(alignment: .leading, spacing: dynamicTypeSize.isAccessibilitySize ? 4 : 2) {
                Text(track.vehicle?.plate ?? track.displayName)
                    .font(.system(.headline, design: .monospaced).weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.75)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 12 : 10)
        .frame(width: layoutSize.width, height: layoutSize.height, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 0.5)
        }
        .scaleEffect(prominenceScale)
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    var subtitle: String {
        Self.subtitle(for: track)
    }

    static func subtitle(for track: VehicleTrack) -> String {
        if let vehicle = track.vehicle {
            let summary = [
                vehicle.make,
                vehicle.model,
                vehicle.color,
                vehicle.registrationYear.map(String.init)
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            return summary.isEmpty ? AppStrings.text("Vehicle confirmed") : summary
        }
        return switch track.cardState {
        case .generic: AppStrings.text("Vehicle found")
        case .candidate: AppStrings.text("Plate detected")
        case .confirming:
            track.formattedPlate.map { AppStrings.text("%@ recognized · preparing RDW", $0) }
                ?? AppStrings.text("Recognized · preparing RDW")
        case .loading:
            track.formattedPlate.map { AppStrings.text("Looking up %@ in RDW…", $0) }
                ?? AppStrings.text("Looking up plate in RDW…")
        case .confirmed: AppStrings.text("Vehicle confirmed")
        case .uncertain:
            track.formattedPlate.map { AppStrings.text("No RDW record for %@", $0) }
                ?? AppStrings.text("No RDW vehicle record")
        case .unavailable:
            track.formattedPlate.map { AppStrings.text("RDW unavailable for %@", $0) }
                ?? AppStrings.text("RDW vehicle data unavailable")
        }
    }

    private var stateColor: Color {
        switch track.cardState {
        case .confirmed: .mint
        case .uncertain, .unavailable: .orange
        case .generic: .cyan
        default: .yellow
        }
    }

    private var prominenceScale: CGFloat {
        Self.prominenceScale(for: distance, dynamicTypeSize: dynamicTypeSize)
    }

    static func prominenceScale(
        for distance: Float,
        dynamicTypeSize: DynamicTypeSize? = nil
    ) -> CGFloat {
        if dynamicTypeSize?.isAccessibilitySize == true {
            return 1
        }
        return max(0.82, min(1.05, 1.12 - CGFloat(distance) * 0.035))
    }

    static func layoutSize(for dynamicTypeSize: DynamicTypeSize) -> CGSize {
        switch dynamicTypeSize {
        case .xSmall, .small, .medium, .large, .xLarge:
            CGSize(width: 180, height: 64)
        case .xxLarge:
            CGSize(width: 200, height: 74)
        case .xxxLarge:
            CGSize(width: 220, height: 86)
        case .accessibility1:
            CGSize(width: 240, height: 112)
        case .accessibility2:
            CGSize(width: 250, height: 126)
        case .accessibility3:
            CGSize(width: 260, height: 144)
        case .accessibility4:
            CGSize(width: 270, height: 160)
        case .accessibility5:
            CGSize(width: 280, height: 178)
        @unknown default:
            dynamicTypeSize.isAccessibilitySize
                ? CGSize(width: 280, height: 178)
                : CGSize(width: 180, height: 64)
        }
    }

    private var accessibilityText: String {
        AppStrings.text(
            "%@, %@, %@ metres away",
            track.vehicle?.plate ?? track.displayName,
            subtitle,
            distance.formatted(.number.precision(.fractionLength(1)))
        )
    }
}
