import Foundation
import os
import libzcashlc

/// Additive capability; the synchronizer keeps ownership of its selected endpoint and Tor runtime.
public protocol OHTTPHealthProviding {
    var ohttpHealthBinding: OHTTPHealthBinding? { get }
    func makeOHTTPHealthSession(route: OHTTPHealthRoute, generation: UUID) async throws -> OHTTPHealthSession
    func probeOHTTPHealth(session: OHTTPHealthSession) async -> OHTTPHealthProbeResult
}

public extension OHTTPHealthProviding {
    var ohttpHealthBinding: OHTTPHealthBinding? { nil }
}

public struct OHTTPHealthProbeResult: Sendable, Equatable {
    public let outcome: OHTTPHealthOutcome
    public let route: OHTTPHealthRoute
    public let generation: UUID
    public let startedAtNanoseconds: UInt64
    public let observedAtNanoseconds: UInt64

    public init(
        outcome: OHTTPHealthOutcome,
        route: OHTTPHealthRoute,
        generation: UUID,
        startedAtNanoseconds: UInt64,
        observedAtNanoseconds: UInt64
    ) {
        self.outcome = outcome
        self.route = route
        self.generation = generation
        self.startedAtNanoseconds = startedAtNanoseconds
        self.observedAtNanoseconds = observedAtNanoseconds
    }
}

struct OHTTPHealthProbeBinding {
    let endpoint: LightWalletEndpoint
    let network: NetworkType
    let viaTor: Bool
    let tor: TorClient

    func validate(_ route: OHTTPHealthRoute) throws {
        let selected = OHTTPHealthRoute(
            network: network,
            gatewayHost: endpoint.host,
            relayURL: try OHTTPEndpoints.relayURL(for: endpoint.host),
            viaTor: viaTor
        )
        guard OHTTPEndpoints.isGateway(endpoint.host), route == selected else {
            throw OHTTPError.keyConfigError("Health route does not match selected endpoint")
        }
    }

    func probe(session: OHTTPHealthSession, budget: OHTTPHealthProbeBudget) async throws -> OHTTPHealthOutcome {
        try budget.check()
        try validate(session.route)
        guard session.isValid else { throw CancellationError() }
        try budget.admit()
        let service = LightWalletOHTTPService(endpoint: endpoint, tor: tor)
        service.walletNetwork = network
        return try await service.healthInfo(viaTor: viaTor)
    }
}

enum OHTTPHealthProbe {
    @TaskLocal static var budget: OHTTPHealthProbeBudget?
    @TaskLocal static var recipient: OHTTPHealthRecipient?

    static func readInfo(client: OHTTPGRPCClient, network: NetworkType) async throws -> OHTTPHealthOutcome {
        let stream: AsyncThrowingStream<LightdInfo, Error> = try await client.serverStreamingIncremental(
            path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLightdInfo",
            request: Empty(),
            timeout: Int(try OHTTPHealthProbe.budget?.remainingMilliseconds() ?? 5000)
        )
        var info: LightdInfo?
        for try await value in stream {
            guard info == nil else { return .responseRejected }
            info = value
        }
        guard let info, NetworkType.forChainName(info.chainName) == network,
              let height = Int32(exactly: info.blockHeight), let remote = ConsensusBranchID.fromString(info.consensusBranchID),
              remote == zcashlc_branch_id_for_height(height, network.networkId) else { return .configurationFailure }
        return .usable
    }
    static func budgetMilliseconds(viaTor: Bool) -> UInt64 { viaTor ? 20_000 : 5_000 }

    static func run(
        session: OHTTPHealthSession,
        timeoutMilliseconds: UInt64? = nil,
        operation: @escaping @Sendable (OHTTPHealthProbeBudget) async throws -> OHTTPHealthOutcome
    ) async -> OHTTPHealthProbeResult {
        await $recipient.withValue(session.diagnosticRecipient) {
            await runPinned(session: session, timeoutMilliseconds: timeoutMilliseconds, operation: operation)
        }
    }

    static func cancelled(session: OHTTPHealthSession, startedAt: UInt64 = OHTTPHealthClock.nowNanoseconds) -> OHTTPHealthProbeResult {
        OHTTPHealthProbeResult(
            outcome: .cancelled,
            route: session.route,
            generation: session.generation,
            startedAtNanoseconds: startedAt,
            observedAtNanoseconds: OHTTPHealthClock.nowNanoseconds
        )
    }

    private static func runPinned(
        session: OHTTPHealthSession,
        timeoutMilliseconds: UInt64?,
        operation: @escaping @Sendable (OHTTPHealthProbeBudget) async throws -> OHTTPHealthOutcome
    ) async -> OHTTPHealthProbeResult {
        guard session.isValid else { return cancelled(session: session) }
        let ticket = OHTTPHealthCenter.shared.begin(route: session.route, scope: .lightwalletd, purpose: .diagnostic)
        let budget = OHTTPHealthProbeBudget(
            milliseconds: timeoutMilliseconds ?? budgetMilliseconds(viaTor: session.route.viaTor),
            nativeDeadline: session.route.viaTor
        )
        session.register(budget)
        defer { session.remove(budget) }
        let outcome: OHTTPHealthOutcome
        let pauses = session.snapshot().observations.compactMap { observation -> UInt64? in
            if case .rateLimited(let deadline) = observation.outcome, deadline > OHTTPHealthClock.nowNanoseconds { return deadline }
            return nil
        }
        if let pause = pauses.max() {
            outcome = .rateLimited(retryNotBefore: pause)
        } else {
            outcome = await budget.run {
                try await Self.$budget.withValue(budget) { try await operation(budget) }
            }
        }
        guard session.isValid else { return cancelled(session: session, startedAt: ticket.startedAtNanoseconds) }
        ticket.record(outcome: outcome, stage: .complete)
        if outcome == .usable { ticket.recordRouteUsable(stage: .complete) }
        return OHTTPHealthProbeResult(
            outcome: outcome,
            route: session.route,
            generation: session.generation,
            startedAtNanoseconds: ticket.startedAtNanoseconds,
            observedAtNanoseconds: OHTTPHealthClock.nowNanoseconds
        )
    }
}

/// One CLOCK_MONOTONIC budget, captured before provider/actor admission. Cancellation while
/// waiting can complete immediately; after admission the bounded network owner drains first so
/// an authoritative HTTP rejection is not replaced by the deadline firing during its body read.
final class OHTTPHealthProbeBudget: Sendable {
    let deadline: UInt64
    private let nativeDeadline: Bool
    private let now: @Sendable () -> UInt64
    private struct State {
        var admitted = false
        var stop: OHTTPHealthOutcome?
        var result: OHTTPHealthOutcome?
        var evidence: OHTTPHealthOutcome?
        var continuation: CheckedContinuation<OHTTPHealthOutcome, Never>?
        var task: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        milliseconds: UInt64,
        nativeDeadline: Bool = false,
        now: @escaping @Sendable () -> UInt64 = { OHTTPHealthClock.nowNanoseconds }
    ) {
        self.nativeDeadline = nativeDeadline
        self.now = now
        let now = now()
        let duration = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        let sum = now.addingReportingOverflow(duration.partialValue)
        deadline = duration.overflow || sum.overflow ? UInt64.max : sum.partialValue
    }

    func remainingMilliseconds() throws -> UInt64 {
        try check()
        let now = now()
        let remaining = deadline > now ? (deadline - now) / 1_000_000 : 0
        guard remaining > 0 else { throw URLError(.timedOut) }
        return remaining
    }

    func check() throws {
        try Task.checkCancellation()
        guard now() < deadline else { throw URLError(.timedOut) }
        if state.withLock({ $0.stop != nil }) { throw CancellationError() }
    }

    func admit() throws {
        try check()
        try state.withLock {
            guard $0.stop == nil else { throw CancellationError() }
            $0.admitted = true
        }
    }

    func record(_ evidence: OHTTPHealthOutcome) { state.withLock { $0.evidence = evidence } }

    func run(_ operation: @escaping @Sendable () async throws -> OHTTPHealthOutcome) async -> OHTTPHealthOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let previous = state.withLock { state -> OHTTPHealthOutcome? in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let previous {
                    continuation.resume(returning: previous)
                    return
                }
                let task = Task {
                    let result: OHTTPHealthOutcome
                    do {
                        try check()
                        result = try await operation()
                    } catch {
                        result = state.withLock { $0.evidence } ?? OHTTPHealthTraffic.outcome(error)
                    }
                    finish(result)
                }
                install(task, timer: false)
                let timer = Task {
                    do {
                        let now = now()
                        if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
                        try Task.checkCancellation()
                        stop(.transportUnavailable)
                    } catch { }
                }
                install(timer, timer: true)
            }
        } onCancel: { self.stop(.cancelled) }
    }

    private func install(_ task: Task<Void, Never>, timer: Bool) {
        let cancel = state.withLock { state in
            guard state.result == nil, state.stop == nil else { return true }
            if timer { state.timer = task } else { state.task = task }
            return false
        }
        if cancel { task.cancel() }
    }

    func cancel() { stop(.cancelled) }

    private func stop(_ reason: OHTTPHealthOutcome) {
        let effects = state.withLock { state -> (Task<Void, Never>?, Bool) in
            guard state.result == nil, state.stop == nil else { return (nil, false) }
            state.stop = reason
            // Tor legs already carry the remaining absolute budget into native send/read.
            // Let that deadline return its typed HTTP outcome before disposal. Cancelling here
            // would disguise our deadline as caller cancellation and erase known rejection.
            let cancel = reason == .cancelled || !state.admitted || !nativeDeadline
            return (cancel ? state.task : nil, !state.admitted)
        }
        effects.0?.cancel()
        if effects.1 { finish(reason) }
    }

    private struct Completion {
        let continuation: CheckedContinuation<OHTTPHealthOutcome, Never>?
        let timer: Task<Void, Never>?
        let outcome: OHTTPHealthOutcome
    }

    private func finish(_ result: OHTTPHealthOutcome) {
        let effects = state.withLock { state -> Completion? in
            guard state.result == nil else { return nil }
            let resolved: OHTTPHealthOutcome
            if state.stop == .cancelled {
                resolved = .cancelled
            } else if state.stop != nil, result == .cancelled || result == .usable || result == .inconclusive {
                resolved = .transportUnavailable
            } else {
                resolved = result
            }
            state.result = resolved
            let effects = Completion(continuation: state.continuation, timer: state.timer, outcome: resolved)
            state.continuation = nil
            state.timer = nil
            state.task = nil
            return effects
        }
        effects?.timer?.cancel()
        if let effects { effects.continuation?.resume(returning: effects.outcome) }
    }
}
