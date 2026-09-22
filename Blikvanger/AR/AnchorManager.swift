import ARKit
import Foundation
import Observation
import simd

@MainActor
protocol WorldAnchorSession: AnyObject {
    func add(anchor: ARAnchor)
    func remove(anchor: ARAnchor)
}

extension ARSession: WorldAnchorSession {}

@MainActor
@Observable
final class AnchorManager {
    private(set) var tracks: [VehicleTrack] = []
    var selectedTrackID: UUID?

    private weak var session: WorldAnchorSession?
    private var anchors: [UUID: ARAnchor] = [:]
    private var nextVehicleNumber = 1

    init(session: WorldAnchorSession? = nil) {
        self.session = session
    }

    func attach(to session: WorldAnchorSession) {
        if self.session === session { return }
        self.session = session
        for anchor in anchors.values {
            session.add(anchor: anchor)
        }
    }

    @discardableResult
    func createAnchor(
        at transform: simd_float4x4,
        displayName: String? = nil,
        now: Date = Date()
    ) -> VehicleTrack {
        let anchor = ARAnchor(transform: transform)
        let name: String
        if let displayName {
            name = displayName
        } else {
            name = "Car \(nextVehicleNumber)"
            nextVehicleNumber += 1
        }
        let track = VehicleTrack(
            displayName: name,
            transform: transform,
            anchorIdentifier: anchor.identifier,
            now: now
        )
        anchors[track.id] = anchor
        tracks.append(track)
        session?.add(anchor: anchor)
        selectedTrackID = track.id
        return track
    }

    func remove(trackID: UUID) {
        if let anchor = anchors.removeValue(forKey: trackID) {
            session?.remove(anchor: anchor)
        }
        tracks.removeAll { $0.id == trackID }
        if selectedTrackID == trackID {
            selectedTrackID = nil
        }
    }

    func reset() {
        for anchor in anchors.values {
            session?.remove(anchor: anchor)
        }
        anchors.removeAll()
        tracks.removeAll()
        selectedTrackID = nil
        nextVehicleNumber = 1
    }

    func track(id: UUID) -> VehicleTrack? {
        tracks.first { $0.id == id }
    }

    func update(_ track: VehicleTrack) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let spatialSource = tracks[index]
        var metadataUpdate = track
        // Metadata enrichment must never desynchronize the model transform from
        // the immutable ARAnchor stored for this track.
        metadataUpdate.stableTransform = spatialSource.stableTransform
        metadataUpdate.anchorIdentifier = spatialSource.anchorIdentifier
        metadataUpdate.createdAt = spatialSource.createdAt
        tracks[index] = metadataUpdate
    }

    /// ARKit may refine an anchor's transform when its world map is adjusted or
    /// relocalized. Keep duplicate reassociation on that same authoritative
    /// spatial transform while preserving the track and ARAnchor identities.
    func synchronizeARKitTransform(anchorIdentifier: UUID, transform: simd_float4x4) {
        guard transform.columns.0.x.isFinite,
              transform.columns.0.y.isFinite,
              transform.columns.0.z.isFinite,
              transform.columns.0.w.isFinite,
              transform.columns.1.x.isFinite,
              transform.columns.1.y.isFinite,
              transform.columns.1.z.isFinite,
              transform.columns.1.w.isFinite,
              transform.columns.2.x.isFinite,
              transform.columns.2.y.isFinite,
              transform.columns.2.z.isFinite,
              transform.columns.2.w.isFinite,
              transform.columns.3.x.isFinite,
              transform.columns.3.y.isFinite,
              transform.columns.3.z.isFinite,
              transform.columns.3.w.isFinite,
              let index = tracks.firstIndex(where: { $0.anchorIdentifier == anchorIdentifier }) else { return }
        let current = tracks[index].stableTransform
        let maximumDifference = (0..<4).flatMap { column in
            (0..<4).map { row in abs(current[column][row] - transform[column][row]) }
        }.max() ?? 0
        guard maximumDifference >= 0.001 else { return }
        tracks[index].stableTransform = transform
    }
}
