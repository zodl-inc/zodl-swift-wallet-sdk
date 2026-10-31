import Foundation
import os

/// A request captures recipients, operation and monotonic start before dispatch; late completion
/// cannot move it to a replacement session. Neither the registry nor a request owns a session.
struct OHTTPHealthRequest: Sendable {
    let route: OHTTPHealthRoute
    let scope: OHTTPHealthScope
    let purpose: OHTTPHealthPurpose
    let operation: OHTTPHealthOperation?
    let attempt: OHTTPHealthAttempt?
    let requestID: UInt64
    let startedAtNanoseconds: UInt64
    let recipients: [OHTTPHealthRecipient]

    func record(outcome: OHTTPHealthOutcome, stage: OHTTPHealthStage) {
        OHTTPHealthCenter.shared.record(self, scope: scope, outcome: outcome, stage: stage)
    }

    /// An authenticated response also proves the route worked, independently of the backend result.
    func recordRouteUsable(stage: OHTTPHealthStage) {
        OHTTPHealthCenter.shared.record(self, scope: .route, outcome: .usable, stage: stage)
    }
}

struct OHTTPHealthRecipient: Sendable {
    weak var storage: OHTTPHealthStorage?
    let generation: UUID
    let operation: OHTTPHealthOperation?

    init(storage: OHTTPHealthStorage, generation: UUID, operation: OHTTPHealthOperation? = nil) {
        self.storage = storage
        self.generation = generation
        self.operation = operation
    }
}

/// Process-scoped transport registry. The bounded recent-route history contains no request payloads.
final class OHTTPHealthCenter: Sendable {
    static let shared = OHTTPHealthCenter()

    private struct State {
        var nextRequest: UInt64 = 0
        var version: UInt64 = 0
        var sessions: [OHTTPHealthRecipient] = []
        var recent: [OHTTPHealthRoute] = []
        var history: [OHTTPHealthRoute: [OHTTPHealthObservation]] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func register(_ storage: OHTTPHealthStorage) {
        state.withLock { state in
            state.sessions.removeAll { $0.storage == nil }
            let replay = (state.history[storage.route] ?? []).filter { observation in
                guard observation.purpose == .diagnostic else { return true }
                if case .rateLimited(let deadline) = observation.outcome { return deadline > OHTTPHealthClock.nowNanoseconds }
                return false
            }.map { observation in
                var replay = observation
                replay.historical = true
                return replay
            }
            storage.record(replay)
            state.sessions.append(OHTTPHealthRecipient(storage: storage, generation: storage.generation))
        }
    }

    func begin(route: OHTTPHealthRoute, scope: OHTTPHealthScope, purpose: OHTTPHealthPurpose? = nil) -> OHTTPHealthRequest {
        let pinned = OHTTPHealthProbe.recipient
        let purpose = pinned == nil ? purpose : .diagnostic
        let operation = purpose == .background || purpose == .diagnostic ? nil : OHTTPHealthContext.operation
        return state.withLock { state in
            precondition(state.nextRequest < UInt64.max, "OHTTP request identity exhausted")
            state.nextRequest += 1
            state.sessions.removeAll { $0.storage == nil }
            // A pinned but closed recipient means nobody, never a replacement route subscriber.
            let candidates = pinned.map { [$0] } ?? state.sessions
            let recipients = candidates.compactMap { recipient -> OHTTPHealthRecipient? in
                guard let storage = recipient.storage, storage.route == route else { return nil }
                return storage.capture(operation)
            }
            return OHTTPHealthRequest(
                route: route,
                scope: scope,
                purpose: purpose ?? (operation == nil ? .background : .userOperation),
                operation: operation,
                attempt: OHTTPHealthContext.attempt.flatMap { $0.operation == operation && $0.isActive ? $0 : nil },
                requestID: state.nextRequest,
                startedAtNanoseconds: OHTTPHealthClock.nowNanoseconds,
                recipients: recipients
            )
        }
    }

    func record(_ request: OHTTPHealthRequest, scope: OHTTPHealthScope, outcome: OHTTPHealthOutcome, stage: OHTTPHealthStage) {
        let observation = state.withLock { state in
            precondition(state.version < UInt64.max, "OHTTP evidence version exhausted")
            state.version += 1
            let observation = makeObservation(request, scope: scope, outcome: outcome, stage: stage, version: state.version)
            // Availability stays session-owned. An explicit pause accepted before recipient closure
            // must also constrain later same-route admission, without admitting late diagnostic work.
            let acceptedPause: Bool
            if request.purpose == .diagnostic, case .rateLimited(let deadline) = outcome, deadline > observation.observedAtNanoseconds {
                acceptedPause = request.recipients.contains { $0.storage?.capture(nil) != nil }
            } else {
                acceptedPause = false
            }
            if request.purpose != .diagnostic || acceptedPause {
                var history = state.history[request.route] ?? []
                OHTTPHealthStorage.retain(observation, in: &history)
                state.history[request.route] = history
                state.recent.removeAll { $0 == request.route }
                state.recent.append(request.route)
                if state.recent.count > 32 { state.history.removeValue(forKey: state.recent.removeFirst()) }
            }
            return observation
        }
        for recipient in request.recipients {
            let entry = OHTTPHealthObservation(
                source: .swift,
                route: observation.route,
                scope: observation.scope,
                outcome: observation.outcome,
                stage: observation.stage,
                generation: recipient.generation,
                version: observation.version,
                requestID: observation.requestID,
                startedAtNanoseconds: observation.startedAtNanoseconds,
                observedAtNanoseconds: observation.observedAtNanoseconds,
                operation: recipient.operation,
                purpose: observation.purpose == .userOperation && recipient.operation == nil ? .background : observation.purpose
            )
            recipient.storage?.record([entry])
            request.attempt?.record(entry)
        }
    }

    private func makeObservation(
        _ request: OHTTPHealthRequest,
        scope: OHTTPHealthScope,
        outcome: OHTTPHealthOutcome,
        stage: OHTTPHealthStage,
        version: UInt64
    ) -> OHTTPHealthObservation {
        OHTTPHealthObservation(
            source: .swift,
            route: request.route,
            scope: scope,
            outcome: outcome,
            stage: stage,
            generation: request.recipients.first?.generation,
            version: version,
            requestID: request.requestID,
            startedAtNanoseconds: request.startedAtNanoseconds,
            observedAtNanoseconds: OHTTPHealthClock.nowNanoseconds,
            operation: request.operation,
            purpose: request.purpose
        )
    }

    func complete(_ operation: OHTTPHealthOperation, failed: Bool, failedAttempt: OHTTPHealthAttempt? = nil) async {
        let sessions = state.withLock { $0.sessions.compactMap(\.storage) }
        // One stalled subscriber must not prevent another route/subscriber receiving completion.
        await withTaskGroup(of: Void.self) { group in
            for storage in sessions {
                group.addTask { await storage.complete(operation, failed: failed, failedAttempt: failedAttempt) }
            }
        }
    }
}

/// Session-local ownership and source merge. Locks are never held across native teardown or suspension.
final class OHTTPHealthStorage: Sendable {
    let route: OHTTPHealthRoute
    let generation: UUID
    private let startedAtNanoseconds = OHTTPHealthClock.nowNanoseconds
    private struct State {
        var closed = false
        var version: UInt64 = 0
        var observations: [OHTTPHealthObservation] = []
        var operations: Set<OHTTPHealthOperation> = []
        var mailboxes: [UUID: OHTTPHealthMailbox] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(route: OHTTPHealthRoute, generation: UUID) {
        self.route = route
        self.generation = generation
    }

    func capture(_ operation: OHTTPHealthOperation?) -> OHTTPHealthRecipient? {
        state.withLock { state in
            guard !state.closed else { return nil }
            // Request ownership is captured NOW. An inherited action predating this owner loses
            // action attribution, but this genuinely new request still reports fresh route health.
            let currentOperation = operation.flatMap { $0.startedAtNanoseconds > startedAtNanoseconds ? $0 : nil }
            if let currentOperation { state.operations.insert(currentOperation) }
            return OHTTPHealthRecipient(storage: self, generation: generation, operation: currentOperation)
        }
    }

    static func retain(_ observation: OHTTPHealthObservation, in entries: inout [OHTTPHealthObservation]) {
        if let index = entries.firstIndex(where: {
            $0.source == observation.source && $0.scope == observation.scope && $0.outcome.category == observation.outcome.category
        }) {
            let previous = entries[index]
            guard (observation.observedAtNanoseconds, observation.version) > (previous.observedAtNanoseconds, previous.version) else { return }
            entries[index] = observation
        } else {
            entries.append(observation)
        }
    }

    func record(_ observations: [OHTTPHealthObservation]) {
        let delivery = state.withLock { state -> (OHTTPHealthSnapshot, [OHTTPHealthMailbox])? in
            guard !state.closed else { return nil }
            let previous = state.observations
            for observation in observations {
                guard observation.route == route, observation.historical || observation.generation == generation else { continue }
                Self.retain(observation, in: &state.observations)
            }
            guard previous != state.observations else { return nil }
            state.version += 1
            let snapshot = OHTTPHealthSnapshot(generation: generation, version: state.version, observations: state.observations)
            return (snapshot, Array(state.mailboxes.values))
        }
        if let delivery {
            for mailbox in delivery.1 { mailbox.snapshot(delivery.0) }
        }
    }

    func snapshot() -> OHTTPHealthSnapshot {
        state.withLock { OHTTPHealthSnapshot(generation: generation, version: $0.version, observations: $0.observations) }
    }

    func updates() -> AsyncStream<OHTTPHealthUpdate> {
        let id = UUID()
        let mailbox = OHTTPHealthMailbox()
        state.withLock { state in
            if state.closed {
                mailbox.close()
            } else {
                state.mailboxes[id] = mailbox
                mailbox.snapshot(OHTTPHealthSnapshot(generation: generation, version: state.version, observations: state.observations))
            }
        }
        let lifetime = StreamLifetime(mailbox: mailbox) { [weak self] in
            _ = self?.state.withLock { $0.mailboxes.removeValue(forKey: id) }
            mailbox.close()
        }
        return AsyncStream(unfolding: { await lifetime.mailbox.next() }, onCancel: { lifetime.retire() })
    }

    /// AsyncStream's unfolding initializer only exposes task cancellation. Retire the mailbox as
    /// well when the last stream/iterator owner releases the closures without requesting another item.
    private final class StreamLifetime: Sendable {
        let mailbox: OHTTPHealthMailbox
        let retire: @Sendable () -> Void

        init(mailbox: OHTTPHealthMailbox, retire: @escaping @Sendable () -> Void) {
            self.mailbox = mailbox
            self.retire = retire
        }

        deinit { retire() }
    }

    func complete(_ operation: OHTTPHealthOperation, failed: Bool, failedAttempt: OHTTPHealthAttempt? = nil) async {
        let delivery = state.withLock { state -> ([OHTTPHealthObservation], [OHTTPHealthMailbox])? in
            guard !state.closed, state.operations.remove(operation) != nil else { return nil }
            let evidence = failed && failedAttempt?.operation == operation
                ? failedAttempt?.evidence(route: route, generation: generation) ?? [] : []
            return (evidence, Array(state.mailboxes.values))
        }
        guard let delivery else { return }
        let update = OHTTPHealthUpdate.operationCompleted(operation, failed: failed, observations: delivery.0)
        await withTaskGroup(of: Void.self) { group in
            for mailbox in delivery.1 { group.addTask { await mailbox.complete(update) } }
        }
    }

    func close() {
        let mailboxes = state.withLock { state in
            state.closed = true
            let mailboxes = Array(state.mailboxes.values)
            state.mailboxes = [:]
            state.observations = []
            state.operations = []
            return mailboxes
        }
        for mailbox in mailboxes { mailbox.close() }
    }
}
