import Foundation

struct ScanGuidanceReducer: Sendable {
    func message(
        diagnostics: AutomaticPipelineDiagnostics,
        tracks: [VehicleTrack],
        secondsSinceDetection: TimeInterval,
        readyMessage: String
    ) -> String? {
        if let pendingLookup = PendingPlateLookupFormatter().text(for: tracks) {
            return pendingLookup
        }
        guard diagnostics.detections > 0 else {
            guard secondsSinceDetection >= 0.8 else { return nil }
            if tracks.contains(where: { $0.cardState == .loading }) {
                return "Plate confirmed — loading public vehicle data"
            }
            if tracks.contains(where: { $0.cardState == .confirmed }) {
                return "Vehicle confirmed — point at another plate when ready"
            }
            if tracks.contains(where: { $0.cardState == .unavailable }) {
                return "Vehicle saved — RDW is temporarily unavailable"
            }
            if tracks.contains(where: { $0.cardState == .uncertain }) {
                return "Vehicle saved — plate or RDW result remains uncertain"
            }
            if !tracks.isEmpty {
                return "Vehicle position saved — keep the plate in view for reading"
            }
            return readyMessage
        }
        if let cardState = diagnostics.currentTargetCardState {
            return switch cardState {
            case .generic, .candidate:
                "Vehicle found — reading its plate"
            case .confirming:
                "Plate confirmed — preparing public vehicle data"
            case .loading:
                "Plate confirmed — loading public vehicle data"
            case .confirmed:
                "Vehicle already labeled — point at another plate when ready"
            case .uncertain:
                "Vehicle already saved — this plate remains uncertain"
            case .unavailable:
                "Vehicle already saved — RDW is temporarily unavailable"
            }
        }
        if diagnostics.poseCandidates == 0 {
            return "Plate found — hold the iPhone steady"
        }
        if diagnostics.maximumDepthSamples < 3 {
            return "Plate found — move a little closer"
        }
        if diagnostics.acceptedPoseEstimates == 0 {
            return "Plate found — hold steady while its position is measured"
        }
        if diagnostics.maximumNormallyTrackedPoseSamples < 2 {
            return "Plate measured — move the iPhone slowly"
        }
        return "Measuring the vehicle position — hold steady"
    }
}

struct PendingPlateLookupFormatter: Sendable {
    func text(for tracks: [VehicleTrack]) -> String? {
        let pending = tracks
            .filter { $0.cardState == .loading || $0.cardState == .confirming }
            .sorted(by: priority)
        guard let track = pending.first,
              let plate = formattedPlate(for: track) else { return nil }

        return switch track.cardState {
        case .confirming:
            "\(plate) recognized — preparing RDW lookup"
        case .loading:
            "Checking \(plate) with RDW…"
        default:
            nil
        }
    }

    private func formattedPlate(for track: VehicleTrack) -> String? {
        if let canonical = track.rdwLookupPlateCanonical,
           let plate = DutchLicensePlate(canonical) {
            return plate.formatted
        }
        return DutchLicensePlate(track.displayName)?.formatted
    }

    private func priority(_ lhs: VehicleTrack, _ rhs: VehicleTrack) -> Bool {
        if lhs.cardState != rhs.cardState {
            return lhs.cardState == .loading
        }
        if lhs.lastSeenAt != rhs.lastSeenAt {
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
