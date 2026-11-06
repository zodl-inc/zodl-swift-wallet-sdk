import Foundation
import os

/// One explicit network alternative of an operation. Keep the token of the attempt whose
/// failure actually determines the business result, and pass only that token to `complete`.
/// The identity never goes on the wire. Reusing a token for another attempt is ignored.
public final class OHTTPHealthAttempt: Sendable {
    public let id: UUID
    public let operation: OHTTPHealthOperation

    private struct Recipient: Hashable {
        let route: OHTTPHealthRoute
        let generation: UUID
    }

    private struct RequestIdentity: Hashable {
        let recipient: Recipient
        let source: OHTTPHealthSource
        let requestID: UInt64
    }

    private struct Evidence: Sendable {
        var terminal: [RequestIdentity: OHTTPHealthObservation] = [:]
        var overflow = false

        mutating func retain(_ observation: OHTTPHealthObservation, generation: UUID) {
            guard !overflow else { return }
            let key = RequestIdentity(
                recipient: Recipient(route: observation.route, generation: generation),
                source: observation.source,
                requestID: observation.requestID
            )
            if let previous = terminal[key] {
                guard observation.version > previous.version else { return }
            } else if terminal.count == 64 {
                overflow = true
                terminal = [:]
                return
            }
            terminal[key] = observation
        }
    }

    private struct State {
        var entered = false
        var active = false
        var invalid = false
        var delegating = false
        var adopted = false
        var consumed = false
        var evidence = Evidence()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(operation: OHTTPHealthOperation, id: UUID = UUID()) {
        self.operation = operation
        self.id = id
    }

    func enter() -> Bool {
        state.withLock {
            guard !$0.entered else {
                $0.invalid = true
                $0.evidence.terminal = [:]
                return false
            }
            $0.entered = true
            $0.active = true
            return true
        }
    }

    func leave() { state.withLock { $0.active = false } }
    var isActive: Bool { state.withLock { $0.active } }

    /// Mixed operations select a child explicitly; their incidental traffic remains global only.
    func beginDelegation() {
        state.withLock {
            guard !$0.delegating else { return }
            $0.delegating = true
            $0.evidence.terminal = [:]
        }
    }

    /// Copies only one explicitly selected, finished child of this operation.
    /// A child cannot be reused by another owner or supply evidence while work is still active.
    func adoptFailure(from child: OHTTPHealthAttempt) {
        guard canAdopt, child !== self, child.id != id, child.operation == operation,
              let evidence = child.takeEvidence() else { return }
        adopt(evidence)
    }

    /// Only an owner whose complete finite set of alternatives failed may use this aggregate.
    func adoptAllFailures(from children: [OHTTPHealthAttempt?]) {
        guard canAdopt, !children.isEmpty else { return }
        var identities = Set<UUID>()
        var selected: [Evidence] = []
        for child in children {
            guard let child, child !== self, child.id != id, child.operation == operation,
                  identities.insert(child.id).inserted, let evidence = child.takeEvidence() else { return }
            selected.append(evidence)
        }
        guard !selected.contains(where: \.overflow) else {
            adopt(Evidence(overflow: true))
            return
        }
        var combined = Evidence()
        let recipients = Set(selected[0].terminal.keys.map(\.recipient))
        for recipient in recipients {
            let groups = selected.map { evidence in
                evidence.terminal.filter { $0.key.recipient == recipient }.map(\.value)
            }
            guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.outcome == .transportUnavailable } }) else { continue }
            for observation in groups.flatMap({ $0 }) {
                combined.retain(observation, generation: recipient.generation)
            }
        }
        adopt(combined)
    }

    private var canAdopt: Bool {
        state.withLock { $0.active && !$0.invalid && $0.delegating && !$0.adopted }
    }

    private func takeEvidence() -> Evidence? {
        state.withLock {
            guard $0.entered, !$0.active, !$0.invalid, !$0.consumed else { return nil }
            $0.consumed = true
            return $0.evidence
        }
    }

    private func adopt(_ evidence: Evidence) {
        state.withLock {
            guard $0.active, !$0.invalid, $0.delegating, !$0.adopted else { return }
            $0.adopted = true
            if !$0.evidence.overflow { $0.evidence = evidence }
        }
    }

    func record(_ observation: OHTTPHealthObservation) {
        guard !observation.historical, observation.operation == operation, let generation = observation.generation else { return }
        state.withLock {
            guard !$0.invalid, !$0.delegating, !$0.consumed else { return }
            $0.evidence.retain(observation, generation: generation)
        }
    }

    func evidence(route: OHTTPHealthRoute, generation: UUID) -> [OHTTPHealthObservation] {
        state.withLock {
            guard !$0.invalid, !$0.evidence.overflow else { return [] }
            return $0.evidence.terminal.values.filter { $0.route == route && $0.generation == generation }.sorted {
                $0.source == $1.source ? $0.requestID < $1.requestID : $0.source == .native
            }
        }
    }
}
