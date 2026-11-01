import Foundation
import os

/// Current routing or required sync-start state. Identities are local to this wallet owner.
public struct TorTransitionState: Sendable, Equatable {
    public enum Phase: Sendable { case waitingForWork, stopping, starting, applying, ready, failed, cancelled }
    public enum Failure: Error, Sendable { case acquisitionTimedOut, nonquiescent, startupTimedOut, startupFailed, routeUnavailable }
    public let requestID: UUID
    public let generation: UInt64
    public let requestedEnabled: Bool
    public let phase: Phase
    public let failure: Failure?

    public init(requestID: UUID, generation: UInt64, requestedEnabled: Bool, phase: Phase, failure: Failure? = nil) {
        self.requestID = requestID
        self.generation = generation
        self.requestedEnabled = requestedEnabled
        self.phase = phase
        self.failure = failure
    }
}

/// Optional companion surface; existing Synchronizer conformers need no new requirements.
public protocol TorTransitionProviding: AnyObject {
    var torTransitionState: TorTransitionState? { get }
    func torTransitionUpdates() -> AsyncStream<TorTransitionState>
    /// Fences new networking and cancels an opposite active request before returning.
    func requestTorTransition(enabled: Bool) -> TorTransitionRequest
}

/// Immediate choice ownership lives outside actor/lifecycle queues so Off can cancel bootstrap.
final class TorRouteTransition: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var request: TorTransitionRequest?
        var snapshot: TorTransitionState?
        var healthTransitions: [UUID] = []
        var observers: [UUID: AsyncStream<TorTransitionState>.Continuation] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let now: @Sendable () -> UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void

    init(
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    var snapshot: TorTransitionState? { state.withLock { $0.snapshot } }

    func updates() -> AsyncStream<TorTransitionState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            state.withLock {
                $0.observers[id] = continuation
                if let snapshot = $0.snapshot { continuation.yield(snapshot) }
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
            }
        }
    }

    func begin(
        enabled: Bool,
        health: OHTTPHealthBinding,
        startsSync: Bool = false,
        resetRecoveryBudget: Bool = true,
        launch: (TorTransitionRequest) -> Void
    ) -> TorTransitionRequest {
        state.withLock { state in
            if let request = state.request, request.enabled == enabled,
               let phase = state.snapshot?.phase, phase != .failed, phase != .cancelled,
               !(startsSync && phase == .ready) {
                return request
            }
            if state.snapshot?.phase != .ready { state.request?.cancel() }
            state.generation += 1
            let request = TorTransitionRequest(
                generation: state.generation,
                enabled: enabled,
                acquisitionDeadline: now() + 30_000_000_000,
                startsSync: startsSync,
                resetRecoveryBudget: resetRecoveryBudget
            )
            state.request = request
            state.healthTransitions.append(health.beginTransition())
            publish(request, phase: .waitingForWork, failure: nil, state: &state)
            launch(request)
            request.installTimer(Task { [weak self, weak request] in
                guard let self, let request else { return }
                do {
                    let current = now()
                    if request.acquisitionDeadline > current { try await sleep(request.acquisitionDeadline - current) }
                    expireWaiting(request)
                } catch { }
            })
            return request
        }
    }

    private func expireWaiting(_ request: TorTransitionRequest) {
        state.withLock { state in
            guard state.request === request, state.snapshot?.phase == .waitingForWork else { return }
            publish(request, phase: .failed, failure: .acquisitionTimedOut, state: &state)
            request.cancel(error: TorTransitionState.Failure.acquisitionTimedOut)
        }
    }

    func acquired(_ request: TorTransitionRequest) throws {
        try state.withLock { state in
            guard state.request === request, !request.isCancelled else { throw CancellationError() }
            guard now() < request.acquisitionDeadline else {
                publish(request, phase: .failed, failure: .acquisitionTimedOut, state: &state)
                request.cancel(error: TorTransitionState.Failure.acquisitionTimedOut)
                throw TorTransitionState.Failure.acquisitionTimedOut
            }
            request.acquired()
            publish(request, phase: .stopping, failure: nil, state: &state)
        }
    }

    func invalidate() {
        state.withLock { state in
            guard let request = state.request else { return }
            if state.snapshot?.phase != .ready { request.cancel() }
            state.generation += 1
            publish(request, phase: .cancelled, failure: nil, state: &state)
            state.request = nil
        }
    }

    func check(_ request: TorTransitionRequest) throws {
        guard state.withLock({ $0.request === request && $0.generation == request.generation }), !request.isCancelled else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    func commit(_ request: TorTransitionRequest, health: OHTTPHealthBinding, endpoint: LightWalletEndpoint, apply: () -> Void) throws {
        try state.withLock { state in
            guard state.request === request, !request.isCancelled else { throw CancellationError() }
            apply()
            for token in state.healthTransitions { health.settle(transition: token, endpoint: endpoint) }
            state.healthTransitions.removeAll()
            publish(request, phase: .ready, failure: nil, state: &state)
        }
    }

    func publish(_ request: TorTransitionRequest, phase: TorTransitionState.Phase, failure: TorTransitionState.Failure? = nil) {
        state.withLock { state in
            guard state.request === request, state.snapshot?.phase != .failed else { return }
            publish(request, phase: phase, failure: failure, state: &state)
        }
    }

    private func publish(
        _ request: TorTransitionRequest,
        phase: TorTransitionState.Phase,
        failure: TorTransitionState.Failure?,
        state: inout State
    ) {
        let snapshot = TorTransitionState(
            requestID: request.id,
            generation: request.generation,
            requestedEnabled: request.enabled,
            phase: phase,
            failure: failure
        )
        state.snapshot = snapshot
        for observer in state.observers.values { observer.yield(snapshot) }
    }
}
