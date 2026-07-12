import ARKit
import XCTest
@testable import LicensePlates

@MainActor
final class AnchorManagerTests: XCTestCase {
    func testAnchorsHaveStableIdentityAndIndependentTransforms() {
        let session = SessionSpy()
        let manager = AnchorManager(session: session)
        var firstTransform = matrix_identity_float4x4
        firstTransform.columns.3 = SIMD4(1, 2, 3, 1)
        var secondTransform = matrix_identity_float4x4
        secondTransform.columns.3 = SIMD4(4, 5, 6, 1)

        let first = manager.createAnchor(at: firstTransform)
        let second = manager.createAnchor(at: secondTransform)

        XCTAssertEqual(first.displayName, "Car 1")
        XCTAssertEqual(second.displayName, "Car 2")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(manager.tracks.count, 2)
        XCTAssertEqual(session.added.count, 2)
        XCTAssertEqual(first.stableTransform.columns.3.x, 1)
        XCTAssertEqual(first.stableTransform.columns.3.z, 3)
    }

    func testRemovalAndResetClearAnchorAndPresentationState() {
        let session = SessionSpy()
        let manager = AnchorManager(session: session)
        let first = manager.createAnchor(at: matrix_identity_float4x4)
        _ = manager.createAnchor(at: matrix_identity_float4x4)

        manager.remove(trackID: first.id)
        XCTAssertNil(manager.track(id: first.id))
        XCTAssertEqual(session.removed.count, 1)

        manager.reset()
        XCTAssertTrue(manager.tracks.isEmpty)
        XCTAssertNil(manager.selectedTrackID)
        XCTAssertEqual(session.removed.count, 2)

        let afterReset = manager.createAnchor(at: matrix_identity_float4x4)
        XCTAssertEqual(afterReset.displayName, "Car 1")
    }

    func testPendingAnchorIsAddedWhenSessionAttaches() {
        let manager = AnchorManager()
        let track = manager.createAnchor(at: matrix_identity_float4x4)
        let session = SessionSpy()

        manager.attach(to: session)
        manager.attach(to: session)

        XCTAssertEqual(session.added.count, 1)
        XCTAssertEqual(session.added[0].identifier, track.anchorIdentifier)
    }

    func testMetadataUpdateCannotMutateSpatialIdentity() {
        let manager = AnchorManager()
        let original = manager.createAnchor(at: matrix_identity_float4x4)
        var update = original
        update.displayName = "12-BD-34"
        update.stableTransform.columns.3.x = 99
        update.anchorIdentifier = UUID()

        manager.update(update)

        let stored = manager.track(id: original.id)
        XCTAssertEqual(stored?.displayName, "12-BD-34")
        XCTAssertEqual(stored?.stableTransform.columns.3.x, 0)
        XCTAssertEqual(stored?.anchorIdentifier, original.anchorIdentifier)
    }

    func testARKitTransformRefinementUpdatesSpatialTruthWithoutChangingIdentity() throws {
        let manager = AnchorManager()
        let original = manager.createAnchor(
            at: matrix_identity_float4x4,
            displayName: "12-BD-34"
        )
        var refined = matrix_identity_float4x4
        refined.columns.3 = SIMD4(0.4, 0.1, -2, 1)

        manager.synchronizeARKitTransform(
            anchorIdentifier: original.anchorIdentifier,
            transform: refined
        )

        let updated = try XCTUnwrap(manager.track(id: original.id))
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.anchorIdentifier, original.anchorIdentifier)
        XCTAssertEqual(updated.displayName, "12-BD-34")
        XCTAssertEqual(updated.stableTransform.columns.3.x, 0.4, accuracy: 0.0001)
        XCTAssertEqual(updated.stableTransform.columns.3.z, -2, accuracy: 0.0001)
    }
}

@MainActor
private final class SessionSpy: WorldAnchorSession {
    var added: [ARAnchor] = []
    var removed: [ARAnchor] = []

    func add(anchor: ARAnchor) { added.append(anchor) }
    func remove(anchor: ARAnchor) { removed.append(anchor) }
}
