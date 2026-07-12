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

    var summary: VehicleSummary {
        VehicleSummary(
            plate: DutchLicensePlate(kenteken)?.formatted ?? kenteken,
            make: merk?.rdwDisplayName,
            model: handelsbenaming?.rdwDisplayName,
            vehicleType: voertuigsoort?.rdwDisplayName,
            primaryColor: eersteKleur?.rdwDisplayName,
            secondaryColor: tweedeKleur?.rdwDisplayName,
            firstRegistrationDate: firstRegistrationDate,
            catalogPrice: catalogusprijs?.rdwInteger,
            cylinderCount: aantalCilinders?.rdwInteger,
            displacementCC: cilinderinhoud?.rdwInteger,
            emptyMassKG: massaLedigVoertuig?.rdwInteger,
            runningMassKG: massaRijklaar?.rdwInteger,
            maximumMassKG: toegestaneMaximumMassaVoertuig?.rdwInteger
        )
    }
}

enum RDWLookupResult: Equatable, Sendable {
    case found(RDWVehicle)
    case empty
    case offline
    case malformed
    case serverFailure(Int)
    case cancelled
}

protocol RDWClientProtocol: Sendable {
    func vehicle(for plate: DutchLicensePlate) async -> RDWLookupResult
    func clearCache() async
}

extension RDWClientProtocol {
    func clearCache() async {}
}

protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
}

struct RDWClientConfiguration: Sendable {
    var requestTimeout: TimeInterval = 8
    var maximumAttempts = 2
    var minimumRequestInterval: TimeInterval = 0.2
    var retryBaseDelay: TimeInterval = 0.4
    var maximumRetryDelay: TimeInterval = 2
    var positiveCacheLifetime: TimeInterval = 30 * 60
    var negativeCacheLifetime: TimeInterval = 5 * 60
    var offlineCacheLifetime: TimeInterval = 20
    var failureCacheLifetime: TimeInterval = 60
}

actor RDWClient: RDWClientProtocol {
    private struct CacheEntry: Sendable {
        let result: RDWLookupResult
        let expiresAt: Date
    }

    private struct InFlightRequest {
        let id: UUID
        let operation: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<RDWLookupResult, Never>]
    }

    private enum RequestError: Error {
        case timedOut
    }

    private let transport: any HTTPTransport
    private let configuration: RDWClientConfiguration
    private let now: @Sendable () -> Date
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: InFlightRequest] = [:]
    private var nextRequestStart = Date.distantPast

    init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        configuration: RDWClientConfiguration = RDWClientConfiguration(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.configuration = configuration
        self.now = now
    }

    func vehicle(for plate: DutchLicensePlate) async -> RDWLookupResult {
        guard !Task.isCancelled else { return .cancelled }
        let key = plate.canonical
        if let cached = cache[key] {
            if cached.expiresAt > now() { return cached.result }
            cache[key] = nil
        }

        let waiterID = UUID()
        if inFlight[key] == nil {
            let requestID = UUID()
            let operation = Task { [weak self] in
                guard let self else { return }
                let result = await self.performLookup(for: plate)
                await self.completeLookup(result, forKey: key, requestID: requestID)
            }
            inFlight[key] = InFlightRequest(id: requestID, operation: operation, waiters: [:])
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                guard var request = inFlight[key] else {
                    continuation.resume(returning: cache[key]?.result ?? .cancelled)
                    return
                }
                request.waiters[waiterID] = continuation
                inFlight[key] = request
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, forKey: key) }
        }
    }

    func clearCache() async {
        cache.removeAll()
        let requests = Array(inFlight.values)
        inFlight.removeAll()
        for request in requests {
            request.operation.cancel()
            for continuation in request.waiters.values {
                continuation.resume(returning: .cancelled)
            }
        }
    }

    nonisolated static func request(
        for plate: DutchLicensePlate,
        timeout: TimeInterval = 8
    ) -> URLRequest? {
        var components = URLComponents(string: "https://opendata.rdw.nl/resource/m9d7-ebf2.json")
        components?.queryItems = [
            URLQueryItem(name: "$select", value: "kenteken,merk,handelsbenaming,voertuigsoort,eerste_kleur,tweede_kleur,datum_eerste_toelating,catalogusprijs,aantal_cilinders,cilinderinhoud,massa_ledig_voertuig,massa_rijklaar,toegestane_maximum_massa_voertuig"),
            URLQueryItem(name: "$where", value: "kenteken='\(plate.canonical)'"),
            URLQueryItem(name: "$limit", value: "1")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = max(0.001, timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func cancelWaiter(_ waiterID: UUID, forKey key: String) {
        guard var request = inFlight[key],
              let continuation = request.waiters.removeValue(forKey: waiterID) else { return }
        if request.waiters.isEmpty {
            inFlight[key] = nil
            request.operation.cancel()
        } else {
            inFlight[key] = request
        }
        continuation.resume(returning: .cancelled)
    }

    private func completeLookup(_ result: RDWLookupResult, forKey key: String, requestID: UUID) {
        guard let current = inFlight[key], current.id == requestID,
              let request = inFlight.removeValue(forKey: key) else { return }
        if let lifetime = cacheLifetime(for: result), lifetime > 0 {
            cache[key] = CacheEntry(result: result, expiresAt: now().addingTimeInterval(lifetime))
        }
        for continuation in request.waiters.values {
            continuation.resume(returning: result)
        }
    }

    private func cacheLifetime(for result: RDWLookupResult) -> TimeInterval? {
        switch result {
        case .found:
            configuration.positiveCacheLifetime
        case .empty:
            configuration.negativeCacheLifetime
        case .offline:
            configuration.offlineCacheLifetime
        case .malformed, .serverFailure:
            configuration.failureCacheLifetime
        case .cancelled:
            nil
        }
    }

    private func performLookup(for plate: DutchLicensePlate) async -> RDWLookupResult {
        guard let request = Self.request(for: plate, timeout: configuration.requestTimeout) else {
            return .malformed
        }
        let maximumAttempts = max(1, configuration.maximumAttempts)

        for attempt in 0..<maximumAttempts {
            do {
                try await reserveRequestSlot()
                let (data, response) = try await Self.response(
                    from: transport,
                    request: request,
                    timeout: max(0.001, configuration.requestTimeout)
                )

                if (200..<300).contains(response.statusCode) {
                    guard let vehicles = try? JSONDecoder().decode([RDWVehicle].self, from: data) else {
                        return .malformed
                    }
                    guard !vehicles.isEmpty else { return .empty }
                    guard let vehicle = vehicles.first(where: {
                        Self.canonicalPlate($0.kenteken) == plate.canonical
                    }) else { return .malformed }
                    return .found(vehicle)
                }

                if Self.isRetryable(statusCode: response.statusCode), attempt + 1 < maximumAttempts {
                    let serverDelay = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                    guard await waitBeforeRetry(attempt: attempt, serverDelay: serverDelay) else { return .cancelled }
                    continue
                }
                return .serverFailure(response.statusCode)
            } catch is CancellationError {
                return .cancelled
            } catch RequestError.timedOut {
                if attempt + 1 < maximumAttempts {
                    guard await waitBeforeRetry(attempt: attempt) else { return .cancelled }
                    continue
                }
                return .offline
            } catch let error as URLError {
                if error.code == .cancelled, Task.isCancelled { return .cancelled }
                if Self.isRetryable(error), attempt + 1 < maximumAttempts {
                    guard await waitBeforeRetry(attempt: attempt) else { return .cancelled }
                    continue
                }
                return .offline
            } catch {
                return .offline
            }
        }
        return .offline
    }

    private func reserveRequestSlot() async throws {
        try Task.checkCancellation()
        let current = now()
        let scheduled = max(current, nextRequestStart)
        let delay = scheduled.timeIntervalSince(current)
        nextRequestStart = scheduled.addingTimeInterval(max(0, configuration.minimumRequestInterval))
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
    }

    private func waitBeforeRetry(attempt: Int, serverDelay: TimeInterval? = nil) async -> Bool {
        let exponential = max(0, configuration.retryBaseDelay) * pow(2, Double(attempt))
        let requested = max(exponential, serverDelay ?? 0)
        let delay = min(max(0, configuration.maximumRetryDelay), requested)
        guard delay > 0 else { return !Task.isCancelled }
        do {
            try await Task.sleep(for: .seconds(delay))
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func response(
        from transport: any HTTPTransport,
        request: URLRequest,
        timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask { try await transport.data(for: request) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw RequestError.timedOut
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw CancellationError() }
            return response
        }
    }

    private nonisolated static func isRetryable(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private nonisolated static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            true
        default:
            false
        }
    }

    private nonisolated static func canonicalPlate(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
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

private extension String {
    var rdwDisplayName: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.localizedCapitalized
    }

    var rdwInteger: Int? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        if let integer = Int(trimmed) { return integer }
        guard let decimal = Double(trimmed), decimal.isFinite, decimal.rounded() == decimal,
              decimal >= Double(Int.min), decimal <= Double(Int.max) else { return nil }
        return Int(decimal)
    }
}
