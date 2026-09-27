import Foundation

extension RDWVehicle {
    var summary: VehicleSummary {
        VehicleSummary(
            plate: DutchLicensePlate(kenteken)?.formatted ?? kenteken,
            make: RDWDisplayNameFormatter.text(merk),
            model: RDWDisplayNameFormatter.text(handelsbenaming),
            vehicleType: RDWDisplayNameFormatter.text(voertuigsoort),
            primaryColor: RDWDisplayNameFormatter.text(eersteKleur),
            secondaryColor: RDWDisplayNameFormatter.text(tweedeKleur),
            firstRegistrationDate: firstRegistrationDate,
            catalogPrice: RDWValueParser.positiveInteger(catalogusprijs),
            cylinderCount: RDWValueParser.integer(aantalCilinders),
            displacementCC: RDWValueParser.integer(cilinderinhoud),
            emptyMassKG: RDWValueParser.integer(massaLedigVoertuig),
            runningMassKG: RDWValueParser.integer(massaRijklaar),
            maximumMassKG: RDWValueParser.integer(toegestaneMaximumMassaVoertuig)
        )
    }
}

enum RDWDisplayNameFormatter {
    private static let preservedInitialisms: Set<String> = [
        "BMW", "BYD", "DAF", "DS", "GMC", "MAN", "MG", "RAM", "VW"
    ]

    static func text(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let words = raw.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return words.map { formatWord(String($0)) }.joined(separator: " ")
    }

    private static func formatWord(_ word: String) -> String {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return normalized }
        if preservedInitialisms.contains(normalized.uppercased()) {
            return normalized.uppercased()
        }
        return normalized.localizedCapitalized
    }
}

enum RDWValueParser {
    static func integer(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let integer = Int(trimmed) { return integer }
        guard let decimal = Double(trimmed), decimal.isFinite, decimal.rounded() == decimal,
              decimal >= Double(Int.min), decimal <= Double(Int.max) else { return nil }
        return Int(decimal)
    }

    /// A catalog price is a monetary amount; never present zero as a usable price.
    static func positiveInteger(_ raw: String?) -> Int? {
        guard let value = integer(raw), value > 0 else { return nil }
        return value
    }
}
