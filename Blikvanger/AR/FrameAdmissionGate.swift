import Foundation

struct FrameAdmission: Equatable, Sendable {
    let timestamp: TimeInterval
    let generation: UInt64
    let droppedFrames: Int
}

/// A small lock-protected gate used directly from ARSession's delegate queue.
/// It prevents expensive frame materialization before cadence and in-flight checks.
/// All mutable state is protected by `lock`; callers may use this gate from
/// ARKit's delegate queue and the main actor.
final class FrameAdmissionGate: @unchecked Sendable {
    private struct State {
        var generation: UInt64 = 0
        var isActive = true
        var detectorInFlight = false
        var lastAcceptedTimestamp: TimeInterval = -.infinity
        var latestObservedTimestamp: TimeInterval = -.infinity
        var minimumTimestamp: TimeInterval = -.infinity
        var droppedFrames = 0
    }

    private let lock = NSLock()
    private var state = State()
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.22) {
        self.interval = interval
    }

    func admit(timestamp: TimeInterval, trackingIsNormal: Bool) -> FrameAdmission? {
        lock.lock()
        defer { lock.unlock() }
        guard timestamp.isFinite else { return nil }
        state.latestObservedTimestamp = max(state.latestObservedTimestamp, timestamp)
        guard state.isActive,
              trackingIsNormal,
              timestamp > state.minimumTimestamp,
              !state.detectorInFlight,
              timestamp - state.lastAcceptedTimestamp >= interval else {
            state.droppedFrames += 1
            return nil
        }
        state.detectorInFlight = true
        state.lastAcceptedTimestamp = timestamp
        let admission = FrameAdmission(
            timestamp: timestamp,
            generation: state.generation,
            droppedFrames: state.droppedFrames
        )
        state.droppedFrames = 0
        return admission
    }

    func finish(_ admission: FrameAdmission) {
        lock.lock()
        defer { lock.unlock() }
        guard admission.generation == state.generation else { return }
        state.detectorInFlight = false
    }

    @discardableResult
    func reset(minimumTimestamp: TimeInterval? = nil) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        state.generation &+= 1
        state.detectorInFlight = false
        state.minimumTimestamp = admissionFloor(minimumTimestamp)
        state.lastAcceptedTimestamp = -.infinity
        state.droppedFrames = 0
        return state.generation
    }

    @discardableResult
    func activate(minimumTimestamp: TimeInterval? = nil) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        state.generation &+= 1
        state.isActive = true
        state.detectorInFlight = false
        state.minimumTimestamp = admissionFloor(minimumTimestamp)
        state.lastAcceptedTimestamp = -.infinity
        state.droppedFrames = 0
        return state.generation
    }

    @discardableResult
    func suspend(minimumTimestamp: TimeInterval? = nil) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        state.generation &+= 1
        state.isActive = false
        state.detectorInFlight = false
        state.minimumTimestamp = admissionFloor(minimumTimestamp)
        state.lastAcceptedTimestamp = -.infinity
        state.droppedFrames = 0
        return state.generation
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == state.generation
    }

    private func admissionFloor(_ suppliedTimestamp: TimeInterval?) -> TimeInterval {
        guard let suppliedTimestamp, suppliedTimestamp.isFinite else {
            return state.latestObservedTimestamp
        }
        return max(state.latestObservedTimestamp, suppliedTimestamp)
    }
}

/// Presentation requires stricter tracking evidence than measured depth analysis.
/// A lifecycle boundary records the last frame that may belong to the old view or
/// session; only a later, normally tracked frame may drive card projection.
struct ProjectionFrameTrust: Equatable, Sendable {
    private(set) var minimumTimestamp: TimeInterval = -.infinity

    mutating func requireFreshFrame(after timestamp: TimeInterval?) {
        guard let timestamp, timestamp.isFinite else { return }
        minimumTimestamp = max(minimumTimestamp, timestamp)
    }

    func accepts(timestamp: TimeInterval, trackingWasNormal: Bool) -> Bool {
        trackingWasNormal && timestamp.isFinite && timestamp > minimumTimestamp
    }
}

struct ARViewOwnershipToken: Equatable, Sendable {
    fileprivate let value: UUID
}

/// Makes SwiftUI representable replacement an explicit ownership handoff. A
/// dismantled old view cannot tear down a newer ARView configured on the same
/// controller.
struct ARViewOwnership {
    private var ownerIdentifier: ObjectIdentifier?
    private var token: ARViewOwnershipToken?

    mutating func claim(_ owner: AnyObject) -> ARViewOwnershipToken {
        let identifier = ObjectIdentifier(owner)
        if ownerIdentifier == identifier, let token {
            return token
        }
        let token = ARViewOwnershipToken(value: UUID())
        ownerIdentifier = identifier
        self.token = token
        return token
    }

    func owns(_ owner: AnyObject, token: ARViewOwnershipToken) -> Bool {
        ownerIdentifier == ObjectIdentifier(owner) && self.token == token
    }

    @discardableResult
    mutating func release(_ owner: AnyObject, token: ARViewOwnershipToken) -> Bool {
        guard owns(owner, token: token) else { return false }
        ownerIdentifier = nil
        self.token = nil
        return true
    }

    mutating func clear() {
        ownerIdentifier = nil
        token = nil
    }
}

struct ARSessionEventToken: Equatable, Sendable {
    let epoch: UInt64
    let sequence: UInt64
}

/// Independent main-actor tasks are not guaranteed to begin in creation order.
/// Buffering by the sequence assigned on ARSession's serial delegate queue keeps
/// interruption, failure, and tracking events in their actual callback order.
struct OrderedSessionEventBuffer<Event> {
    private var epoch: UInt64?
    private var nextSequence: UInt64 = 1
    private var pending: [UInt64: Event] = [:]

    mutating func receive(_ event: Event, token: ARSessionEventToken) -> [Event] {
        if epoch != token.epoch {
            epoch = token.epoch
            nextSequence = 1
            pending.removeAll(keepingCapacity: true)
        }
        guard token.sequence >= nextSequence else { return [] }
        pending[token.sequence] = event

        var ready: [Event] = []
        while let event = pending.removeValue(forKey: nextSequence) {
            ready.append(event)
            nextSequence &+= 1
        }
        return ready
    }

    mutating func reset() {
        epoch = nil
        nextSequence = 1
        pending.removeAll(keepingCapacity: true)
    }
}

/// Rejects late delegate callbacks from a dismantled ARSession and gives
/// main-actor handlers a total order even though unstructured Tasks may resume
/// out of enqueue order.
/// All mutable state is protected by `lock`; it is the explicit boundary for
/// late callbacks from an old ARSession.
final class ARSessionCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeSession: ObjectIdentifier?
    private var epoch: UInt64 = 0
    private var sequence: UInt64 = 0

    func activate(_ session: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        epoch &+= 1
        sequence = 0
        activeSession = ObjectIdentifier(session)
    }

    func deactivate() {
        lock.lock()
        defer { lock.unlock() }
        epoch &+= 1
        sequence = 0
        activeSession = nil
    }

    func token(for session: AnyObject) -> ARSessionEventToken? {
        lock.lock()
        defer { lock.unlock() }
        guard activeSession == ObjectIdentifier(session) else { return nil }
        sequence &+= 1
        return ARSessionEventToken(epoch: epoch, sequence: sequence)
    }

    func isCurrent(_ token: ARSessionEventToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeSession != nil && token.epoch == epoch
    }

    func owns(_ session: AnyObject) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeSession == ObjectIdentifier(session)
    }
}

/// Coalesces render-thread callbacks so at most one main-actor projection update is queued.
/// The one-bit state is protected by `lock`; controller work is always resumed
/// on the main actor.
final class ProjectionUpdateScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false

    func schedule(for controller: ARSessionController) {
        lock.lock()
        guard !pending else {
            lock.unlock()
            return
        }
        pending = true
        lock.unlock()

        Task { @MainActor [weak self, weak controller] in
            controller?.updateProjections()
            self?.complete()
        }
    }

    private func complete() {
        lock.lock()
        pending = false
        lock.unlock()
    }
}
