import Foundation

struct VehicleEnrichmentRetryRequest: Equatable, Sendable {
    let trackID: UUID
    let plate: DutchLicensePlate
}

struct VehicleEnrichmentRetryPolicy: Sendable {
    func dueRequests(in tracks: [VehicleTrack], at date: Date) -> [VehicleEnrichmentRetryRequest] {
        tracks.compactMap { track in
            guard track.vehicle == nil,
                  track.rdwEnrichmentStatus != .loading,
                  track.rdwEnrichmentStatus != .found,
                  let canonical = track.rdwLookupPlateCanonical,
                  let plate = DutchLicensePlate(canonical),
                  track.rdwRetryAfter.map({ $0 <= date }) ?? true else { return nil }
            return VehicleEnrichmentRetryRequest(trackID: track.id, plate: plate)
        }
    }
}
