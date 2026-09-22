import XCTest
@testable import Blikvanger

final class DutchLicensePlateTests: XCTestCase {
    func testRecognizesAndFormatsAllPublishedSidecodeLayouts() throws {
        let fixtures: [(raw: String, sidecode: Int, formatted: String)] = [
            ("ND0001", 1, "ND-00-01"),
            ("0001AD", 2, "00-01-AD"),
            ("00AD01", 3, "00-AD-01"),
            ("MP66KY", 4, "MP-66-KY"),
            ("BDFG12", 5, "BD-FG-12"),
            ("12BDFG", 6, "12-BD-FG"),
            ("12BDF3", 7, "12-BDF-3"),
            ("1BDF23", 8, "1-BDF-23"),
            ("BD123F", 9, "BD-123-F"),
            ("B123DF", 10, "B-123-DF"),
            ("BDF12G", 11, "BDF-12-G"),
            ("V12BDF", 12, "V-12-BDF"),
            ("1GV234", 13, "1-GV-234"),
            ("123GV4", 14, "123-GV-4")
        ]

        for fixture in fixtures {
            let plate = try XCTUnwrap(DutchLicensePlate(fixture.raw), fixture.raw)
            XCTAssertEqual(plate.sidecode, fixture.sidecode, fixture.raw)
            XCTAssertEqual(plate.formatted, fixture.formatted, fixture.raw)
            XCTAssertEqual(plate.canonical, fixture.raw, fixture.raw)
        }
    }

    func testNormalizesOnlyPlatePresentationSeparators() {
        XCTAssertEqual(DutchLicensePlate(" 12 – bd – 34\n")?.canonical, "12BD34")
        XCTAssertEqual(DutchLicensePlate.recognizedPlate(in: "7-TDH-82")?.canonical, "7TDH82")
        XCTAssertNil(DutchLicensePlate("12/BD/34"))
        XCTAssertNil(DutchLicensePlate("12.BD.34"))
        XCTAssertNil(DutchLicensePlate("１２-BD-３４"))
        XCTAssertNil(DutchLicensePlate("ﬀ-12-34"))
    }

    func testHistoricVowelsModernYAndInferableCategoryPrefixes() {
        XCTAssertEqual(DutchLicensePlate("AE-12-34")?.sidecode, 1)
        XCTAssertEqual(DutchLicensePlate("12-34-EU")?.sidecode, 2)
        XCTAssertEqual(DutchLicensePlate("12-AU-34")?.sidecode, 3)

        // Y is used as a consonant in issued modern registrations.
        XCTAssertEqual(DutchLicensePlate("MP-66-KY")?.sidecode, 4)

        // O identifies an oplegger in sidecode 4; E identifies the sidecode 12
        // special-moped series in RDW's current category table.
        XCTAssertEqual(DutchLicensePlate("OK-49-SX")?.sidecode, 4)
        XCTAssertEqual(DutchLicensePlate("E-12-BDF")?.sidecode, 12)
    }

    func testRejectsModernVowelsOutsideAnInferableCategoryPrefixAndAlwaysRejectsCOrQ() {
        let invalid = [
            "BA-12-BD", "BD-12-AF", "A-123-BD", "B-123-AD",
            "OA-49-SX", "OK-49-OX", "V-12-BAF",
            "CQ-12-34", "12-CQ-34", "12-CQRS"
        ]
        for raw in invalid {
            XCTAssertNil(DutchLicensePlate(raw), raw)
        }
    }

    func testRejectsOfficialForbiddenGroupsWithinPrintedLetterGroups() {
        let forbiddenThreeLetterGroups = [
            "GVD", "KKK", "NSB", "PKK", "PSV", "TBS",
            "PVV", "SGP", "VVD", "FVD", "BBB"
        ]
        for group in forbiddenThreeLetterGroups {
            XCTAssertNil(DutchLicensePlate("12-\(group)-3"), group)
        }

        for raw in ["SS-12-BD", "BD-12-SD", "12-SSB-3", "12-BSD-3", "12-BSA-3"] {
            XCTAssertNil(DutchLicensePlate(raw), raw)
        }

        // The KKK characters cross the printed GK-KK group boundary and are legal.
        XCTAssertEqual(DutchLicensePlate("89-GK-KK")?.formatted, "89-GK-KK")
    }

    func testRestrictsSidecodesThirteenAndFourteenToThePublishedGVSeries() {
        XCTAssertEqual(DutchLicensePlate("1-GV-234")?.sidecode, 13)
        XCTAssertEqual(DutchLicensePlate("123-GV-4")?.sidecode, 14)
        XCTAssertNil(DutchLicensePlate("1-BD-234"))
        XCTAssertNil(DutchLicensePlate("123-BD-4"))
    }

    func testRejectsInvalidPatternAndLength() {
        XCTAssertNil(DutchLicensePlate("ABCDEF"))
        XCTAssertNil(DutchLicensePlate("12-BD-345"))
        XCTAssertNil(DutchLicensePlate("--"))
    }

    func testOCRRecognitionRemovesOnlyDuplicateCodeAtFirstGroupBoundary() {
        let variants = [
            "121-BD-34",
            "12-1BD-34",
            "12¹-BD-34",
            "120-BD-34"
        ]

        for raw in variants {
            XCTAssertNil(DutchLicensePlate(raw), "The strict domain initializer must stay strict: \(raw)")
            XCTAssertEqual(DutchLicensePlate.recognizedPlate(in: raw)?.canonical, "12BD34", raw)
        }

        XCTAssertEqual(DutchLicensePlate.recognizedPlate(in: "B2-123-DF")?.canonical, "B123DF")
        XCTAssertEqual(DutchLicensePlate.recognizedPlate(in: "BDF9-12-G")?.canonical, "BDF12G")
    }

    func testOCRRecognitionDoesNotDropUnrelatedOrAmbiguousExtraCharacters() {
        for raw in ["12-BD-341", "12-BD-134", "12X-BD-34", "1", "¹"] {
            XCTAssertNil(DutchLicensePlate.recognizedPlate(in: raw), raw)
        }
        XCTAssertEqual(DutchLicensePlate.recognizedPlate(in: "12-BD-34")?.canonical, "12BD34")
    }
}
