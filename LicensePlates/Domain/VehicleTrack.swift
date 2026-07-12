import Foundation
import simd

enum TrackLifecycle: String, Sendable {
    case detected
    case tracking
    case spatiallyEstimating
    case spatiallyStable
    case reading
    case confirming
    case anchored
    case rejected
    case lost
}

enum VehicleCardState: Equatable, Sendable {
    case generic
    case candidate
    case confirming
    case loading
    case confirmed
    case uncertain
    case unavailable
}

enum RDWEnrichmentStatus: Equatable, Sendable {
    case notRequested
    case loading
    case found
    case empty
    case unavailable
    case malformed
}

struct PlateQuadrilateral: Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
}

struct OCRObservation: Equatable, Sendable {
    var text: String
    var confidence: Float
    var timestamp: TimeInterval
}

struct PoseSample: Sendable {
    var worldTransform: simd_float4x4
    var confidence: Float
    var timestamp: TimeInterval
}

struct VehicleSummary: Equatable, Sendable {
    var plate: String
    var make: String?
    var model: String?
    var vehicleType: String?
    var primaryColor: String?
    var secondaryColor: String?
    var firstRegistrationDate: Date?
    var catalogPrice: Int?
    var cylinderCount: Int?
    var displacementCC: Int?
    var emptyMassKG: Int?
    var runningMassKG: Int?
    var maximumMassKG: Int?

    var color: String? {
        let colors = [primaryColor, secondaryColor]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return colors.isEmpty ? nil : colors.joined(separator: " / ")
    }

    var registrationYear: Int? {
        guard let firstRegistrationDate else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.component(.year, from: firstRegistrationDate)
    }

    init(
        plate: String,
        make: String? = nil,
        model: String? = nil,
        vehicleType: String? = nil,
        primaryColor: String? = nil,
        secondaryColor: String? = nil,
        firstRegistrationDate: Date? = nil,
        catalogPrice: Int? = nil,
        cylinderCount: Int? = nil,
        displacementCC: Int? = nil,
        emptyMassKG: Int? = nil,
        runningMassKG: Int? = nil,
        maximumMassKG: Int? = nil
    ) {
        self.plate = plate
        self.make = make
        self.model = model
        self.vehicleType = vehicleType
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.firstRegistrationDate = firstRegistrationDate
        self.catalogPrice = catalogPrice
        self.cylinderCount = cylinderCount
        self.displacementCC = displacementCC
        self.emptyMassKG = emptyMassKG
        self.runningMassKG = runningMassKG
        self.maximumMassKG = maximumMassKG
    }
}

struct VehicleTrack: Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var lifecycle: TrackLifecycle
    var quadrilateralHistory: [PlateQuadrilateral]
    var ocrEvidence: [OCRObservation]
    var poseSamples: [PoseSample]
    var stableTransform: simd_float4x4
    var anchorIdentifier: UUID
    var createdAt: Date
    var lastSeenAt: Date
    var cardState: VehicleCardState
    var rdwLookupPlateCanonical: String?
    var rdwEnrichmentStatus: RDWEnrichmentStatus
    var rdwRetryAfter: Date?
    var vehicle: VehicleSummary?

    init(
        id: UUID = UUID(),
        displayName: String,
        transform: simd_float4x4,
        anchorIdentifier: UUID = UUID(),
        now: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.lifecycle = .anchored
        self.quadrilateralHistory = []
        self.ocrEvidence = []
        self.poseSamples = []
        self.stableTransform = transform
        self.anchorIdentifier = anchorIdentifier
        self.createdAt = now
        self.lastSeenAt = now
        self.cardState = .generic
        self.rdwLookupPlateCanonical = nil
        self.rdwEnrichmentStatus = .notRequested
        self.rdwRetryAfter = nil
        self.vehicle = nil
    }
}
