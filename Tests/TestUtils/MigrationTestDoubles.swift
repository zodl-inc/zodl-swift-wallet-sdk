//
//  MigrationTestDoubles.swift
//  TestUtils
//

import Foundation
import SwiftProtobuf
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
/// It keeps the production broadcaster's order on one connection: the call (connect), then the
/// scripted server height is read, then `prepareTransaction` is asked for the transaction with that
/// height, then the `onWillSubmit` hook fires and the transaction is "submitted". A test observes the
/// order with ``onBroadcast`` (the connect), ``onHeightRead``, whatever its `prepareTransaction`
/// closure does (the take) and ``onWillSubmitObserver`` (the submit), and reads the height the take
/// received from ``preparedServerHeights``.
///
/// Subsumes the narrower always-throw doubles that used to be duplicated per file
/// (`MigrationLogicTests.FailClosedBroadcaster`, `MigrationFFITests.UnusedBroadcaster`, both of which
/// only ever threw `migrationTorUnavailable` and exposed a plain call counter): script
/// `.throwing(ZcashError.migrationTorUnavailable)` for the same always-fails-closed behavior, and
/// read `receivedCalls.count` in place of their `broadcastCallCount`.
final class ScriptedBroadcaster: MigrationBroadcasting {
    enum Script {
        /// Connects, reads the scripted server height, takes the transaction and "submits" it,
        /// returning the outcome.
        case outcome(MigrationBroadcastOutcome)
        /// Fails closed before anything is read or taken (Tor unavailable): throws, and never fires
        /// the hook.
        case throwing(Error)
        /// Connects but cannot read the server's height: returns
        /// ``MigrationBroadcastOutcome/transportError`` without ever asking for a transaction, as the
        /// production broadcaster does.
        case unreadableHeight
    }

    /// The server height the fake reports unless a test scripts another.
    static let defaultServerHeight: BlockHeight = 3_600_000

    /// Every call, in order. `rawTransaction` is what `prepareTransaction` returned, and stays `nil`
    /// for a call that never got that far: one that failed closed, could not read the height, or
    /// whose preparation threw.
    private(set) var receivedCalls: [(rawTransaction: Data?, endpoint: LightWalletEndpoint, useTor: Bool)] = []
    /// The server heights `prepareTransaction` was called with, in order.
    private(set) var preparedServerHeights: [BlockHeight] = []
    /// The transactions that reached the "network", in order: the ones `prepareTransaction` returned
    /// and the fake then submitted. Empty when nothing was submitted, whatever was called.
    private(set) var submittedTransactions: [Data] = []
    /// How many times the `onWillSubmit` hook fired. Mirrors the production contract: fired
    /// exactly once per submitted transaction (immediately before the "submit"), never on a call
    /// that fails closed, cannot read the height or whose preparation throws.
    private(set) var onWillSubmitCallCount = 0
    /// Invoked as the call starts, which is the connect.
    var onBroadcast: (() -> Void)?
    /// Invoked once the fake has read its server height, right before it asks for the transaction.
    var onHeightRead: (() -> Void)?
    /// Invoked at the instant the fake fires the caller's `onWillSubmit` hook (right before it),
    /// so hook-ordering tests can capture what other observable effects preceded the pre-submit
    /// arm (A9). It is also the instant the fake submits.
    var onWillSubmitObserver: (() -> Void)?
    private let script: Script
    private let serverHeight: BlockHeight

    init(script: Script, serverHeight: BlockHeight = ScriptedBroadcaster.defaultServerHeight) {
        self.script = script
        self.serverHeight = serverHeight
    }

    func broadcast(
        to endpoint: LightWalletEndpoint,
        useTor: Bool,
        onWillSubmit: @Sendable () -> Void,
        prepareTransaction: @Sendable (_ serverHeight: BlockHeight) async throws -> Data
    ) async throws -> MigrationBroadcastOutcome {
        receivedCalls.append((rawTransaction: nil, endpoint: endpoint, useTor: useTor))
        let callIndex = receivedCalls.count - 1
        onBroadcast?()
        switch script {
        case .outcome(let outcome):
            onHeightRead?()
            preparedServerHeights.append(serverHeight)
            let rawTransaction = try await prepareTransaction(serverHeight)
            receivedCalls[callIndex].rawTransaction = rawTransaction
            submittedTransactions.append(rawTransaction)
            // The production broadcaster fires the hook at the last pre-submit instant; a
            // returned outcome means a submit happened, so the fake fires it exactly then.
            onWillSubmitObserver?()
            onWillSubmitCallCount += 1
            onWillSubmit()
            return outcome
        case .unreadableHeight:
            // Nothing was asked for, so nothing was taken, and nothing reached the network.
            return MigrationBroadcastOutcome.transportError
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
/// The suspension is the connect: once opened, a call reads the scripted server height, asks for
/// the transaction, and submits it (``submittedCount`` counts the ones that got that far), like
/// the production broadcaster. A call whose transaction is refused starts but never submits.
///
/// Promoted here (from `OrchardMigrationCompositionTests`) so `OrchardMigrationHostTests` can hold
/// a submit open long enough to observe the wallet-scope stream's in-flight `true`.
actor GatedBroadcaster: MigrationBroadcasting {
    private let outcome: MigrationBroadcastOutcome
    private let serverHeight: BlockHeight
    private var isOpen = false
    private(set) var startedCount = 0
    private(set) var submittedCount = 0
    private var pendingBroadcasts: [CheckedContinuation<Void, Never>] = []
    private var startObservers: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(outcome: MigrationBroadcastOutcome, serverHeight: BlockHeight = ScriptedBroadcaster.defaultServerHeight) {
        self.outcome = outcome
        self.serverHeight = serverHeight
    }

    func broadcast(
        to endpoint: LightWalletEndpoint,
        useTor: Bool,
        onWillSubmit: @Sendable () -> Void,
        prepareTransaction: @Sendable (_ serverHeight: BlockHeight) async throws -> Data
    ) async throws -> MigrationBroadcastOutcome {
        startedCount += 1
        notifyStartObservers()
        if !isOpen {
            await withCheckedContinuation { continuation in
                pendingBroadcasts.append(continuation)
            }
        }
        // Connected: the height is read and the transaction taken. A refusal throws out of here
        // with nothing submitted.
        _ = try await prepareTransaction(serverHeight)
        // Per the production contract the hook fires at the last pre-submit instant; a returned
        // outcome means a submit happened.
        submittedCount += 1
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

extension LightWalletServiceMockResponse {
    /// A lightwalletd answer to a submit RPC: `errorCode == 0` is acceptance, anything else a rejection
    /// with `errorMessage`.
    static func submitAnswer(errorCode: Int32, errorMessage: String = "") -> LightWalletServiceMockResponse {
        LightWalletServiceMockResponse(errorCode: errorCode, errorMessage: errorMessage, unknownFields: UnknownStorage())
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
