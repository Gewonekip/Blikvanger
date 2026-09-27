import Foundation

struct ScanGuidanceReducer: Sendable {
    static var scanDistanceInstruction: String {
        AppStrings.text("Scan vehicles from 1–5 metres away")
    }

    func message(
        status: AutomaticPipelineStatus,
        tracks: [VehicleTrack],
        secondsSinceDetection: TimeInterval,
        readyMessage: String
    ) -> String? {
        if let pendingLookup = PendingPlateLookupFormatter().text(for: tracks) {
            return pendingLookup
        }
        guard status.detections > 0 else {
            guard secondsSinceDetection >= 0.8 else { return nil }
            if tracks.contains(where: { $0.cardState == .loading }) {
                return AppStrings.text("Plate confirmed — loading public vehicle data")
            }
            if tracks.contains(where: { $0.cardState == .confirmed }) {
                return AppStrings.text("Vehicle confirmed — point at another plate when ready")
            }
            if tracks.contains(where: { $0.cardState == .unavailable }) {
                return AppStrings.text("Vehicle saved — RDW is temporarily unavailable")
            }
            if tracks.contains(where: { $0.cardState == .uncertain }) {
                return AppStrings.text("Vehicle saved — plate or RDW result remains uncertain")
            }
            if !tracks.isEmpty {
                return AppStrings.text("Vehicle position saved — keep the plate in view for reading")
            }
            return readyMessage
        }
        if let cardState = status.currentTargetCardState {
            return switch cardState {
            case .generic, .candidate:
                AppStrings.text("Vehicle found — reading its plate")
            case .confirming:
                AppStrings.text("Plate confirmed — preparing public vehicle data")
            case .loading:
                AppStrings.text("Plate confirmed — loading public vehicle data")
            case .confirmed:
                AppStrings.text("Vehicle already labeled — point at another plate when ready")
            case .uncertain:
                AppStrings.text("Vehicle already saved — this plate remains uncertain")
            case .unavailable:
                AppStrings.text("Vehicle already saved — RDW is temporarily unavailable")
            }
        }
        if status.poseCandidates == 0 {
            return AppStrings.text("Plate found — hold the iPhone steady")
        }
        if status.maximumDepthSamples < 3 {
            return AppStrings.text("Plate found — move a little closer")
        }
        if status.acceptedPoseEstimates == 0 {
            return AppStrings.text("Plate found — hold steady while its position is measured")
        }
        if status.maximumNormallyTrackedPoseSamples < 2 {
            return AppStrings.text("Plate measured — move the iPhone slowly")
        }
        return AppStrings.text("Measuring the vehicle position — hold steady")
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
            AppStrings.text("%@ recognized — preparing RDW lookup", plate)
        case .loading:
            AppStrings.text("Checking %@ with RDW…", plate)
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
