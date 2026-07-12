import XCTest
@testable import LicensePlates

final class CardLayoutEngineTests: XCTestCase {
    func testClampsToSafeFrameAndResolvesOverlapWithoutChangingIdentity() {
        let first = UUID()
        let second = UUID()
        let items = [
            CardLayoutItem(id: first, desiredPoint: CGPoint(x: 2, y: 2), size: CGSize(width: 100, height: 50), depth: 1),
            CardLayoutItem(id: second, desiredPoint: CGPoint(x: 2, y: 2), size: CGSize(width: 100, height: 50), depth: 2)
        ]
        let results = CardLayoutEngine().layout(items: items, safeFrame: CGRect(x: 10, y: 20, width: 300, height: 500))

        XCTAssertEqual(results.map(\.id), [first, second])
        XCTAssertGreaterThanOrEqual(results[0].cardPoint.x, 60)
        XCTAssertGreaterThanOrEqual(results[0].cardPoint.y, 45)
        XCTAssertNotEqual(results[0].cardPoint, results[1].cardPoint)
        XCTAssertTrue(results[0].needsLeaderLine)
    }

    func testMultipleCardsAvoidEachOtherAndAReservedControlArea() {
        let itemSize = CGSize(width: 100, height: 50)
        let items = (0..<6).map {
            CardLayoutItem(
                id: UUID(),
                desiredPoint: CGPoint(x: 160, y: 200),
                size: itemSize,
                depth: Float($0 + 1)
            )
        }
        let exclusion = CGRect(x: 100, y: 160, width: 120, height: 80)

        let results = CardLayoutEngine(spacing: 10).layout(
            items: items,
            safeFrame: CGRect(x: 0, y: 0, width: 320, height: 440),
            excludedFrames: [exclusion]
        )

        XCTAssertEqual(results.count, items.count)
        let frames = results.map {
            CGRect(
                x: $0.cardPoint.x - itemSize.width / 2,
                y: $0.cardPoint.y - itemSize.height / 2,
                width: itemSize.width,
                height: itemSize.height
            )
        }
        XCTAssertTrue(frames.allSatisfy { !$0.intersects(exclusion) })
        for first in frames.indices {
            for second in frames.indices where second > first {
                XCTAssertFalse(frames[first].insetBy(dx: -10, dy: -10).intersects(frames[second]))
            }
        }
    }

    func testUnreadableOverflowIsOmittedInsteadOfOverlapped() {
        let itemSize = CGSize(width: 280, height: 178)
        let items = (0..<4).map {
            CardLayoutItem(
                id: UUID(),
                desiredPoint: CGPoint(x: 150, y: 250),
                size: itemSize,
                depth: Float($0 + 1)
            )
        }

        let results = CardLayoutEngine().layout(
            items: items,
            safeFrame: CGRect(x: 0, y: 0, width: 300, height: 500)
        )

        XCTAssertLessThan(results.count, items.count)
        XCTAssertFalse(results.isEmpty)
    }

    func testSpatialLabelCountUsesClearSingularAndVisibilityCopy() {
        let formatter = SpatialLabelCountFormatter()

        XCTAssertEqual(formatter.text(total: 0), "No vehicles")
        XCTAssertEqual(formatter.text(total: 1), "1 vehicle")
        XCTAssertEqual(formatter.text(total: 2), "2 vehicles")
        XCTAssertEqual(formatter.text(total: -1), "No vehicles")
    }

    func testEqualDepthLayoutUsesDeterministicIdentityTieBreak() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let item: (UUID) -> CardLayoutItem = { id in
            CardLayoutItem(
                id: id,
                desiredPoint: CGPoint(x: 160, y: 220),
                size: CGSize(width: 100, height: 50),
                depth: 2
            )
        }
        let engine = CardLayoutEngine()
        let safeFrame = CGRect(x: 0, y: 0, width: 320, height: 440)

        let forward = engine.layout(items: [item(first), item(second)], safeFrame: safeFrame)
        let reversed = engine.layout(items: [item(second), item(first)], safeFrame: safeFrame)

        XCTAssertEqual(forward.map(\.id), [first, second])
        XCTAssertEqual(reversed.map(\.id), [first, second])
        XCTAssertEqual(forward, reversed)
    }
}
