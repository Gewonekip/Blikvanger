import CoreGraphics
import Foundation
import ImageIO
import Vision

protocol PlateRecognizing: Sendable {
    func recognize(in image: CGImage, timestamp: TimeInterval) throws -> [OCRObservation]
}

struct VisionPlateRecognizer: PlateRecognizing {
    func recognize(in image: CGImage, timestamp: TimeInterval) throws -> [OCRObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // The crop may include a plate holder and the raised duplicate code. A
        // lower minimum keeps distant characters eligible without scanning the
        // full camera image (this request only sees the corrected plate crop).
        request.minimumTextHeight = 0.08
        request.recognitionLanguages = ["nl-NL", "en-US"]
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let fragments = (request.results ?? []).map { observation in
            PlateTextFragment(
                boundingBox: observation.boundingBox,
                candidates: observation.topCandidates(3).map {
                    PlateTextCandidate(text: $0.string, confidence: $0.confidence)
                }
            )
        }
        return PlateTextAssembler().observations(from: fragments, timestamp: timestamp)
    }
}

struct PlateTextCandidate: Equatable, Sendable {
    let text: String
    let confidence: Float
}

struct PlateTextFragment: Equatable, Sendable {
    let boundingBox: CGRect
    let candidates: [PlateTextCandidate]
}

/// Vision frequently splits a distant registration into multiple text regions
/// (for example, `12`, `BD`, `34`). The input is already a perspective-corrected
/// plate crop, so a small bounded beam can safely retain/skip regions and join
/// them left-to-right. Domain validation still decides whether any joined text
/// is a Dutch plate, and temporal consensus remains mandatory.
struct PlateTextAssembler: Sendable {
    var maximumFragments = 8
    var maximumAlternativesPerFragment = 2
    var maximumBeamWidth = 96

    func observations(
        from input: [PlateTextFragment],
        timestamp: TimeInterval
    ) -> [OCRObservation] {
        guard timestamp.isFinite else { return [] }
        let fragments = selectedFragments(from: input)
        var strongestByText: [String: OCRObservation] = [:]

        for fragment in fragments {
            for candidate in fragment.candidates.prefix(3) where Self.isUsable(candidate) {
                retain(
                    OCRObservation(
                        text: candidate.text,
                        confidence: candidate.confidence,
                        timestamp: timestamp
                    ),
                    in: &strongestByText
                )
            }
        }

        guard fragments.count >= 2 else {
            return Self.ordered(Array(strongestByText.values))
        }

        var beam = [AssemblyState.empty]
        for (fragmentIndex, fragment) in fragments.enumerated() {
            var expanded = beam // Skipping a logo, maker mark, or duplicate digit is valid.
            for state in beam {
                for candidate in fragment.candidates
                    .prefix(maximumAlternativesPerFragment)
                    where Self.isUsable(candidate) {
                    guard let next = state.appending(
                        candidate,
                        boundingBox: fragment.boundingBox,
                        fragmentIndex: fragmentIndex
                    ) else { continue }
                    if next.significantCharacterCount <= 8 {
                        expanded.append(next)
                    }
                }
            }
            beam = pruned(expanded)
        }

        for state in beam where state.fragmentCount >= 2 {
            guard DutchLicensePlate.normalizedCharacters(in: state.text) != nil
                    || DutchLicensePlate.recognizedPlate(in: state.text) != nil else { continue }
            retain(
                OCRObservation(
                    text: state.text,
                    confidence: state.confidence,
                    timestamp: timestamp
                ),
                in: &strongestByText
            )
        }
        return Self.ordered(Array(strongestByText.values))
    }

    private func selectedFragments(from input: [PlateTextFragment]) -> [PlateTextFragment] {
        let geometricallyUsable = input.filter { fragment in
            fragment.boundingBox.minX.isFinite
                && fragment.boundingBox.midX.isFinite
                && fragment.boundingBox.midY.isFinite
                && fragment.boundingBox.width > 0
                && fragment.boundingBox.height > 0
                && fragment.candidates.contains(where: Self.isUsable)
        }
        let maximumHeight = geometricallyUsable.map(\.boundingBox.height).max() ?? 0
        let usable = geometricallyUsable.filter {
            !Self.isSmallCountryMark($0, maximumGlyphHeight: maximumHeight)
        }
        let selected: [PlateTextFragment]
        if usable.count > maximumFragments {
            selected = Array(usable.sorted {
                let lhsArea = $0.boundingBox.width * $0.boundingBox.height
                let rhsArea = $1.boundingBox.width * $1.boundingBox.height
                if lhsArea != rhsArea { return lhsArea > rhsArea }
                return $0.boundingBox.midX < $1.boundingBox.midX
            }.prefix(maximumFragments))
        } else {
            selected = usable
        }
        return selected.sorted {
            if $0.boundingBox.midX != $1.boundingBox.midX {
                return $0.boundingBox.midX < $1.boundingBox.midX
            }
            if $0.boundingBox.midY != $1.boundingBox.midY {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.width > $1.boundingBox.width
        }
    }

    private static func isSmallCountryMark(
        _ fragment: PlateTextFragment,
        maximumGlyphHeight: CGFloat
    ) -> Bool {
        // A corrected Dutch plate crop may retain the narrow blue EU strip.
        // Vision often returns its small `NL` mark as a separate leftmost word;
        // allowing that stable logo into the beam can manufacture a valid-looking
        // six-character registration with two genuine groups. Preserve a real
        // full-height `NL` registration group by applying both size and position.
        guard maximumGlyphHeight > 0,
              fragment.boundingBox.maxX <= 0.16,
              fragment.boundingBox.height <= maximumGlyphHeight * 0.68 else {
            return false
        }
        return fragment.candidates.prefix(3).contains { candidate in
            candidate.text.uppercased().filter { $0.isLetter || $0.isNumber } == "NL"
        }
    }

    private func pruned(_ states: [AssemblyState]) -> [AssemblyState] {
        var strongestByPath: [AssemblyState.PathKey: AssemblyState] = [:]
        for state in states {
            if state.confidence > (strongestByPath[state.pathKey]?.confidence ?? -1) {
                strongestByPath[state.pathKey] = state
            }
        }
        return Array(strongestByPath.values).sorted { lhs, rhs in
            let lhsDistance = abs(Double(lhs.significantCharacterCount) - 6.5)
            let rhsDistance = abs(Double(rhs.significantCharacterCount) - 6.5)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return lhs.text < rhs.text
        }
        .prefix(maximumBeamWidth)
        .map { $0 }
    }

    private func retain(
        _ observation: OCRObservation,
        in dictionary: inout [String: OCRObservation]
    ) {
        if observation.confidence > (dictionary[observation.text]?.confidence ?? -1) {
            dictionary[observation.text] = observation
        }
    }

    private static func isUsable(_ candidate: PlateTextCandidate) -> Bool {
        !candidate.text.isEmpty
            && candidate.confidence.isFinite
            && (0...1).contains(candidate.confidence)
    }

    private static func ordered(_ observations: [OCRObservation]) -> [OCRObservation] {
        observations.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.text < $1.text
        }
    }

    private struct AssemblyState {
        var text: String
        var weightedConfidence: Float
        var weight: Int
        var fragmentCount: Int
        var firstBoundingBox: CGRect?
        var lastBoundingBox: CGRect?
        var firstFragmentIndex: Int?
        var lastFragmentIndex: Int?

        static let empty = AssemblyState(
            text: "",
            weightedConfidence: 0,
            weight: 0,
            fragmentCount: 0,
            firstBoundingBox: nil,
            lastBoundingBox: nil,
            firstFragmentIndex: nil,
            lastFragmentIndex: nil
        )

        struct PathKey: Hashable {
            let text: String
            let firstFragmentIndex: Int?
            let lastFragmentIndex: Int?
        }

        var pathKey: PathKey {
            PathKey(
                text: text,
                firstFragmentIndex: firstFragmentIndex,
                lastFragmentIndex: lastFragmentIndex
            )
        }

        var confidence: Float {
            weight > 0 ? weightedConfidence / Float(weight) : 0
        }

        var significantCharacterCount: Int {
            text.unicodeScalars.count { scalar in
                switch scalar.value {
                case 48...57, 65...90, 97...122,
                     0x2070, 0x00B9, 0x00B2, 0x00B3, 0x2074...0x2079:
                    true
                default:
                    false
                }
            }
        }

        func appending(
            _ candidate: PlateTextCandidate,
            boundingBox: CGRect,
            fragmentIndex: Int
        ) -> AssemblyState? {
            if let lastBoundingBox {
                // Vision can return a whole word and one of its subranges as
                // separate observations. Never concatenate nested regions;
                // allow only the slight box overlap produced by glyph edges.
                guard boundingBox.midX > lastBoundingBox.midX else { return nil }
                let overlap = min(lastBoundingBox.maxX, boundingBox.maxX)
                    - max(lastBoundingBox.minX, boundingBox.minX)
                if overlap > 0 {
                    let smallerWidth = min(lastBoundingBox.width, boundingBox.width)
                    guard overlap / smallerWidth <= 0.15 else { return nil }
                }
                // A tall first observation can overlap two otherwise unrelated
                // rows. Requiring adjacent fragments to share the same aligned
                // glyph band closes that bridge. A separate raised duplicate
                // marker can be skipped; if Vision attaches it to a group, the
                // domain parser removes it at the validated sidecode boundary.
                guard Self.sharesVerticalGlyphBand(lastBoundingBox, boundingBox) else {
                    return nil
                }
            }

            if let firstBoundingBox {
                // A plate line has a common vertical glyph band. Comparing
                // every fragment with the first retained fragment prevents a
                // chain of partially overlapping boxes from drifting into a
                // second line or plate-holder text.
                guard Self.sharesVerticalGlyphBand(firstBoundingBox, boundingBox) else {
                    return nil
                }
            }

            let candidateWeight = max(1, candidate.text.unicodeScalars.count { scalar in
                switch scalar.value {
                case 48...57, 65...90, 97...122,
                     0x2070, 0x00B9, 0x00B2, 0x00B3, 0x2074...0x2079:
                    true
                default:
                    false
                }
            })
            return AssemblyState(
                text: text + candidate.text,
                weightedConfidence: weightedConfidence + candidate.confidence * Float(candidateWeight),
                weight: weight + candidateWeight,
                fragmentCount: fragmentCount + 1,
                firstBoundingBox: firstBoundingBox ?? boundingBox,
                lastBoundingBox: boundingBox,
                firstFragmentIndex: firstFragmentIndex ?? fragmentIndex,
                lastFragmentIndex: fragmentIndex
            )
        }

        private static func sharesVerticalGlyphBand(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
            let smallerHeight = min(lhs.height, rhs.height)
            return overlap > 0
                && smallerHeight > 0
                && overlap / smallerHeight >= 0.35
                && abs(lhs.midY - rhs.midY) <= smallerHeight * 0.8
        }
    }
}

struct PlateConsensus: Sendable {
    var minimumFrames = 3
    var minimumConfidence: Float = 0.62
    var minimumAmbiguousConfidence: Float = 0.74
    var minimumMargin: Float = 0.18
    var minimumAmbiguousMargin: Float = 0.28
    var minimumObservationConfidence: Float = 0.20
    var minimumWholePlateFrames = 2
    var minimumWholePlateConfidence: Float = 0.60
    var minimumModerateWholePlateFrames = 3
    var minimumModerateWholePlateConfidence: Float = 0.35
    var minimumModerateMeanConfidence: Float = 0.42

    func confirmedPlate(from observations: [OCRObservation]) -> DutchLicensePlate? {
        let usable = observations.compactMap { observation -> TimedCandidate? in
            guard observation.timestamp.isFinite,
                  observation.confidence.isFinite,
                  observation.confidence >= minimumObservationConfidence,
                  observation.confidence <= 1,
                  let canonical = DutchLicensePlate.normalizedCharacters(in: observation.text)
                    ?? DutchLicensePlate.recognizedPlate(in: observation.text)?.canonical else {
                return nil
            }
            return TimedCandidate(
                characters: Array(canonical),
                confidence: observation.confidence,
                timestamp: observation.timestamp
            )
        }

        let grouped = Dictionary(grouping: usable, by: { $0.timestamp.bitPattern })
        let frames = grouped.keys.sorted().compactMap { key in
            grouped[key].map(FrameEvidence.init)
        }
        guard frames.count >= minimumFrames else { return nil }

        var result = ""
        for position in 0..<6 {
            var totalWeights: [Character: Float] = [:]
            var frameWins: [Character: Int] = [:]

            for frame in frames {
                var frameWeights: [Character: Float] = [:]
                for candidate in frame.candidates {
                    let character = candidate.characters[position]
                    frameWeights[character] = max(frameWeights[character, default: 0], candidate.confidence)
                }

                let rankedFrame = Self.ranked(frameWeights)
                guard let frameWinner = rankedFrame.first else { continue }
                if rankedFrame.count == 1 || frameWinner.value > rankedFrame[1].value {
                    frameWins[frameWinner.key, default: 0] += 1
                }

                let sum = frameWeights.values.reduce(0, +)
                let scale = frameWeights.values.max() ?? 0
                guard sum > 0 else { continue }
                for (character, weight) in frameWeights {
                    // One Vision frame contributes at most its strongest candidate confidence,
                    // even though topCandidates can return several alternatives for that frame.
                    totalWeights[character, default: 0] += (weight / sum) * scale
                }
            }

            let ranked = Self.ranked(totalWeights)
            guard let winner = ranked.first,
                  frameWins[winner.key, default: 0] >= minimumFrames else {
                return nil
            }

            let total = totalWeights.values.reduce(0, +)
            let winnerShare = winner.value / max(total, 0.001)
            let runnerUp = ranked.dropFirst().first
            let runnerUpShare = (runnerUp?.value ?? 0) / max(total, 0.001)
            let isAmbiguousPair = runnerUp.map {
                Self.areVisuallyAmbiguous(winner.key, $0.key)
            } ?? false
            let requiredConfidence = isAmbiguousPair ? minimumAmbiguousConfidence : minimumConfidence
            let requiredMargin = isAmbiguousPair ? minimumAmbiguousMargin : minimumMargin
            guard winnerShare >= requiredConfidence,
                  winnerShare - runnerUpShare >= requiredMargin else {
                return nil
            }

            result.append(winner.key)
        }

        guard let plate = DutchLicensePlate(result) else { return nil }
        let exactWholePlateConfidences = frames.compactMap { frame -> Float? in
            guard let best = frame.bestCandidate,
                  String(best.characters) == plate.canonical else {
                return nil
            }
            return best.confidence
        }
        let strongFrameCount = exactWholePlateConfidences.count {
            $0 >= minimumWholePlateConfidence
        }
        let moderateFrames = exactWholePlateConfidences.filter {
            $0 >= minimumModerateWholePlateConfidence
        }
        let moderateMean = moderateFrames.reduce(0, +) / Float(max(moderateFrames.count, 1))
        guard strongFrameCount >= minimumWholePlateFrames
                || (moderateFrames.count >= minimumModerateWholePlateFrames
                    && moderateMean >= minimumModerateMeanConfidence) else { return nil }
        return plate
    }

    private static func ranked(_ weights: [Character: Float]) -> [(key: Character, value: Float)] {
        weights.sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return String(lhs.key) < String(rhs.key)
            }
            return lhs.value > rhs.value
        }
    }

    private static func areVisuallyAmbiguous(_ lhs: Character, _ rhs: Character) -> Bool {
        ambiguityGroups.contains { $0.contains(lhs) && $0.contains(rhs) }
    }

    private struct TimedCandidate: Sendable {
        let characters: [Character]
        let confidence: Float
        let timestamp: TimeInterval
    }

    private struct FrameEvidence: Sendable {
        let candidates: [TimedCandidate]

        init(_ candidates: [TimedCandidate]) {
            var strongestByText: [String: TimedCandidate] = [:]
            for candidate in candidates {
                let text = String(candidate.characters)
                if candidate.confidence > (strongestByText[text]?.confidence ?? -1) {
                    strongestByText[text] = candidate
                }
            }
            self.candidates = strongestByText.values.sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence {
                    return String(lhs.characters) < String(rhs.characters)
                }
                return lhs.confidence > rhs.confidence
            }
        }

        var bestCandidate: TimedCandidate? { candidates.first }
    }

    private static let ambiguityGroups: [Set<Character>] = [
        ["0", "O"], ["1", "I"], ["2", "Z"], ["5", "S"],
        ["6", "G"], ["8", "B"]
    ]
}
