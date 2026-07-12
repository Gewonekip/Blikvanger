import Foundation

@MainActor
struct VehicleEnrichmentService {
    private let now: @MainActor () -> Date

    init(now: @escaping @MainActor () -> Date = Date.init) {
        self.now = now
    }

    func enrich(
        trackID: UUID,
        plate: DutchLicensePlate,
        anchorManager: AnchorManager,
        client: any RDWClientProtocol
    ) async {
        guard var track = anchorManager.track(id: trackID), track.vehicle == nil else { return }
        let requestDate = now()
        if track.rdwLookupPlateCanonical == plate.canonical {
            if track.rdwEnrichmentStatus == .loading || track.rdwEnrichmentStatus == .found { return }
            if let retryAfter = track.rdwRetryAfter, retryAfter > requestDate { return }
        }
        track.displayName = plate.formatted
        track.cardState = .loading
        track.rdwLookupPlateCanonical = plate.canonical
        track.rdwEnrichmentStatus = .loading
        track.rdwRetryAfter = nil
        anchorManager.update(track)
        let result = await client.vehicle(for: plate)
        guard var current = anchorManager.track(id: trackID),
              current.vehicle == nil,
              current.rdwLookupPlateCanonical == plate.canonical else { return }
        // Recognition is complete regardless of RDW's outcome. Lookup failures
        // may change the card's data state, but the spatial label is no longer in
        // the plate-confirmation lifecycle.
        current.lifecycle = .anchored
        switch result {
        case .found(let vehicle):
            current.vehicle = vehicle.summary
            current.displayName = plate.formatted
            current.cardState = .confirmed
            current.rdwEnrichmentStatus = .found
            current.rdwRetryAfter = nil
        case .empty:
            current.displayName = plate.formatted
            current.cardState = .uncertain
            current.rdwEnrichmentStatus = .empty
            current.rdwRetryAfter = now().addingTimeInterval(5 * 60)
        case .offline:
            current.displayName = plate.formatted
            current.cardState = .unavailable
            current.rdwEnrichmentStatus = .unavailable
            current.rdwRetryAfter = now().addingTimeInterval(20)
        case .serverFailure:
            current.displayName = plate.formatted
            current.cardState = .unavailable
            current.rdwEnrichmentStatus = .unavailable
            current.rdwRetryAfter = now().addingTimeInterval(60)
        case .malformed:
            current.displayName = plate.formatted
            current.cardState = .uncertain
            current.rdwEnrichmentStatus = .malformed
            current.rdwRetryAfter = now().addingTimeInterval(60)
        case .cancelled:
            // Cancellation is a lifecycle event, not a network failure. Keep the
            // recognized plate and let a later scan retry enrichment.
            current.displayName = plate.formatted
            current.cardState = .confirming
            current.rdwEnrichmentStatus = .notRequested
            current.rdwRetryAfter = nil
        }
        anchorManager.update(current)
    }
}
