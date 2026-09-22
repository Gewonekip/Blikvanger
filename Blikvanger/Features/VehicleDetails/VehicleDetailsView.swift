import SwiftUI

struct VehicleDetailsStatusFormatter: Sendable {
    func text(
        for state: VehicleCardState,
        plate: String? = nil
    ) -> String {
        return switch state {
        case .loading:
            plate.map { "Checking plate \($0) in the public RDW dataset…" }
                ?? "Loading public RDW vehicle data…"
        case .unavailable:
            "RDW vehicle data is temporarily unavailable. The vehicle remains saved for this scan."
        case .uncertain:
            "No reliable RDW vehicle record is available for this plate."
        case .generic:
            "Recognize a Dutch plate to load public vehicle data."
        case .candidate:
            "The vehicle position is saved. Plate detection and reading pause while these details are open; close them to continue across several frames."
        case .confirming:
            plate.map { "Plate \($0) was recognized. Preparing the RDW lookup…" }
                ?? "The plate was recognized. Preparing the RDW lookup…"
        case .confirmed:
            "The plate is confirmed; public vehicle details are not available for this record."
        }
    }
}

struct VehicleDetailsView: View {
    let track: VehicleTrack
    let onRemove: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

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
                        detail("Make", track.vehicle?.make)
                        detail("Model", track.vehicle?.model)
                        detail("Type", track.vehicle?.vehicleType)
                        detail("Primary color", track.vehicle?.primaryColor)
                        detail("Secondary color", track.vehicle?.secondaryColor)
                        detail("First registration", formattedDate(track.vehicle?.firstRegistrationDate))
                    }
                }

                if hasTechnicalDetails {
                    Section("Technical data") {
                        detail("Catalog price", formattedCurrency(track.vehicle?.catalogPrice))
                        detail("Cylinders", formattedNumber(track.vehicle?.cylinderCount))
                        detail("Engine displacement", formattedNumber(track.vehicle?.displacementCC, unit: "cm³"))
                        detail("Empty mass", formattedNumber(track.vehicle?.emptyMassKG, unit: "kg"))
                        detail("Running mass", formattedNumber(track.vehicle?.runningMassKG, unit: "kg"))
                        detail("Maximum mass", formattedNumber(track.vehicle?.maximumMassKG, unit: "kg"))
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
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: value)
    }

    private func formattedCurrency(_ value: Int?) -> String? {
        guard let value else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value))
    }

    private func formattedNumber(_ value: Int?, unit: String? = nil) -> String? {
        guard let value else { return nil }
        let number = value.formatted(.number.grouping(.automatic))
        return unit.map { "\(number) \($0)" } ?? number
    }
}
