import simd
import XCTest
@testable import Blikvanger

final class RDWClientTests: XCTestCase {
    func testDecodesCompleteNumericAndMissingRecords() throws {
        let complete = try JSONDecoder().decode([RDWVehicle].self, from: Data(Self.completeJSON.utf8))[0]
        XCTAssertEqual(complete.kenteken, "12BD34")
        XCTAssertEqual(complete.catalogusprijs, "50000")
        XCTAssertEqual(complete.summary.make, "Tesla")
        XCTAssertEqual(complete.summary.model, "Model 3")
        XCTAssertEqual(complete.summary.vehicleType, "Personenauto")
        XCTAssertEqual(complete.summary.color, "Zwart / Wit")
        XCTAssertEqual(complete.summary.registrationYear, 2020)
        XCTAssertEqual(complete.summary.catalogPrice, 50_000)
        XCTAssertEqual(complete.summary.cylinderCount, 4)
        XCTAssertEqual(complete.summary.displacementCC, 1_998)
        XCTAssertEqual(complete.summary.emptyMassKG, 1_700)
        XCTAssertEqual(complete.summary.runningMassKG, 1_825)
        XCTAssertEqual(complete.summary.maximumMassKG, 2_250)

        let missing = try JSONDecoder().decode([RDWVehicle].self, from: Data("[{\"kenteken\":\"12BD34\"}]".utf8))[0]
        XCTAssertNil(missing.merk)
        XCTAssertNil(missing.firstRegistrationDate)
        XCTAssertNil(missing.summary.catalogPrice)

        let invalidDate = try JSONDecoder().decode(
            [RDWVehicle].self,
            from: Data("[{\"kenteken\":\"12BD34\",\"datum_eerste_toelating\":\"20200230\"}]".utf8)
        )[0]
        XCTAssertNil(invalidDate.firstRegistrationDate)

        let zeroPrice = try JSONDecoder().decode(
            [RDWVehicle].self,
            from: Data("[{\"kenteken\":\"12BD34\",\"catalogusprijs\":0,\"aantal_cilinders\":0}]".utf8)
        )[0]
        XCTAssertNil(zeroPrice.summary.catalogPrice)
        XCTAssertEqual(zeroPrice.summary.cylinderCount, 0)
    }

    func testDisplayFormatterPreservesKnownInitialismsWithoutDamagingNormalNames() throws {
        let vehicle = try JSONDecoder().decode(
            [RDWVehicle].self,
            from: Data("""
            [{
              "kenteken":"12BD34",
              "merk":"BMW",
              "handelsbenaming":"MODEL 3",
              "voertuigsoort":"PERSONENAUTO",
              "eerste_kleur":"DONKER BLAUW"
            }]
            """.utf8)
        )[0]

        XCTAssertEqual(vehicle.summary.make, "BMW")
        XCTAssertEqual(vehicle.summary.model, "Model 3")
        XCTAssertEqual(vehicle.summary.vehicleType, "Personenauto")
        XCTAssertEqual(vehicle.summary.primaryColor, "Donker Blauw")
    }

    func testFoundEmptyMalformedOfflineAndServerFailure() async {
        let plate = DutchLicensePlate("12BD34")!
        let configuration = Self.configuration()
        let found = await RDWClient(transport: StubTransport(.success(Self.completeJSON, 200)), configuration: configuration).vehicle(for: plate)
        let empty = await RDWClient(transport: StubTransport(.success("[]", 200)), configuration: configuration).vehicle(for: plate)
        let malformed = await RDWClient(transport: StubTransport(.success("nope", 200)), configuration: configuration).vehicle(for: plate)
        let wrongPlate = await RDWClient(transport: StubTransport(.success("[{\"kenteken\":\"34BD56\"}]", 200)), configuration: configuration).vehicle(for: plate)
        let server = await RDWClient(transport: StubTransport(.success("[]", 404)), configuration: configuration).vehicle(for: plate)
        let offline = await RDWClient(transport: StubTransport(.failure(.notConnectedToInternet)), configuration: configuration).vehicle(for: plate)
        XCTAssertEqual(found.foundVehicle?.kenteken, "12BD34")
        XCTAssertEqual(empty, .empty)
        XCTAssertEqual(malformed, .malformed)
        XCTAssertEqual(wrongPlate, .malformed)
        XCTAssertEqual(server, .serverFailure(404))
        XCTAssertEqual(offline, .offline)
    }

    func testRequestIsEncodedAndConcurrentLookupsAreDeduplicatedAndCached() async {
        let plate = DutchLicensePlate("12BD34")!
        let transport = CountingTransport(json: Self.completeJSON, delay: .milliseconds(40))
        let client = RDWClient(transport: transport, configuration: Self.configuration())
        async let first = client.vehicle(for: plate)
        async let second = client.vehicle(for: plate)
        let results = await (first, second)
        XCTAssertEqual(results.0, results.1)
        _ = await client.vehicle(for: plate)
        let requestCount = await transport.count
        XCTAssertEqual(requestCount, 1)

        let request = RDWClient.request(for: plate)!
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "$where" })?.value, "kenteken='12BD34'")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "$limit" })?.value, "1")
        let selection = components?.queryItems?.first(where: { $0.name == "$select" })?.value
        XCTAssertTrue(selection?.contains("toegestane_maximum_massa_voertuig") == true)
        XCTAssertEqual(request.timeoutInterval, 8)
    }

    func testClearCacheForcesTheNextLookupToUseTheNetwork() async {
        let plate = DutchLicensePlate("12BD34")!
        let transport = CountingTransport(json: Self.completeJSON)
        let client = RDWClient(transport: transport, configuration: Self.configuration())

        _ = await client.vehicle(for: plate)
        _ = await client.vehicle(for: plate)
        let cachedRequestCount = await transport.count
        XCTAssertEqual(cachedRequestCount, 1)

        await client.clearCache()
        _ = await client.vehicle(for: plate)
        let refreshedRequestCount = await transport.count
        XCTAssertEqual(refreshedRequestCount, 2)
    }

    func testNegativeAndOfflineCachesExpireIndependently() async {
        let plate = DutchLicensePlate("12BD34")!
        let clock = TestDate(Date(timeIntervalSince1970: 1_000))
        var configuration = Self.configuration()
        configuration.negativeCacheLifetime = 10
        configuration.offlineCacheLifetime = 3

        let emptyTransport = CountingTransport(json: "[]")
        let emptyClient = RDWClient(transport: emptyTransport, configuration: configuration, now: clock.now)
        let firstEmpty = await emptyClient.vehicle(for: plate)
        let cachedEmpty = await emptyClient.vehicle(for: plate)
        let firstEmptyCount = await emptyTransport.count
        XCTAssertEqual(firstEmpty, .empty)
        XCTAssertEqual(cachedEmpty, .empty)
        XCTAssertEqual(firstEmptyCount, 1)
        clock.advance(by: 11)
        let expiredEmpty = await emptyClient.vehicle(for: plate)
        let expiredEmptyCount = await emptyTransport.count
        XCTAssertEqual(expiredEmpty, .empty)
        XCTAssertEqual(expiredEmptyCount, 2)

        let offlineTransport = FailureCountingTransport(code: .notConnectedToInternet)
        let offlineClient = RDWClient(transport: offlineTransport, configuration: configuration, now: clock.now)
        let firstOffline = await offlineClient.vehicle(for: plate)
        let cachedOffline = await offlineClient.vehicle(for: plate)
        let firstOfflineCount = await offlineTransport.count
        XCTAssertEqual(firstOffline, .offline)
        XCTAssertEqual(cachedOffline, .offline)
        XCTAssertEqual(firstOfflineCount, 1)
        clock.advance(by: 4)
        let expiredOffline = await offlineClient.vehicle(for: plate)
        let expiredOfflineCount = await offlineTransport.count
        XCTAssertEqual(expiredOffline, .offline)
        XCTAssertEqual(expiredOfflineCount, 2)
    }

    func testTransientServerFailureRetriesWithMinimumSpacingThenCachesFinalFailure() async {
        let plate = DutchLicensePlate("12BD34")!
        var retryConfiguration = Self.configuration(maximumAttempts: 2)
        retryConfiguration.minimumRequestInterval = 0.03
        let recovering = ScriptedTransport([
            .response("[]", 503),
            .response(Self.completeJSON, 200)
        ])
        let recovered = await RDWClient(transport: recovering, configuration: retryConfiguration).vehicle(for: plate)
        let recoveringCount = await recovering.count
        let minimumStartInterval = await recovering.minimumStartInterval
        XCTAssertNotNil(recovered.foundVehicle)
        XCTAssertEqual(recoveringCount, 2)
        XCTAssertGreaterThanOrEqual(minimumStartInterval, 0.02)

        var failureConfiguration = Self.configuration()
        failureConfiguration.failureCacheLifetime = 30
        let failing = CountingTransport(json: "[]", statusCode: 503)
        let client = RDWClient(transport: failing, configuration: failureConfiguration)
        let firstFailure = await client.vehicle(for: plate)
        let cachedFailure = await client.vehicle(for: plate)
        let failureCount = await failing.count
        XCTAssertEqual(firstFailure, .serverFailure(503))
        XCTAssertEqual(cachedFailure, .serverFailure(503))
        XCTAssertEqual(failureCount, 1)
    }

    func testExplicitTimeoutCancelsTransportAndIsShortTermCachedAsOffline() async {
        let plate = DutchLicensePlate("12BD34")!
        var configuration = Self.configuration()
        configuration.requestTimeout = 0.025
        configuration.offlineCacheLifetime = 30
        let transport = SlowTransport(delay: .seconds(10), json: Self.completeJSON)
        let client = RDWClient(transport: transport, configuration: configuration)

        let start = ContinuousClock.now
        let timedOut = await client.vehicle(for: plate)
        let timeoutCount = await transport.count
        let timeoutCancellationCount = await transport.cancellationCount
        XCTAssertEqual(timedOut, .offline)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        XCTAssertEqual(timeoutCount, 1)
        XCTAssertEqual(timeoutCancellationCount, 1)

        let cachedTimeout = await client.vehicle(for: plate)
        let cachedTimeoutCount = await transport.count
        XCTAssertEqual(cachedTimeout, .offline)
        XCTAssertEqual(cachedTimeoutCount, 1, "A timeout must be cached briefly to prevent a request storm")
    }

    func testCancellingOnlyWaiterReturnsCancelledAndCancelsUnderlyingTransport() async {
        let plate = DutchLicensePlate("12BD34")!
        var configuration = Self.configuration()
        configuration.requestTimeout = 5
        let transport = SlowTransport(delay: .seconds(10), json: Self.completeJSON)
        let client = RDWClient(transport: transport, configuration: configuration)
        let lookup = Task { await client.vehicle(for: plate) }
        await transport.waitUntilStarted()

        lookup.cancel()
        let cancelledResult = await lookup.value
        await transport.waitUntilCancelled()
        let cancellationCount = await transport.cancellationCount
        XCTAssertEqual(cancelledResult, .cancelled)
        XCTAssertEqual(cancellationCount, 1)
    }

    func testCancellingOneDeduplicatedWaiterDoesNotCancelRemainingLookup() async {
        let plate = DutchLicensePlate("12BD34")!
        var configuration = Self.configuration()
        configuration.requestTimeout = 5
        let transport = SlowTransport(delay: .milliseconds(120), json: Self.completeJSON)
        let client = RDWClient(transport: transport, configuration: configuration)
        let first = Task { await client.vehicle(for: plate) }
        await transport.waitUntilStarted()
        let second = Task { await client.vehicle(for: plate) }
        try? await Task.sleep(for: .milliseconds(20))

        first.cancel()
        let cancelledResult = await first.value
        let remainingResult = await second.value
        let requestCount = await transport.count
        let cancellationCount = await transport.cancellationCount
        XCTAssertEqual(cancelledResult, .cancelled)
        XCTAssertNotNil(remainingResult.foundVehicle)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(cancellationCount, 0)
    }

    func testCancelledRequestCompletionCannotConsumeReplacementWaiters() async {
        let plate = DutchLicensePlate("12BD34")!
        var configuration = Self.configuration()
        configuration.requestTimeout = 5
        let transport = CancellationRaceTransport(json: Self.completeJSON)
        let client = RDWClient(transport: transport, configuration: configuration)
        let abandoned = Task { await client.vehicle(for: plate) }
        await transport.waitUntilStarted()

        abandoned.cancel()
        let abandonedResult = await abandoned.value
        let replacementResult = await client.vehicle(for: plate)
        let requestCount = await transport.count

        XCTAssertEqual(abandonedResult, .cancelled)
        XCTAssertNotNil(replacementResult.foundVehicle)
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testEnrichmentPreservesFullVehicleDetailsAndConfirmedCardShowsYear() async throws {
        let manager = AnchorManager()
        var track = manager.createAnchor(at: matrix_identity_float4x4)
        track.cardState = .confirming
        manager.update(track)
        let vehicle = try JSONDecoder().decode([RDWVehicle].self, from: Data(Self.completeJSON.utf8))[0]

        await VehicleEnrichmentService().enrich(
            trackID: track.id,
            plate: DutchLicensePlate("12BD34")!,
            anchorManager: manager,
            client: ResultClient(.found(vehicle))
        )

        let enriched = manager.track(id: track.id)!
        XCTAssertEqual(enriched.cardState, .confirmed)
        XCTAssertEqual(enriched.rdwEnrichmentStatus, .found)
        XCTAssertEqual(enriched.vehicle?.catalogPrice, 50_000)
        XCTAssertEqual(enriched.vehicle?.maximumMassKG, 2_250)
        let subtitle = VehicleCardView.subtitle(for: enriched)
        XCTAssertTrue(subtitle.contains("Tesla"))
        XCTAssertTrue(subtitle.contains("Zwart / Wit"))
        XCTAssertTrue(subtitle.contains("2020"))
    }

    @MainActor
    func testEnrichmentExposesExactPlateForTheWholePendingRequest() async {
        let manager = AnchorManager()
        var track = manager.createAnchor(at: matrix_identity_float4x4)
        track.lifecycle = .confirming
        track.cardState = .confirming
        track.displayName = "12-BD-34"
        track.rdwLookupPlateCanonical = "12BD34"
        manager.update(track)
        let client = SuspendingResultClient()

        let enrichment = Task { @MainActor in
            await VehicleEnrichmentService().enrich(
                trackID: track.id,
                plate: DutchLicensePlate("12BD34")!,
                anchorManager: manager,
                client: client
            )
        }
        await client.waitUntilStarted()

        let pending = manager.track(id: track.id)
        XCTAssertEqual(pending?.displayName, "12-BD-34")
        XCTAssertEqual(pending?.cardState, .loading)
        XCTAssertEqual(pending?.rdwLookupPlateCanonical, "12BD34")
        XCTAssertEqual(pending?.rdwEnrichmentStatus, .loading)
        XCTAssertEqual(VehicleCardView.subtitle(for: pending!), "Looking up 12-BD-34 in RDW…")
        XCTAssertEqual(
            PendingPlateLookupFormatter().text(for: manager.tracks),
            "Checking 12-BD-34 with RDW…"
        )

        await client.complete(with: .empty)
        await enrichment.value
        XCTAssertEqual(manager.track(id: track.id)?.cardState, .uncertain)
        XCTAssertNil(PendingPlateLookupFormatter().text(for: manager.tracks))
    }

    @MainActor
    func testCancelledEnrichmentPreservesAnchorAndRecognizedPlateWithoutOfflineError() async {
        let manager = AnchorManager()
        var track = manager.createAnchor(at: matrix_identity_float4x4)
        track.lifecycle = .confirming
        track.cardState = .confirming
        manager.update(track)

        await VehicleEnrichmentService().enrich(
            trackID: track.id,
            plate: DutchLicensePlate("12BD34")!,
            anchorManager: manager,
            client: ResultClient(.cancelled)
        )

        let current = manager.track(id: track.id)
        XCTAssertNotNil(current)
        XCTAssertEqual(current?.displayName, "12-BD-34")
        XCTAssertEqual(current?.cardState, .confirming)
        XCTAssertEqual(current?.lifecycle, .anchored)
        XCTAssertEqual(current?.rdwEnrichmentStatus, .notRequested)
        XCTAssertNil(current?.vehicle)
    }

    @MainActor
    func testEveryCompletedRDWFailureLeavesPlateConfirmationLifecycle() async {
        let results: [RDWLookupResult] = [
            .empty,
            .offline,
            .serverFailure(503),
            .malformed,
            .cancelled
        ]

        for result in results {
            let manager = AnchorManager()
            var track = manager.createAnchor(at: matrix_identity_float4x4)
            track.lifecycle = .confirming
            track.cardState = .confirming
            manager.update(track)

            await VehicleEnrichmentService().enrich(
                trackID: track.id,
                plate: DutchLicensePlate("12BD34")!,
                anchorManager: manager,
                client: ResultClient(result)
            )

            XCTAssertEqual(manager.track(id: track.id)?.lifecycle, .anchored, "Result: \(result)")
        }
    }

    @MainActor
    func testEnrichmentSuppressesRepeatedNegativeLookupUntilRetryWindowExpires() async {
        let manager = AnchorManager()
        var track = manager.createAnchor(at: matrix_identity_float4x4)
        track.lifecycle = .confirming
        track.cardState = .confirming
        manager.update(track)
        let clock = TestDate(Date(timeIntervalSince1970: 2_000))
        let client = CountingResultClient(.empty)
        let service = VehicleEnrichmentService(now: clock.now)
        let plate = DutchLicensePlate("12BD34")!

        await service.enrich(trackID: track.id, plate: plate, anchorManager: manager, client: client)
        await service.enrich(trackID: track.id, plate: plate, anchorManager: manager, client: client)
        let suppressedCount = await client.count
        XCTAssertEqual(suppressedCount, 1)
        XCTAssertEqual(manager.track(id: track.id)?.rdwEnrichmentStatus, .empty)
        XCTAssertEqual(manager.track(id: track.id)?.lifecycle, .anchored)

        clock.advance(by: 301)
        await service.enrich(trackID: track.id, plate: plate, anchorManager: manager, client: client)
        let retriedCount = await client.count
        XCTAssertEqual(retriedCount, 2)
    }

    private static func configuration(maximumAttempts: Int = 1) -> RDWClientConfiguration {
        var configuration = RDWClientConfiguration()
        configuration.maximumAttempts = maximumAttempts
        configuration.minimumRequestInterval = 0
        configuration.retryBaseDelay = 0
        configuration.maximumRetryDelay = 0
        configuration.requestTimeout = 1
        return configuration
    }

    private static let completeJSON = """
    [{
      "kenteken":"12BD34",
      "merk":"TESLA",
      "handelsbenaming":"MODEL 3",
      "voertuigsoort":"PERSONENAUTO",
      "eerste_kleur":"ZWART",
      "tweede_kleur":"WIT",
      "datum_eerste_toelating":20200115,
      "catalogusprijs":50000.0,
      "aantal_cilinders":4,
      "cilinderinhoud":1998,
      "massa_ledig_voertuig":1700,
      "massa_rijklaar":1825,
      "toegestane_maximum_massa_voertuig":2250
    }]
    """
}

private extension RDWLookupResult {
    var foundVehicle: RDWVehicle? {
        if case .found(let vehicle) = self { return vehicle }
        return nil
    }
}

private struct ResultClient: RDWClientProtocol {
    let result: RDWLookupResult
    init(_ result: RDWLookupResult) { self.result = result }
    func vehicle(for plate: DutchLicensePlate) async -> RDWLookupResult { result }
}

private actor CountingResultClient: RDWClientProtocol {
    private(set) var count = 0
    let result: RDWLookupResult
    init(_ result: RDWLookupResult) { self.result = result }

    func vehicle(for plate: DutchLicensePlate) async -> RDWLookupResult {
        count += 1
        return result
    }
}

private actor SuspendingResultClient: RDWClientProtocol {
    private var started = false
    private var continuation: CheckedContinuation<RDWLookupResult, Never>?

    func vehicle(for plate: DutchLicensePlate) async -> RDWLookupResult {
        started = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func complete(with result: RDWLookupResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private struct StubTransport: HTTPTransport {
    enum Response: Sendable {
        case success(String, Int)
        case failure(URLError.Code)
    }

    let response: Response
    init(_ response: Response) { self.response = response }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        switch response {
        case .success(let json, let status):
            return (Data(json.utf8), Self.response(url: request.url!, status: status))
        case .failure(let code):
            throw URLError(code)
        }
    }

    static func response(url: URL, status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }
}

private actor CountingTransport: HTTPTransport {
    private(set) var count = 0
    let json: String
    let statusCode: Int
    let delay: Duration

    init(json: String, statusCode: Int = 200, delay: Duration = .zero) {
        self.json = json
        self.statusCode = statusCode
        self.delay = delay
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        return (Data(json.utf8), StubTransport.response(url: request.url!, status: statusCode))
    }
}

private actor FailureCountingTransport: HTTPTransport {
    private(set) var count = 0
    let code: URLError.Code
    init(code: URLError.Code) { self.code = code }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        throw URLError(code)
    }
}

private actor ScriptedTransport: HTTPTransport {
    enum Step: Sendable {
        case response(String, Int)
    }

    private var steps: [Step]
    private var starts: [Date] = []

    init(_ steps: [Step]) { self.steps = steps }

    var count: Int { starts.count }

    var minimumStartInterval: TimeInterval {
        zip(starts.dropFirst(), starts).map { $0.0.timeIntervalSince($0.1) }.min() ?? 0
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        starts.append(Date())
        let step = steps.isEmpty ? .response("[]", 500) : steps.removeFirst()
        switch step {
        case .response(let json, let status):
            return (Data(json.utf8), StubTransport.response(url: request.url!, status: status))
        }
    }
}

private actor SlowTransport: HTTPTransport {
    private(set) var count = 0
    private(set) var cancellationCount = 0
    let delay: Duration
    let json: String

    init(delay: Duration, json: String) {
        self.delay = delay
        self.json = json
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        do {
            try await Task.sleep(for: delay)
        } catch {
            cancellationCount += 1
            throw error
        }
        return (Data(json.utf8), StubTransport.response(url: request.url!, status: 200))
    }

    func waitUntilStarted() async {
        while count == 0 { await Task.yield() }
    }

    func waitUntilCancelled() async {
        while cancellationCount == 0 { await Task.yield() }
    }
}

private actor CancellationRaceTransport: HTTPTransport {
    private(set) var count = 0
    let json: String

    init(json: String) { self.json = json }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        if count == 1 {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                let cleanup = Task.detached {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                await cleanup.value
                throw error
            }
        } else {
            try await Task.sleep(for: .milliseconds(100))
        }
        return (Data(json.utf8), StubTransport.response(url: request.url!, status: 200))
    }

    func waitUntilStarted() async {
        while count == 0 { await Task.yield() }
    }
}

private final class TestDate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}
