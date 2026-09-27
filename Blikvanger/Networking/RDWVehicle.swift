import Foundation

struct RDWVehicle: Codable, Equatable, Sendable {
    let kenteken: String
    let merk: String?
    let handelsbenaming: String?
    let voertuigsoort: String?
    let eersteKleur: String?
    let tweedeKleur: String?
    let datumEersteToelating: String?
    let catalogusprijs: String?
    let aantalCilinders: String?
    let cilinderinhoud: String?
    let massaLedigVoertuig: String?
    let massaRijklaar: String?
    let toegestaneMaximumMassaVoertuig: String?

    enum CodingKeys: String, CodingKey {
        case kenteken, merk, handelsbenaming, voertuigsoort
        case eersteKleur = "eerste_kleur"
        case tweedeKleur = "tweede_kleur"
        case datumEersteToelating = "datum_eerste_toelating"
        case catalogusprijs
        case aantalCilinders = "aantal_cilinders"
        case cilinderinhoud
        case massaLedigVoertuig = "massa_ledig_voertuig"
        case massaRijklaar = "massa_rijklaar"
        case toegestaneMaximumMassaVoertuig = "toegestane_maximum_massa_voertuig"
    }

    init(
        kenteken: String,
        merk: String?,
        handelsbenaming: String?,
        voertuigsoort: String?,
        eersteKleur: String?,
        tweedeKleur: String?,
        datumEersteToelating: String?,
        catalogusprijs: String?,
        aantalCilinders: String?,
        cilinderinhoud: String?,
        massaLedigVoertuig: String?,
        massaRijklaar: String?,
        toegestaneMaximumMassaVoertuig: String?
    ) {
        self.kenteken = kenteken
        self.merk = merk
        self.handelsbenaming = handelsbenaming
        self.voertuigsoort = voertuigsoort
        self.eersteKleur = eersteKleur
        self.tweedeKleur = tweedeKleur
        self.datumEersteToelating = datumEersteToelating
        self.catalogusprijs = catalogusprijs
        self.aantalCilinders = aantalCilinders
        self.cilinderinhoud = cilinderinhoud
        self.massaLedigVoertuig = massaLedigVoertuig
        self.massaRijklaar = massaRijklaar
        self.toegestaneMaximumMassaVoertuig = toegestaneMaximumMassaVoertuig
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kenteken = try values.decodeFlexibleString(forKey: .kenteken)
        merk = try values.decodeFlexibleStringIfPresent(forKey: .merk)
        handelsbenaming = try values.decodeFlexibleStringIfPresent(forKey: .handelsbenaming)
        voertuigsoort = try values.decodeFlexibleStringIfPresent(forKey: .voertuigsoort)
        eersteKleur = try values.decodeFlexibleStringIfPresent(forKey: .eersteKleur)
        tweedeKleur = try values.decodeFlexibleStringIfPresent(forKey: .tweedeKleur)
        datumEersteToelating = try values.decodeFlexibleStringIfPresent(forKey: .datumEersteToelating)
        catalogusprijs = try values.decodeFlexibleStringIfPresent(forKey: .catalogusprijs)
        aantalCilinders = try values.decodeFlexibleStringIfPresent(forKey: .aantalCilinders)
        cilinderinhoud = try values.decodeFlexibleStringIfPresent(forKey: .cilinderinhoud)
        massaLedigVoertuig = try values.decodeFlexibleStringIfPresent(forKey: .massaLedigVoertuig)
        massaRijklaar = try values.decodeFlexibleStringIfPresent(forKey: .massaRijklaar)
        toegestaneMaximumMassaVoertuig = try values.decodeFlexibleStringIfPresent(forKey: .toegestaneMaximumMassaVoertuig)
    }

    var firstRegistrationDate: Date? {
        guard let value = datumEersteToelating?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count == 8,
              let year = Int(value.prefix(4)),
              let month = Int(value.dropFirst(4).prefix(2)),
              let day = Int(value.suffix(2)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return date
    }

    var firstRegistrationYear: Int? {
        guard let firstRegistrationDate else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.component(.year, from: firstRegistrationDate)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) throws -> String {
        guard let value = try decodeFlexibleStringIfPresent(forKey: key) else {
            throw DecodingError.valueNotFound(
                String.self,
                DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Expected a string or number")
            )
        }
        return value
    }

    func decodeFlexibleStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Expected a string or number")
        )
    }
}
