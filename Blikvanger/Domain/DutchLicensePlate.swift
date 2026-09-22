import Foundation

struct DutchLicensePlate: Hashable, Sendable, CustomStringConvertible {
    let canonical: String
    let sidecode: Int

    init?(_ raw: String) {
        guard let normalized = Self.normalizedCharacters(in: raw),
              let pattern = Self.patterns.first(where: { $0.matches(normalized) }),
              Self.hasPermittedLetters(normalized, pattern: pattern),
              Self.hasPermittedLetterGroups(normalized, pattern: pattern) else {
            return nil
        }

        canonical = normalized
        sidecode = pattern.sidecode
    }

    var formatted: String {
        guard let pattern = Self.patterns.first(where: { $0.sidecode == sidecode }) else {
            return canonical
        }
        return pattern.groups(in: canonical).joined(separator: "-")
    }

    var description: String { formatted }

    /// Normalizes presentation separators without changing ambiguous glyphs such as O/0 or I/1.
    static func normalizedCharacters(in raw: String) -> String? {
        var result = ""
        result.reserveCapacity(6)

        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 48...57, 65...90:
                result.unicodeScalars.append(scalar)
            case 97...122:
                guard let uppercase = UnicodeScalar(scalar.value - 32) else { return nil }
                result.unicodeScalars.append(uppercase)
            case 9...13, 32, 45, 0x2010...0x2014:
                continue
            default:
                return nil
            }
        }

        return result.utf8.count == 6 ? result : nil
    }

    /// Extracts plate candidates from OCR without relaxing the strict domain
    /// initializer. Replacement Dutch plates print a separate duplicate code at
    /// the first group boundary. Vision can flatten that small digit into the
    /// six registration characters, so remove exactly one digit only when the
    /// resulting, fully validated sidecode places it at that boundary.
    static func recognitionCandidates(in raw: String) -> [DutchLicensePlate] {
        if let plate = DutchLicensePlate(raw) {
            return [plate]
        }

        guard let tokenization = recognitionTokens(in: raw),
              tokenization.tokens.count == 7 else { return [] }
        let tokens = tokenization.tokens
        var candidates = Set<DutchLicensePlate>()
        for (index, token) in tokens.enumerated() where token.canBeDuplicateCode {
            var characters = tokens.map(\.character)
            characters.remove(at: index)
            guard let plate = DutchLicensePlate(String(characters)),
                  let pattern = patterns.first(where: { $0.sidecode == plate.sidecode }),
                  pattern.groupLengths.first == index,
                  separatorsAreConsistent(
                    tokenization.separatorBoundaries,
                    afterRemovingTokenAt: index,
                    pattern: pattern
                  ) else { continue }
            candidates.insert(plate)
        }
        return candidates.sorted { $0.canonical < $1.canonical }
    }

    static func recognizedPlate(in raw: String) -> DutchLicensePlate? {
        let candidates = recognitionCandidates(in: raw)
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func recognitionTokens(in raw: String) -> RecognitionTokenization? {
        var result: [RecognitionToken] = []
        var separatorBoundaries = Set<Int>()
        result.reserveCapacity(7)

        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 48...57:
                result.append(RecognitionToken(
                    character: Character(String(scalar)),
                    canBeDuplicateCode: true
                ))
            case 65...90:
                result.append(RecognitionToken(
                    character: Character(String(scalar)),
                    canBeDuplicateCode: false
                ))
            case 97...122:
                guard let uppercase = UnicodeScalar(scalar.value - 32) else { return nil }
                result.append(RecognitionToken(
                    character: Character(String(uppercase)),
                    canBeDuplicateCode: false
                ))
            case 45, 0x2010...0x2014:
                separatorBoundaries.insert(result.count)
            case 9...13, 32:
                continue
            default:
                guard let digit = superscriptDigit(for: scalar) else { return nil }
                result.append(RecognitionToken(character: digit, canBeDuplicateCode: true))
            }
        }
        return RecognitionTokenization(
            tokens: result,
            separatorBoundaries: separatorBoundaries
        )
    }

    private static func separatorsAreConsistent(
        _ rawBoundaries: Set<Int>,
        afterRemovingTokenAt removedIndex: Int,
        pattern: Pattern
    ) -> Bool {
        guard !rawBoundaries.isEmpty else { return true }
        var running = 0
        let expected = Set(pattern.groupLengths.dropLast().map { length -> Int in
            running += length
            return running
        })
        let adjusted = rawBoundaries.compactMap { boundary -> Int? in
            let value = boundary > removedIndex ? boundary - 1 : boundary
            return (1..<6).contains(value) ? value : nil
        }
        return !adjusted.isEmpty && adjusted.allSatisfy(expected.contains)
    }

    private static func superscriptDigit(for scalar: UnicodeScalar) -> Character? {
        switch scalar.value {
        case 0x2070: "0"
        case 0x00B9: "1"
        case 0x00B2: "2"
        case 0x00B3: "3"
        case 0x2074...0x2079:
            Character(String(scalar.value - 0x2074 + 4))
        default: nil
        }
    }

    private struct RecognitionToken {
        let character: Character
        let canBeDuplicateCode: Bool
    }

    private struct RecognitionTokenization {
        let tokens: [RecognitionToken]
        let separatorBoundaries: Set<Int>
    }

    private static func hasPermittedLetters(_ canonical: String, pattern: Pattern) -> Bool {
        let characters = Array(canonical)
        let firstLetterIndex = pattern.layout.firstIndex(of: "L")

        for (index, character) in characters.enumerated() where pattern.layout[index] == "L" {
            // RDW does not use C or Q. Historic standard sidecodes can contain vowels.
            guard character != "C", character != "Q" else { return false }
            guard pattern.sidecode >= 4 else { continue }

            if "AEIOU".contains(character) {
                let isSemiTrailerPrefix = pattern.sidecode == 4
                    && index == firstLetterIndex
                    && character == "O"
                let isSpecialMopedPrefix = pattern.sidecode == 12
                    && index == firstLetterIndex
                    && character == "E"
                guard isSemiTrailerPrefix || isSpecialMopedPrefix else { return false }
            }
        }

        // Sidecodes 13 and 14 are the current GV border-traffic series.
        if pattern.sidecode == 13 || pattern.sidecode == 14 {
            return pattern.letterGroups(in: canonical) == ["GV"]
        }
        return true
    }

    private static func hasPermittedLetterGroups(_ canonical: String, pattern: Pattern) -> Bool {
        pattern.letterGroups(in: canonical).allSatisfy { group in
            !forbiddenExactGroups.contains(group)
                && forbiddenSubgroups.allSatisfy { !group.contains($0) }
        }
    }

    private static let forbiddenExactGroups: Set<String> = [
        "GVD", "KKK", "NSB", "PKK", "PSV", "TBS",
        "PVV", "SGP", "VVD", "FVD", "BBB"
    ]

    // RDW explicitly excludes SS and SD inside three-letter groups too. Its history
    // also records SA as withheld, so reject each sequence within a printed group.
    private static let forbiddenSubgroups = ["SS", "SD", "SA"]

    private struct Pattern: Sendable {
        let sidecode: Int
        let layout: [Character]
        let groupLengths: [Int]

        init(_ sidecode: Int, _ layout: String, _ groupLengths: [Int]) {
            self.sidecode = sidecode
            self.layout = Array(layout)
            self.groupLengths = groupLengths
        }

        func matches(_ canonical: String) -> Bool {
            let characters = Array(canonical)
            guard characters.count == layout.count else { return false }

            return zip(characters, layout).allSatisfy { character, kind in
                switch kind {
                case "L": character.isASCII && character.isLetter
                case "D": character.isASCII && character.isNumber
                default: false
                }
            }
        }

        func groups(in canonical: String) -> [String] {
            let characters = Array(canonical)
            var start = 0
            return groupLengths.map { length in
                defer { start += length }
                return String(characters[start..<(start + length)])
            }
        }

        func letterGroups(in canonical: String) -> [String] {
            zip(groups(in: canonical), groupedLayout).compactMap { group, kinds in
                kinds.allSatisfy { $0 == "L" } ? group : nil
            }
        }

        private var groupedLayout: [[Character]] {
            var start = 0
            return groupLengths.map { length in
                defer { start += length }
                return Array(layout[start..<(start + length)])
            }
        }
    }

    private static let patterns: [Pattern] = [
        Pattern(1, "LLDDDD", [2, 2, 2]),
        Pattern(2, "DDDDLL", [2, 2, 2]),
        Pattern(3, "DDLLDD", [2, 2, 2]),
        Pattern(4, "LLDDLL", [2, 2, 2]),
        Pattern(5, "LLLLDD", [2, 2, 2]),
        Pattern(6, "DDLLLL", [2, 2, 2]),
        Pattern(7, "DDLLLD", [2, 3, 1]),
        Pattern(8, "DLLLDD", [1, 3, 2]),
        Pattern(9, "LLDDDL", [2, 3, 1]),
        Pattern(10, "LDDDLL", [1, 3, 2]),
        Pattern(11, "LLLDDL", [3, 2, 1]),
        Pattern(12, "LDDLLL", [1, 2, 3]),
        Pattern(13, "DLLDDD", [1, 2, 3]),
        Pattern(14, "DDDLLD", [3, 2, 1])
    ]
}
