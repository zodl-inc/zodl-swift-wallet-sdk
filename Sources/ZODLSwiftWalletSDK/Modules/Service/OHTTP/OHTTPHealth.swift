import Foundation
import os
import Darwin

/// A configuration identity, never a per-request URL or a backend destination.
public struct OHTTPHealthRoute: Hashable, Sendable {
    public let network: NetworkType
    public let gatewayHost: String
    public let relayURL: String
    public let viaTor: Bool

    public init(network: NetworkType, gatewayHost: String, relayURL: String, viaTor: Bool) {
        self.network = network
        self.gatewayHost = gatewayHost.lowercased()
        self.relayURL = relayURL
        self.viaTor = viaTor
    }
}

public enum OHTTPHealthSource: Sendable, Hashable { case native, swift }

public enum OHTTPHealthScope: UInt32, Sendable, CaseIterable {
    case route, lightwalletd, exchangeRates, swaps, voting, flexa, other
}

public enum OHTTPHealthOutcome: Sendable, Equatable {
    case usable
    case transportUnavailable
    case backendUnavailable
    /// The deadline uses ``OHTTPHealthClock``'s monotonic nanoseconds.
    case rateLimited(retryNotBefore: UInt64)
    case policyRejected
    case configurationFailure
    case responseRejected
    case cancelled
    case inconclusive

    var category: Int {
        switch self {
        case .usable: return 0
        case .transportUnavailable: return 1
        case .backendUnavailable: return 2
        case .rateLimited: return 3
        case .policyRejected: return 4
        case .configurationFailure: return 5
        case .responseRejected: return 6
        case .cancelled: return 7
        case .inconclusive: return 8
        }
    }
}

public enum OHTTPHealthStage: UInt32, Sendable { case connection, keyConfiguration, responseHead, responseBody, complete }
public enum OHTTPHealthPurpose: UInt32, Sendable { case background, userOperation, diagnostic }

/// Same CLOCK_MONOTONIC domain as native evidence; do not compare with wall time or DispatchTime.
public enum OHTTPHealthClock {
    public static var nowNanoseconds: UInt64 {
        var time = timespec()
        precondition(clock_gettime(CLOCK_MONOTONIC, &time) == 0, "CLOCK_MONOTONIC is required for health evidence")
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }
}

/// Immutable identity shared by the child work of one explicit user operation.
/// It is local correlation data and is never serialized into HTTP requests.
public struct OHTTPHealthOperation: Sendable, Hashable {
    public let id: UUID
    public let startedAtNanoseconds: UInt64

    public init(id: UUID = UUID(), startedAtNanoseconds: UInt64 = OHTTPHealthClock.nowNanoseconds) {
        self.id = id
        self.startedAtNanoseconds = startedAtNanoseconds
    }
}

public struct OHTTPHealthObservation: Sendable, Equatable {
    public let source: OHTTPHealthSource
    public let route: OHTTPHealthRoute
    public let scope: OHTTPHealthScope
    public let outcome: OHTTPHealthOutcome
    public let stage: OHTTPHealthStage
    /// Nil for native history whose original owner is no longer known in Swift.
    public let generation: UUID?
    /// Original native generation, including zero for evidence without an owner. Nil for Swift.
    public let nativeGeneration: UInt64?
    /// Monotonic within this source, not comparable between sources.
    public let version: UInt64
    public let requestID: UInt64
    public let startedAtNanoseconds: UInt64
    public let observedAtNanoseconds: UInt64
    public let operation: OHTTPHealthOperation?
    public let purpose: OHTTPHealthPurpose
    /// Replay is never fresh evidence, even when its original generation matches.
    public internal(set) var historical: Bool

    public init(
        source: OHTTPHealthSource,
        route: OHTTPHealthRoute,
        scope: OHTTPHealthScope,
        outcome: OHTTPHealthOutcome,
        stage: OHTTPHealthStage,
        generation: UUID?,
        nativeGeneration: UInt64? = nil,
        version: UInt64,
        requestID: UInt64,
        startedAtNanoseconds: UInt64,
        observedAtNanoseconds: UInt64,
        operation: OHTTPHealthOperation? = nil,
        purpose: OHTTPHealthPurpose = .background,
        historical: Bool = false
    ) {
        self.source = source
        self.route = route
        self.scope = scope
        self.outcome = outcome
        self.stage = stage
        self.generation = generation
        self.nativeGeneration = nativeGeneration
        self.version = version
        self.requestID = requestID
        self.startedAtNanoseconds = startedAtNanoseconds
        self.observedAtNanoseconds = observedAtNanoseconds
        self.operation = operation
        self.purpose = purpose
        self.historical = historical
    }
}

public struct OHTTPHealthSnapshot: Sendable, Equatable {
    public let generation: UUID
    /// Session delivery version. Each observation also preserves its own source version.
    public let version: UInt64
    /// At most 126 entries: two sources × seven scopes × nine outcome categories.
    public let observations: [OHTTPHealthObservation]

    public init(generation: UUID, version: UInt64, observations: [OHTTPHealthObservation]) {
        self.generation = generation
        self.version = version
        self.observations = observations
    }
}

public enum OHTTPHealthUpdate: Sendable, Equatable {
    case snapshot(OHTTPHealthSnapshot)
    /// Evidence of the explicitly failed network attempt only. Empty for a local failure or when no final attempt is attributed.
    case operationCompleted(OHTTPHealthOperation, failed: Bool, observations: [OHTTPHealthObservation])
}

public enum OHTTPHealthError: Error, Sendable, Equatable {
    case unsupportedNativeVersion(UInt32)
    case subscriptionFailed
    /// The provider is replacing its selected route. Retry setup after its binding becomes ready.
    case bindingUnavailable
}

public enum OHTTPHealthContext {
    @TaskLocal public static var operation: OHTTPHealthOperation?
    @TaskLocal static var attempt: OHTTPHealthAttempt?

    public static func withOperation<T: Sendable>(
        _ operation: OHTTPHealthOperation,
        operation work: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await $attempt.withValue(nil) {
            try await $operation.withValue(operation) { try await work() }
        }
    }

    /// Automatic retries, timers and follow-up work must not inherit a user's action identity.
    public static func withBackground<T: Sendable>(operation work: @Sendable () async throws -> T) async rethrows -> T {
        try await $attempt.withValue(nil) {
            try await $operation.withValue(nil) { try await work() }
        }
    }

    /// Scope only the network await whose final failure may determine the operation result.
    /// Nested foreign operations and reused attempt tokens never inherit attribution.
    /// For a lazy submission stream, keep this scope active until consumption finishes. SDK
    /// submission owners select their terminal child internally; the caller still decides whether
    /// the final business result failed before supplying this token to `complete`.
    public static func withAttempt<T: Sendable>(
        _ attempt: OHTTPHealthAttempt,
        operation work: @Sendable () async throws -> T
    ) async rethrows -> T {
        let admitted = operation == attempt.operation && attempt.enter()
        defer { if admitted { attempt.leave() } }
        return try await $attempt.withValue(admitted ? attempt : nil) { try await work() }
    }

    /// Publish the business result and leave transaction/wallet critical sections before awaiting health delivery. A stalled subscriber applies
    /// backpressure after 64 completions. Cancellation does not discard accepted completion evidence;
    /// consuming or closing the subscriber releases this wait. This never changes individual outcomes.
    public static func complete(_ operation: OHTTPHealthOperation, failed: Bool, failedAttempt: OHTTPHealthAttempt? = nil) async {
        await OHTTPHealthCenter.shared.complete(operation, failed: failed, failedAttempt: failedAttempt)
    }

    /// Select only the complete finite set of attempts whose failures determine the final business result.
    /// Mixed, pending or unknown results cannot be inferred to be all-failed from an error alone.
    /// Each child must be finished, distinct and unused, with complete nonempty terminal transport
    /// failures for the same route and generation. Invalid or missing children and more than 64
    /// terminal request identities leave completion without qualifying evidence. Original identities
    /// and global observations are preserved. Success does not consume the supplied attempts.
    /// Publish the original business result and release transaction/wallet guards before awaiting
    /// completion. Delivery has the same backpressure and cancellation semantics as single-attempt completion.
    public static func complete(_ operation: OHTTPHealthOperation, failed: Bool, allFailedAttempts: [OHTTPHealthAttempt?]) async {
        guard failed else {
            await complete(operation, failed: false)
            return
        }
        let aggregate = OHTTPHealthAttempt(operation: operation)
        _ = aggregate.enter()
        aggregate.beginDelegation()
        aggregate.adoptAllFailures(from: allFailedAttempts)
        aggregate.leave()
        await complete(operation, failed: true, failedAttempt: aggregate)
    }
}

/// Owns a retained native subscription and Swift observations for exactly one route generation.
/// Construction fails explicitly if the linked native library does not support this capability.
public final class OHTTPHealthSession: Sendable {
    public let route: OHTTPHealthRoute
    public let generation: UUID
    public let bindingID: UUID?
    let ownerID: UUID?
    private struct State {
        var valid = true
        var budgets: [ObjectIdentifier: OHTTPHealthProbeBudget] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let closeCompletion = DispatchGroup()
    public var isValid: Bool { state.withLock { $0.valid } }
    var diagnosticRecipient: OHTTPHealthRecipient { OHTTPHealthRecipient(storage: storage, generation: generation) }

    func register(_ budget: OHTTPHealthProbeBudget) {
        let accepted = state.withLock { state in
            guard state.valid else { return false }
            state.budgets[ObjectIdentifier(budget)] = budget
            return true
        }
        if !accepted { budget.cancel() }
    }

    func remove(_ budget: OHTTPHealthProbeBudget) {
        _ = state.withLock { $0.budgets.removeValue(forKey: ObjectIdentifier(budget)) }
    }
    private let storage: OHTTPHealthStorage
    private let closeNative: @Sendable () -> Void

    public convenience init(route: OHTTPHealthRoute, generation: UUID) throws {
        try self.init(route: route, generation: generation, bindingID: nil, ownerID: nil)
    }

    init(
        route: OHTTPHealthRoute,
        generation: UUID,
        bindingID: UUID?,
        ownerID: UUID?,
        closeNative: @escaping @Sendable (OHTTPNativeHealth) -> Void = { $0.close() }
    ) throws {
        self.bindingID = bindingID
        self.ownerID = ownerID
        self.route = route
        self.generation = generation
        let storage = OHTTPHealthStorage(route: route, generation: generation)
        self.storage = storage
        let native = try OHTTPNativeHealth(route: route, generation: generation) { [weak storage] observations in
            storage?.record(observations)
        }
        self.closeNative = { closeNative(native) }
        closeCompletion.enter()
        OHTTPHealthCenter.shared.register(storage)
    }

    /// Each subscriber gets one coalesced snapshot slot and 64 lossless completion slots.
    /// Consume on a task that does not wait for presentation or user input. Cancel its task or close
    /// the session to retire it and release blocked completion publishers.
    public func updates() -> AsyncStream<OHTTPHealthUpdate> { storage.updates() }
    public func snapshot() -> OHTTPHealthSnapshot { storage.snapshot() }

    /// Retires delivery before fencing native callbacks; never holds a callback-required lock.
    public func close() {
        let budgets = state.withLock { state -> [OHTTPHealthProbeBudget]? in
            guard state.valid else { return nil }
            state.valid = false
            let budgets = Array(state.budgets.values)
            state.budgets = [:]
            return budgets
        }
        guard let budgets else {
            // Join only synchronous native teardown, never diagnostic tasks or async work.
            // The native callback touches storage alone and cannot re-enter this close.
            closeCompletion.wait()
            return
        }
        storage.close()
        for budget in budgets { budget.cancel() }
        closeNative()
        closeCompletion.leave()
    }

    deinit { close() }
}
