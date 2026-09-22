import CoreGraphics
import Foundation

struct PlateTracker: Sendable {
    private(set) var candidates: [PlateCandidate] = []
    private(set) var expiredCandidateIDs: Set<UUID> = []
    private(set) var evictedCandidateIDs: Set<UUID> = []
    var expiryInterval: TimeInterval = 0.9
    var minimumIntersectionOverUnion: CGFloat = 0.06
    var maximumConsecutiveGap: TimeInterval = 0.80
    var maximumCandidates = 48
    var maximumQuadrilateralHistory = 12
    var maximumPoseSamples = 10

    var removedCandidateIDs: Set<UUID> {
        expiredCandidateIDs.union(evictedCandidateIDs)
    }

    mutating func ingest(_ detections: [PlateDetection], timestamp: TimeInterval) -> [PlateCandidate] {
        guard timestamp.isFinite else {
            expiredCandidateIDs.removeAll(keepingCapacity: true)
            evictedCandidateIDs.removeAll(keepingCapacity: true)
            return candidates
        }
        let expiryInterval = max(0, self.expiryInterval)
        expiredCandidateIDs = Set(candidates.lazy
            .filter { timestamp - $0.lastSeen > expiryInterval }
            .map(\.id))
        evictedCandidateIDs.removeAll(keepingCapacity: true)
        candidates.removeAll { expiredCandidateIDs.contains($0.id) }

        let validDetections = detections.filter(\.isValid)
        let matches = candidateDetectionMatches(for: validDetections)
        var matchedCandidateIndices = Set<Int>()
        var matchedDetectionIndices = Set<Int>()

        for match in matches {
            guard !matchedCandidateIndices.contains(match.candidateIndex),
                  !matchedDetectionIndices.contains(match.detectionIndex) else { continue }
            updateCandidate(at: match.candidateIndex, with: validDetections[match.detectionIndex], timestamp: timestamp)
            matchedCandidateIndices.insert(match.candidateIndex)
            matchedDetectionIndices.insert(match.detectionIndex)
        }

        for index in candidates.indices where !matchedCandidateIndices.contains(index) {
            guard timestamp - candidates[index].lastSeen > 0.000_001 else { continue }
            candidates[index].missedObservationCount += 1
            guard candidates[index].missedObservationCount >= 3 else { continue }
            candidates[index].consecutiveObservationCount = 0
            switch candidates[index].state {
            case .anchored, .reading, .confirming, .rejected:
                break
            case .detected, .tracking, .spatiallyEstimating, .spatiallyStable, .lost:
                candidates[index].poseSamples.removeAll(keepingCapacity: true)
                candidates[index].state = .detected
            }
        }

        let unmatchedDetections = validDetections.enumerated()
            .filter { !matchedDetectionIndices.contains($0.offset) }
            .map(\.element)
            .sorted(by: detectionOrder)
        for detection in unmatchedDetections {
            candidates.append(PlateCandidate(
                id: UUID(),
                state: .detected,
                quadrilateralHistory: [detection.quadrilateral],
                poseSamples: [],
                firstSeen: timestamp,
                lastSeen: timestamp,
                observationCount: 1,
                consecutiveObservationCount: 1,
                missedObservationCount: 0
            ))
        }

        evictCandidatesOverLimit()
        return candidates
    }

    mutating func addPose(_ sample: PoseSample, to id: UUID) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        guard sample.timestamp.isFinite,
              sample.confidence.isFinite,
              !candidates[index].poseSamples.contains(where: { abs($0.timestamp - sample.timestamp) < 0.000_001 }) else { return }
        candidates[index].poseSamples.append(sample)
        candidates[index].poseSamples = Array(candidates[index].poseSamples.suffix(max(1, maximumPoseSamples)))
        if PoseFusion().stableTransform(from: candidates[index].poseSamples) != nil {
            switch candidates[index].state {
            case .reading, .confirming, .anchored:
                break
            default:
                candidates[index].state = .spatiallyStable
            }
        }
    }

    mutating func markState(_ state: TrackLifecycle, for id: UUID) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].state = state
    }

    func candidate(id: UUID) -> PlateCandidate? {
        candidates.first { $0.id == id }
    }

    mutating func reset() {
        candidates.removeAll()
        expiredCandidateIDs.removeAll()
        evictedCandidateIDs.removeAll()
    }

    private mutating func updateCandidate(at index: Int, with detection: PlateDetection, timestamp: TimeInterval) {
        let representsNewFrame = timestamp - candidates[index].lastSeen > 0.000_001
        if representsNewFrame {
            if timestamp - candidates[index].lastSeen > maximumConsecutiveGap {
                candidates[index].consecutiveObservationCount = 0
                if candidates[index].state != .anchored {
                    candidates[index].poseSamples.removeAll(keepingCapacity: true)
                }
            }
            candidates[index].quadrilateralHistory.append(detection.quadrilateral)
            candidates[index].observationCount += 1
            candidates[index].consecutiveObservationCount += 1
            candidates[index].missedObservationCount = 0
        } else if !candidates[index].quadrilateralHistory.isEmpty {
            candidates[index].quadrilateralHistory[candidates[index].quadrilateralHistory.count - 1] = detection.quadrilateral
        }
        candidates[index].quadrilateralHistory = Array(candidates[index].quadrilateralHistory.suffix(max(1, maximumQuadrilateralHistory)))
        candidates[index].lastSeen = max(candidates[index].lastSeen, timestamp)

        switch candidates[index].state {
        case .spatiallyStable, .reading, .confirming, .anchored, .rejected:
            break
        case .lost:
            candidates[index].state = .detected
        case .detected, .tracking, .spatiallyEstimating:
            if candidates[index].consecutiveObservationCount >= 3 {
                candidates[index].state = .spatiallyEstimating
            } else if candidates[index].consecutiveObservationCount >= 2 {
                candidates[index].state = .tracking
            } else {
                candidates[index].state = .detected
            }
        }
    }

    private func candidateDetectionMatches(for detections: [PlateDetection]) -> [CandidateDetectionMatch] {
        var matches: [CandidateDetectionMatch] = []
        for (candidateIndex, candidate) in candidates.enumerated() {
            guard candidate.state != .rejected, candidate.state != .lost else { continue }
            guard let quadrilateral = candidate.latestQuadrilateral else { continue }
            let candidateBox = boundingBox(quadrilateral)
            for (detectionIndex, detection) in detections.enumerated() {
                let overlap = intersectionOverUnion(candidateBox, detection.boundingBox)
                let candidateArea = candidateBox.width * candidateBox.height
                let detectionArea = detection.boundingBox.width * detection.boundingBox.height
                guard candidateArea > 0, detectionArea > 0 else { continue }
                let referenceSize = max(sqrt(candidateArea), sqrt(detectionArea), 0.01)
                let centerDistance = hypot(
                    candidateBox.midX - detection.boundingBox.midX,
                    candidateBox.midY - detection.boundingBox.midY
                ) / referenceSize
                let scaleChange = abs(log(candidateArea / detectionArea))
                let candidateAspect = candidateBox.width / candidateBox.height
                let detectionAspect = detection.boundingBox.width / detection.boundingBox.height
                let aspectChange = abs(log(candidateAspect / detectionAspect))
                let similarMotion = centerDistance <= 0.75
                    && scaleChange <= 0.75
                    && aspectChange <= 0.45
                guard overlap >= minimumIntersectionOverUnion || similarMotion else { continue }
                let quality = overlap
                    + max(0, 1 - centerDistance) * 0.25
                    - scaleChange * 0.06
                    - aspectChange * 0.06
                matches.append(CandidateDetectionMatch(
                    candidateIndex: candidateIndex,
                    detectionIndex: detectionIndex,
                    quality: quality
                ))
            }
        }
        return matches.sorted {
            if $0.quality != $1.quality {
                return $0.quality > $1.quality
            }
            if $0.candidateIndex != $1.candidateIndex {
                return $0.candidateIndex < $1.candidateIndex
            }
            return $0.detectionIndex < $1.detectionIndex
        }
    }

    private mutating func evictCandidatesOverLimit() {
        let limit = max(0, maximumCandidates)
        guard candidates.count > limit else { return }
        let survivorIDs = Set(candidates.sorted(by: candidateRetentionOrder).prefix(limit).map(\.id))
        evictedCandidateIDs = Set(candidates.lazy.filter { !survivorIDs.contains($0.id) }.map(\.id))
        candidates.removeAll { evictedCandidateIDs.contains($0.id) }
    }

    private func candidateRetentionOrder(_ lhs: PlateCandidate, _ rhs: PlateCandidate) -> Bool {
        // Repeated evidence is more valuable than a brand-new incidental
        // rectangle. Prioritizing recency first lets a busy vehicle scene evict
        // the real plate track whenever it is missed for one detector pass.
        if lhs.observationCount != rhs.observationCount { return lhs.observationCount > rhs.observationCount }
        if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
        if lhs.firstSeen != rhs.firstSeen { return lhs.firstSeen > rhs.firstSeen }
        let lhsX = lhs.latestQuadrilateral.map { boundingBox($0).midX } ?? 0
        let rhsX = rhs.latestQuadrilateral.map { boundingBox($0).midX } ?? 0
        if lhsX != rhsX { return lhsX < rhsX }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func detectionOrder(_ lhs: PlateDetection, _ rhs: PlateDetection) -> Bool {
        if lhs.boundingBox.minX != rhs.boundingBox.minX { return lhs.boundingBox.minX < rhs.boundingBox.minX }
        if lhs.boundingBox.minY != rhs.boundingBox.minY { return lhs.boundingBox.minY < rhs.boundingBox.minY }
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        return lhs.timestamp < rhs.timestamp
    }

    private func boundingBox(_ quad: PlateQuadrilateral) -> CGRect {
        PlateDetection(quadrilateral: quad, confidence: 1, timestamp: 0).boundingBox
    }

    private func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        guard unionArea.isFinite, unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
}

private struct CandidateDetectionMatch {
    let candidateIndex: Int
    let detectionIndex: Int
    let quality: CGFloat
}
