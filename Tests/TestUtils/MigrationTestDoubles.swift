//
//  MigrationTestDoubles.swift
//  TestUtils
//

import Foundation
@testable import ZODLSwiftWalletSDK

/// A mutable clock for injecting deterministic time into `MigrationSyncGate` under test. Shared by
/// every migration test file that needs a controllable `now` (previously duplicated verbatim between
/// `MigrationLogicTests` and `OrchardMigrationCompositionTests`); promoted here following this
/// directory's `SubmissionTestDoubles.swift` precedent.
final class TestClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

/// A ``MigrationBroadcasting`` fake whose outcome (or thrown error) is scripted by the test, and
/// which records every call's `(endpoint, useTor)` so tests can assert broadcaster single-endpoint
/// discipline.
///
/// Subsumes the narrower always-throw doubles that used to be duplicated per file
/// (`MigrationLogicTests.FailClosedBroadcaster`, `MigrationFFITests.UnusedBroadcaster`, both of which
/// only ever threw `migrationTorUnavailable` and exposed a plain call counter): script
/// `.throwing(ZcashError.migrationTorUnavailable)` for the same always-fails-closed behavior, and
/// read `receivedCalls.count` in place of their `broadcastCallCount`.
final class ScriptedBroadcaster: MigrationBroadcasting {
    enum Script {
        case outcome(MigrationBroadcastOutcome)
        case throwing(Error)
    }

    private(set) var receivedCalls: [(rawTransaction: Data, endpoint: LightWalletEndpoint, useTor: Bool)] = []
    /// How many times the `onWillSubmit` hook fired. Mirrors the production contract: fired
    /// exactly once per `.outcome` call (immediately before the "submit"), never on a
    /// `.throwing` call (a fail-closed throw precedes any submit).
    private(set) var onWillSubmitCallCount = 0
    var onBroadcast: (() -> Void)?
    /// Invoked at the instant the fake fires the caller's `onWillSubmit` hook (right before it),
    /// so hook-ordering tests can capture what other observable effects preceded the pre-submit
    /// arm (A9).
    var onWillSubmitObserver: (() -> Void)?
    private let script: Script

    init(script: Script) {
        self.script = script
    }

    func broadcast(
        rawTransaction: Data,
        to endpoint: LightWalletEndpoint,
        useTor: Bool,
        onWillSubmit: @Sendable () -> Void
    ) async throws -> MigrationBroadcastOutcome {
        receivedCalls.append((rawTransaction: rawTransaction, endpoint: endpoint, useTor: useTor))
        onBroadcast?()
        switch script {
        case .outcome(let outcome):
            // The production broadcaster fires the hook at the last pre-submit instant; a
            // returned outcome means a submit happened, so the fake fires it exactly then.
            onWillSubmitObserver?()
            onWillSubmitCallCount += 1
            onWillSubmit()
            return outcome
        case .throwing(let error):
            // A throw means nothing reached the network — per the contract the hook must NOT
            // have fired.
            throw error
        }
    }
}

/// A ``MigrationBroadcasting`` fake with a test-controlled suspension: every `broadcast` call
/// suspends until ``open()`` is called, giving single-flight tests a deterministic in-flight window.
/// Starts are observable via ``awaitBroadcastsStarted(_:)``; once opened, suspended and future
/// broadcasts complete immediately with the scripted outcome. An actor, because these tests
/// deliberately call it from concurrent tasks.
///
/// Promoted here (from `OrchardMigrationCompositionTests`) so `OrchardMigrationHostTests` can hold
/// a submit open long enough to observe the wallet-scope stream's in-flight `true`.
actor GatedBroadcaster: MigrationBroadcasting {
    private let outcome: MigrationBroadcastOutcome
    private var isOpen = false
    private(set) var startedCount = 0
    private var pendingBroadcasts: [CheckedContinuation<Void, Never>] = []
    private var startObservers: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(outcome: MigrationBroadcastOutcome) {
        self.outcome = outcome
    }

    func broadcast(
        rawTransaction: Data,
        to endpoint: LightWalletEndpoint,
        useTor: Bool,
        onWillSubmit: @Sendable () -> Void
    ) async throws -> MigrationBroadcastOutcome {
        startedCount += 1
        notifyStartObservers()
        if !isOpen {
            await withCheckedContinuation { continuation in
                pendingBroadcasts.append(continuation)
            }
        }
        // Per the production contract the hook fires at the last pre-submit instant; a returned
        // outcome means a submit happened.
        onWillSubmit()
        return outcome
    }

    /// Returns once at least `count` broadcasts have started (immediately when they already have).
    func awaitBroadcastsStarted(_ count: Int) async {
        if startedCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            startObservers.append((threshold: count, continuation: continuation))
        }
    }

    /// Releases every suspended broadcast and lets all future ones complete immediately.
    func open() {
        isOpen = true
        let pending = pendingBroadcasts
        pendingBroadcasts = []
        for continuation in pending {
            continuation.resume()
        }
    }

    private func notifyStartObservers() {
        let ready = startObservers.filter { $0.threshold <= startedCount }
        startObservers.removeAll { $0.threshold <= startedCount }
        for observer in ready {
            observer.continuation.resume()
        }
    }
}

/// A generic, non-`ZcashError` failure for stubbing a `GatedTorClientFactory` bootstrap failure.
/// Promoted here (from `MigrationLogicTests`) so `OrchardMigrationHostTests` can reuse it.
struct StubTorBootstrapError: Error {}

/// A controllable test double for `MigrationBroadcaster`'s injectable Tor-client factory seam
/// (finding 8's fix): each call increments `callCount` and suspends until `resolve()` releases every
/// call suspended so far, then either returns a fresh, FFI-untouched `TorClient` or throws the
/// resolved error. Mirrors `GatedBroadcaster`'s started/threshold pattern so two concurrent
/// bootstraps can be pinned deterministically -- no `Task.sleep`, no polling.
///
/// Promoted here (from `MigrationLogicTests`) following this directory's promotion precedent, so the
/// shared-broadcaster single-bootstrap canary in `OrchardMigrationHostTests` can drive the same seam
/// through the host without duplicating it.
actor GatedTorClientFactory {
    private(set) var callCount = 0
    private var isOpen = false
    private var errorToThrow: Error?
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []
    private var startObservers: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// The injectable factory closure itself: `MigrationBroadcaster` calls this in place of its
    /// default `bootstrapTorClient(migrationTorDir:)`.
    func make(_ directory: URL) async throws -> TorClient {
        callCount += 1
        notifyStartObservers()
        if !isOpen {
            await withCheckedContinuation { continuation in
                pendingContinuations.append(continuation)
            }
        }
        if let errorToThrow {
            throw errorToThrow
        }
        // A bare `TorClient` never touches the FFI/Arti runtime until an operation is invoked on
        // it (`resolveRuntime()` is fully lazy) -- safe to construct in an offline test.
        return TorClient(torDir: directory)
    }

    /// Returns once at least `count` calls to `make` have started (immediately if they already have).
    func awaitCallsStarted(_ count: Int) async {
        if callCount >= count { return }
        await withCheckedContinuation { continuation in
            startObservers.append((threshold: count, continuation: continuation))
        }
    }

    /// Releases every call suspended so far -- and every future one -- with `error` if given, else a
    /// fresh `TorClient`.
    func resolve(throwing error: Error? = nil) {
        errorToThrow = error
        isOpen = true
        let pending = pendingContinuations
        pendingContinuations = []
        for continuation in pending {
            continuation.resume()
        }
    }

    private func notifyStartObservers() {
        let ready = startObservers.filter { $0.threshold <= callCount }
        startObservers.removeAll { $0.threshold <= callCount }
        for observer in ready {
            observer.continuation.resume()
        }
    }
}
