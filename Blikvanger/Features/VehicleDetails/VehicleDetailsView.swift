import SwiftUI

struct VehicleDetailsStatusFormatter: Sendable {
    func text(
        for state: VehicleCardState,
        plate: String? = nil
    ) -> String {
        return switch state {
        case .loading:
            plate.map { AppStrings.text("Checking plate %@ in the public RDW dataset…", $0) }
                ?? AppStrings.text("Loading public RDW vehicle data…")
        case .unavailable:
            AppStrings.text("RDW vehicle data is temporarily unavailable. The vehicle remains saved for this scan.")
        case .uncertain:
            AppStrings.text("No reliable RDW vehicle record is available for this plate.")
        case .generic:
            AppStrings.text("Recognize a Dutch plate to load public vehicle data.")
        case .candidate:
            AppStrings.text("The vehicle position is saved. Plate detection and reading pause while these details are open; close them to continue across several frames.")
        case .confirming:
            plate.map { AppStrings.text("Plate %@ was recognized. Preparing the RDW lookup…", $0) }
                ?? AppStrings.text("The plate was recognized. Preparing the RDW lookup…")
        case .confirmed:
            AppStrings.text("The plate is confirmed; public vehicle details are not available for this record.")
        }
    }
}

private enum VehicleDetailsFormatStyles {
    static func date(locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(date: .long, time: .omitted)
            .locale(locale)
    }

    static func currency(locale: Locale) -> IntegerFormatStyle<Int>.Currency {
        .currency(code: "EUR")
            .precision(.fractionLength(0))
            .locale(locale)
    }

    static func number(locale: Locale) -> IntegerFormatStyle<Int> {
        .number
            .grouping(.automatic)
            .locale(locale)
    }
}

struct VehicleDetailsView: View {
    let track: VehicleTrack
    let onRemove: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    init(track: VehicleTrack, onRemove: (() -> Void)? = nil) {
        self.track = track
        self.onRemove = onRemove
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(track.vehicle?.plate ?? track.displayName)
                            .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let name = vehicleName {
                            Text(name)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Vehicle") {
                    if track.vehicle == nil {
                        Text(vehicleStatusText)
                            .foregroundStyle(.secondary)
                    } else {
                        detail(AppStrings.text("Make"), track.vehicle?.make)
                        detail(AppStrings.text("Model"), track.vehicle?.model)
                        detail(AppStrings.text("Type"), track.vehicle?.vehicleType)
                        detail(AppStrings.text("Primary color"), track.vehicle?.primaryColor)
                        detail(AppStrings.text("Secondary color"), track.vehicle?.secondaryColor)
                        detail(AppStrings.text("First registration"), formattedDate(track.vehicle?.firstRegistrationDate))
                    }
                }

                if hasTechnicalDetails {
                    Section("Technical data") {
                        detail(AppStrings.text("Catalog price"), formattedCurrency(track.vehicle?.catalogPrice))
                        detail(AppStrings.text("Cylinders"), formattedNumber(track.vehicle?.cylinderCount))
                        detail(AppStrings.text("Engine displacement"), formattedNumber(track.vehicle?.displacementCC, unit: "cm³"))
                        detail(AppStrings.text("Empty mass"), formattedNumber(track.vehicle?.emptyMassKG, unit: "kg"))
                        detail(AppStrings.text("Running mass"), formattedNumber(track.vehicle?.runningMassKG, unit: "kg"))
                        detail(AppStrings.text("Maximum mass"), formattedNumber(track.vehicle?.maximumMassKG, unit: "kg"))
                    }
                }

                Section {
                    Text("Vehicle information comes from the public RDW vehicle dataset. No owner data is requested or displayed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let onRemove {
                    Section {
                        Button("Remove vehicle", role: .destructive) {
                            onRemove()
                            dismiss()
                        }
                    } footer: {
                        Text("This removes this vehicle and its public data from the current scan.")
                    }
                }
            }
            .navigationTitle("Vehicle details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var vehicleName: String? {
        let name = [track.vehicle?.make, track.vehicle?.model]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    private var hasTechnicalDetails: Bool {
        guard let vehicle = track.vehicle else { return false }
        return [
            vehicle.catalogPrice,
            vehicle.cylinderCount,
            vehicle.displacementCC,
            vehicle.emptyMassKG,
            vehicle.runningMassKG,
            vehicle.maximumMassKG
        ].contains { $0 != nil }
    }

    private var vehicleStatusText: String {
        VehicleDetailsStatusFormatter().text(
            for: track.cardState,
            plate: lookupPlate
        )
    }

    private var lookupPlate: String? {
        if let canonical = track.rdwLookupPlateCanonical,
           let plate = DutchLicensePlate(canonical) {
            return plate.formatted
        }
        return DutchLicensePlate(track.displayName)?.formatted
    }

    @ViewBuilder
    private func detail(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title, value: value)
        }
    }

    private func formattedDate(_ value: Date?) -> String? {
        guard let value else { return nil }
        return value.formatted(VehicleDetailsFormatStyles.date(locale: locale))
    }

    private func formattedCurrency(_ value: Int?) -> String? {
        guard let value else { return nil }
        return value.formatted(VehicleDetailsFormatStyles.currency(locale: locale))
    }

    private func formattedNumber(_ value: Int?, unit: String? = nil) -> String? {
        guard let value else { return nil }
        let number = value.formatted(VehicleDetailsFormatStyles.number(locale: locale))
        return unit.map { "\(number) \($0)" } ?? number
    }
}
