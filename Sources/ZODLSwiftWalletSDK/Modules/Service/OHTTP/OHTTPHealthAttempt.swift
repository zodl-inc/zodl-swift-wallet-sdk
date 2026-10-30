import Foundation
import os

/// One explicit network alternative of an operation. Keep the token of the attempt whose
/// failure actually determines the business result, and pass only that token to `complete`.
/// The identity never goes on the wire. Reusing a token for another attempt is ignored.
public final class OHTTPHealthAttempt: Sendable {
    public let id: UUID
    public let operation: OHTTPHealthOperation

    private struct State {
        var entered = false
        var active = false
        var invalid = false
        var observations: [UUID: [OHTTPHealthObservation]] = [:]
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
                $0.observations = [:]
                return false
            }
            $0.entered = true
            $0.active = true
            return true
        }
    }

    func leave() { state.withLock { $0.active = false } }
    var isActive: Bool { state.withLock { $0.active } }

    func record(_ observation: OHTTPHealthObservation) {
        guard !observation.historical, observation.operation == operation, let generation = observation.generation else { return }
        state.withLock {
            guard !$0.invalid else { return }
            var entries = $0.observations[generation] ?? []
            OHTTPHealthStorage.retain(observation, in: &entries)
            $0.observations[generation] = entries
        }
    }

    func evidence(route: OHTTPHealthRoute, generation: UUID) -> [OHTTPHealthObservation] {
        state.withLock { ($0.observations[generation] ?? []).filter { $0.route == route } }
    }
}
