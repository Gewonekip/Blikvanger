import simd
import XCTest
@testable import Blikvanger

final class VehicleEnrichmentRetryPolicyTests: XCTestCase {
    func testOnlyExpiredRecognizedFailureBecomesDue() {
        let now = Date(timeIntervalSince1970: 1_000)
        var due = VehicleTrack(
            displayName: "12-BD-34",
            transform: matrix_identity_float4x4
        )
        due.rdwLookupPlateCanonical = "12BD34"
        due.rdwEnrichmentStatus = .unavailable
        due.rdwRetryAfter = now.addingTimeInterval(-1)

        var future = due
        future.rdwRetryAfter = now.addingTimeInterval(20)
        var loading = due
        loading.rdwEnrichmentStatus = .loading
        var anonymous = due
        anonymous.rdwLookupPlateCanonical = nil

        let requests = VehicleEnrichmentRetryPolicy().dueRequests(
            in: [future, loading, anonymous, due],
            at: now
        )
        XCTAssertEqual(requests, [
            VehicleEnrichmentRetryRequest(trackID: due.id, plate: DutchLicensePlate("12BD34")!)
        ])
    }

    func testCancelledRecognizedLookupWithoutDelayRetries() {
        var track = VehicleTrack(
            displayName: "12-BD-34",
            transform: matrix_identity_float4x4
        )
        track.rdwLookupPlateCanonical = "12BD34"
        track.rdwEnrichmentStatus = .notRequested
        track.rdwRetryAfter = nil
        XCTAssertEqual(
            VehicleEnrichmentRetryPolicy().dueRequests(in: [track], at: Date()).first?.trackID,
            track.id
        )
    }
}
