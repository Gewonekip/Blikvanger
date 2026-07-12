import simd
import XCTest
@testable import LicensePlates

final class FrameAdmissionGateTests: XCTestCase {
    @MainActor
    func testObscuringScanSuspendsAnalysisButPreservesEstablishedLabels() {
        let controller = ARSessionController()
        let track = controller.anchorManager.createAnchor(
            at: matrix_identity_float4x4
        )

        controller.setAnalysisEnabled(false)

        XCTAssertNil(controller.frameGate.admit(timestamp: 10, trackingIsNormal: true))
        XCTAssertEqual(controller.anchorManager.track(id: track.id)?.id, track.id)

        controller.setAnalysisEnabled(true)
        XCTAssertNotNil(controller.frameGate.admit(timestamp: 10.1, trackingIsNormal: true))
    }

    func testRejectsBeforeCadenceAndWhileInFlightWithoutMaterializingFrames() {
        let gate = FrameAdmissionGate(interval: 0.2)
        let first = gate.admit(timestamp: 1, trackingIsNormal: true)
        XCTAssertNotNil(first)
        XCTAssertNil(gate.admit(timestamp: 1.3, trackingIsNormal: true), "Only one detector may be in flight")
        gate.finish(first!)
        XCTAssertNil(gate.admit(timestamp: 1.1, trackingIsNormal: true), "Older/too-close frames must be dropped")
        let next = gate.admit(timestamp: 1.3, trackingIsNormal: true)
        XCTAssertEqual(next?.droppedFrames, 2)
    }

    func testRejectsLimitedTrackingAndInvalidatesStaleGenerationOnReset() {
        let gate = FrameAdmissionGate()
        XCTAssertNil(gate.admit(timestamp: 1, trackingIsNormal: false))
        let admitted = gate.admit(timestamp: 2, trackingIsNormal: true)!
        XCTAssertTrue(gate.isCurrent(admitted.generation))
        gate.reset()
        XCTAssertFalse(gate.isCurrent(admitted.generation))
        gate.finish(admitted)
        XCTAssertNotNil(gate.admit(timestamp: 2.1, trackingIsNormal: true))
    }

    func testSuspensionRejectsQueuedFramesAndActivationRejectsPreResumeTimestamp() {
        let gate = FrameAdmissionGate(interval: 0)
        let first = gate.admit(timestamp: 3, trackingIsNormal: true)!
        gate.suspend()

        XCTAssertFalse(gate.isCurrent(first.generation))
        XCTAssertNil(gate.admit(timestamp: 3.1, trackingIsNormal: true))

        gate.activate()
        XCTAssertNil(gate.admit(timestamp: 3.05, trackingIsNormal: true))
        XCTAssertNotNil(gate.admit(timestamp: 3.2, trackingIsNormal: true))
    }

    func testExplicitRunBoundaryFloorRejectsFrameFirstObservedAfterActivation() {
        let gate = FrameAdmissionGate(interval: 0)
        let first = gate.admit(timestamp: 3, trackingIsNormal: true)!
        gate.finish(first)

        // Timestamp 3.4 represents a frame captured before the run boundary but
        // still queued on ARSession's delegate queue. It was never presented to
        // `admit` while the gate was suspended.
        gate.suspend(minimumTimestamp: 3.5)
        gate.activate(minimumTimestamp: 3.5)

        XCTAssertNil(gate.admit(timestamp: 3.4, trackingIsNormal: true))
        XCTAssertNotNil(gate.admit(timestamp: 3.6, trackingIsNormal: true))
    }

    func testProjectionTrustRequiresLaterNormallyTrackedFrame() {
        var trust = ProjectionFrameTrust()
        trust.requireFreshFrame(after: 10)

        XCTAssertFalse(trust.accepts(timestamp: 10, trackingWasNormal: true))
        XCTAssertFalse(trust.accepts(timestamp: 10.1, trackingWasNormal: false))
        XCTAssertTrue(trust.accepts(timestamp: 10.1, trackingWasNormal: true))
    }

    func testARViewOwnershipRejectsStaleDismantleToken() {
        var ownership = ARViewOwnership()
        let firstView = NSObject()
        let secondView = NSObject()
        let firstToken = ownership.claim(firstView)
        XCTAssertEqual(ownership.claim(firstView), firstToken)

        let secondToken = ownership.claim(secondView)

        XCTAssertNotEqual(firstToken, secondToken)
        XCTAssertFalse(ownership.release(firstView, token: firstToken))
        XCTAssertTrue(ownership.owns(secondView, token: secondToken))
        XCTAssertTrue(ownership.release(secondView, token: secondToken))
    }

    func testSessionCallbackGateRejectsOldSessionAndOldEpoch() {
        let gate = ARSessionCallbackGate()
        let firstSession = NSObject()
        let secondSession = NSObject()
        gate.activate(firstSession)
        let firstToken = gate.token(for: firstSession)!

        gate.activate(secondSession)

        XCTAssertFalse(gate.isCurrent(firstToken))
        XCTAssertNil(gate.token(for: firstSession))
        XCTAssertNotNil(gate.token(for: secondSession))
        XCTAssertTrue(gate.owns(secondSession))
        gate.deactivate()
        XCTAssertNil(gate.token(for: secondSession))
        XCTAssertFalse(gate.owns(secondSession))
    }

    func testSessionCallbackGateStartsNewEpochForSameSessionRun() {
        let gate = ARSessionCallbackGate()
        let session = NSObject()
        gate.activate(session)
        let priorRunToken = gate.token(for: session)!

        gate.activate(session)

        XCTAssertFalse(gate.isCurrent(priorRunToken))
        XCTAssertTrue(gate.owns(session))
    }

    func testSessionEventsAreReducedInDelegateSequenceEvenWhenTasksArriveOutOfOrder() {
        var buffer = OrderedSessionEventBuffer<String>()
        let second = ARSessionEventToken(epoch: 4, sequence: 2)
        let first = ARSessionEventToken(epoch: 4, sequence: 1)

        XCTAssertTrue(buffer.receive("tracking", token: second).isEmpty)
        XCTAssertEqual(
            buffer.receive("interruption", token: first),
            ["interruption", "tracking"]
        )
    }

    func testSessionEventBufferDropsPendingEventsAtANewEpoch() {
        var buffer = OrderedSessionEventBuffer<String>()
        XCTAssertTrue(buffer.receive(
            "old second",
            token: ARSessionEventToken(epoch: 2, sequence: 2)
        ).isEmpty)

        XCTAssertEqual(
            buffer.receive("new first", token: ARSessionEventToken(epoch: 3, sequence: 1)),
            ["new first"]
        )
    }
}
