//
//  OrchardMigrationHostTests.swift
//  OfflineTests
//
//  Tests for `OrchardMigrationHost`: the per-synchronizer owner of the migration machinery. Driven
//  through the host's injecting initializer against `ZcashRustBackendWeldingMock`, the shared
//  `MigrationBroadcasting` seam, and real temp-file-backed `MigrationSyncGate`s (as established by
//  the other migration test files). No network, no real FFI. Covers per-account actor identity and
//  caching, the single shared Tor bootstrap across accounts, the wallet-scope `isSyncBlocked()`
//  predicate (including dormant-account enumeration and degrade-open), and the wallet-scope
//  `syncBlockedStream`.
//

import Combine
import XCTest
@testable import TestUtils
@_spi(Testing) @testable import ZODLSwiftWalletSDK

final class OrchardMigrationHostTests: ZcashTestCase {
    private let accountA = AccountUUID(id: [UInt8](repeating: 0x0A, count: 16))
    private let accountB = AccountUUID(id: [UInt8](repeating: 0x0B, count: 16))
    private let accountD = AccountUUID(id: [UInt8](repeating: 0x0D, count: 16))
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let submissionEndpoint = LightWalletEndpoint(address: "submit.example", port: 9067)

    private var clock: TestClock!

    override func setUp() {
        super.setUp()
        clock = TestClock(referenceDate)
    }

    override func tearDown() {
        clock = nil
        super.tearDown()
    }

    // MARK: - Per-account identity and caching

    /// Same account resolves to the same cached actor; distinct accounts get distinct actors; and
    /// driving each actor reaches the welding with that actor's own account UUID.
    func testMigrationForAccountCachesPerAccountAndRoutesTheRightUUID() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationAdvanceStepForEstimatedTipReturnValue = MigrationAdvance(step: .waiting, next: nil)
        let host = makeHost(welding: welding, broadcaster: ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)))

        let firstA = await host.migration(for: accountA)
        let secondA = await host.migration(for: accountA)
        let firstB = await host.migration(for: accountB)

        XCTAssertTrue(firstA === secondA, "the same account must resolve to the same cached actor")
        XCTAssertFalse(firstA === firstB, "distinct accounts must get distinct actors")

        // Driving each actor (sequentially) reaches the welding with that actor's own account UUID.
        _ = try await firstA.advanceStep()
        XCTAssertEqual(welding.migrationAdvanceStepForEstimatedTipReceivedArguments?.account, accountA)
        _ = try await firstB.advanceStep()
        XCTAssertEqual(welding.migrationAdvanceStepForEstimatedTipReceivedArguments?.account, accountB)
    }

    // MARK: - Shared broadcaster (single Tor bootstrap across accounts)

    /// Shared-broadcaster canary: two accounts each broadcasting (over Tor) through their own actor go
    /// through the host's ONE `MigrationBroadcaster`, so exactly ONE Tor bootstrap happens — counted
    /// via the broadcaster's injectable `torClientFactory`. If each actor built its own broadcaster
    /// (the latent multi-account hazard this host closes), the count would be two. Held gated and
    /// resolved with a failure so no real Arti runtime/connection is ever driven (offline).
    func testTwoAccountsBroadcastingShareASingleTorBootstrap() async throws {
        let factory = GatedTorClientFactory()
        let sharedBroadcaster = MigrationBroadcaster(
            torDirURL: testGeneralStorageDirectory,
            logger: logger,
            torClientFactory: factory.make
        )

        let prepared = PreparedMigrationTransfer(
            id: 0,
            txid: Data(repeating: 0xAB, count: 32),
            pczt: Data([0x01, 0x02])
        )
        // Fulfilled from account B's own actor, right before it hands off to the shared broadcaster
        // (its next step, `syncGate.markBroadcastInFlight()`, is synchronous, so this fires at most
        // one actor-hop before B's `dedicatedTorClient()` cache check) -- a much tighter, and
        // therefore far less flaky, synchronization point than counting `Task.yield()`s from B's
        // Task start, which has to cross B's own mocked advance/serve calls first too.
        let accountBReachedTheBroadcaster = expectation(description: "account B's actor reached the point just before calling the shared broadcaster")
        // A fresh mock per account keeps the two concurrent broadcast flows off a shared mutable mock.
        let perAccountFactory: (AccountUUID, any MigrationBroadcasting) -> OrchardMigration = { [testGeneralStorageDirectory, clock, accountB] accountUUID, broadcaster in
            let accountWelding = ZcashRustBackendWeldingMock()
            accountWelding.migrationTakeBroadcastTransactionIdForClosure = { _, _ in
                if accountUUID == accountB {
                    accountBReachedTheBroadcaster.fulfill()
                }
                return prepared
            }
            return OrchardMigration(
                welding: accountWelding,
                accountUUID: accountUUID,
                broadcaster: broadcaster,
                syncGate: MigrationSyncGate(
                    directory: testGeneralStorageDirectory!,
                    accountUUID: accountUUID,
                    tickInterval: 3600,
                    now: { clock!.now },
                    logger: logger
                ),
                logger: logger
            )
        }

        let clockValue = clock!
        let host = OrchardMigrationHost(
            welding: ZcashRustBackendWeldingMock(),
            sharedBroadcaster: sharedBroadcaster,
            generalStorageURL: testGeneralStorageDirectory,
            tickInterval: 3600,
            now: { clockValue.now },
            logger: logger,
            actorFactory: perAccountFactory
        )

        let migrationA = await host.migration(for: accountA)
        let migrationB = await host.migration(for: accountB)
        let options = MigrationNetworkPrivacyOptions(useTor: true, submissionEndpoint: submissionEndpoint)

        let taskA = Task { try await migrationA.performBroadcast(MigrationBroadcastInstruction(id: prepared.id), options: options) }
        // Wait for account A's broadcast to have started the (single) bootstrap.
        await factory.awaitCallsStarted(1)
        let taskB = Task { try await migrationB.performBroadcast(MigrationBroadcastInstruction(id: prepared.id), options: options) }
        // Deterministic: B has reached its own extract step, one short hop from the shared
        // broadcaster's cache check.
        await fulfillment(of: [accountBReachedTheBroadcaster], timeout: 5)
        // The one remaining hop is NOT purely cooperative: `MigrationSyncGate.markBroadcastInFlight()`
        // -- B's very next step -- does a real synchronous, atomic file write (finding 14's
        // durability requirement), which can genuinely block its worker thread on I/O rather than
        // merely being an unscheduled `Task`; `Task.yield()` only reorders cooperatively-ready work
        // and cannot wait out that write. A short real sleep is the honest bridge for that non-
        // cooperative gap (the test's own correctness comes from `countWhileInFlight`/`finalCount`
        // below, not from this duration).
        try await Task.sleep(nanoseconds: 200_000_000)

        let countWhileInFlight = await factory.callCount
        XCTAssertEqual(countWhileInFlight, 1, "two accounts must share ONE Tor bootstrap through the host's shared broadcaster")

        await factory.resolve(throwing: StubTorBootstrapError())
        await assertThrowsMigrationTorUnavailable(taskA)
        await assertThrowsMigrationTorUnavailable(taskB)

        let finalCount = await factory.callCount
        XCTAssertEqual(finalCount, 1, "the failing bootstrap was shared by both accounts, not driven twice")
    }

    // MARK: - Wallet-scope isSyncBlocked (dormant enumeration + degrade-open)

    /// Dormant-account enumeration: a persisted gate file for an account whose actor is never
    /// created still blocks sync — the crash-mid-broadcast case. Account B's in-flight marker is
    /// written by a throwaway gate; a FRESH host that never instantiates B's actor enumerates
    /// [A, B] via the welding, reads B's gate file directly, and reports blocked while the marker
    /// is live — then unblocked once the injected clock passes its self-expiry.
    func testIsSyncBlockedEnumeratesDormantAccountsFromTheirPersistedGateFiles() async throws {
        // Persist a live in-flight marker for B, then discard the gate (a crash between submit
        // and record leaves exactly this).
        let dormantGateB = MigrationSyncGate(
            directory: testGeneralStorageDirectory,
            accountUUID: accountB,
            tickInterval: 3600,
            now: { [clock] in clock!.now },
            logger: logger
        )
        dormantGateB.markBroadcastInFlight()

        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsReturnValue = [makeAccount(accountA), makeAccount(accountB)]
        let host = makeHost(welding: welding, broadcaster: ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)))

        let blockedWhileInFlight = await host.isSyncBlocked()
        XCTAssertTrue(blockedWhileInFlight, "a dormant account's live gate file must block sync after a fresh launch")

        clock.now = referenceDate.addingTimeInterval(MigrationSyncGate.broadcastInFlightGuardDuration + 1)
        let blockedAfterExpiry = await host.isSyncBlocked()
        XCTAssertFalse(blockedAfterExpiry, "once the marker self-expires, sync is no longer blocked")
    }

    /// Degrade-open: if the welding's account enumeration throws, `isSyncBlocked()` returns `false`
    /// (sync allowed) and never crashes — matching `OrchardMigration.isSyncBlocked()`'s behavior.
    func testIsSyncBlockedDegradesOpenWhenAccountEnumerationThrows() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsThrowableError = StubHostWeldingError()
        let host = makeHost(welding: welding, broadcaster: ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)))

        let blocked = await host.isSyncBlocked()
        XCTAssertFalse(blocked, "an account-enumeration failure must degrade open, not crash")
    }

    /// D1 REVERSAL PIN at wallet scope: with no gate file and no live view for either enumerated
    /// account, the predicate holds sync for nothing — and never reaches the estimate, whose whole
    /// second pass died with the gate's forward-looking clause.
    func testIsSyncBlockedHoldsForNothingForwardLookingAcrossAllAccounts() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsReturnValue = [makeAccount(accountA), makeAccount(accountB)]
        let host = makeHost(welding: welding, broadcaster: ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)))

        let blocked = await host.isSyncBlocked()

        XCTAssertFalse(blocked, "sync holds only while a submission is in flight (gate files, live views)")
        XCTAssertFalse(welding.migrationBlockRateSamplesWindowCalled, "the estimate pass is deleted")
    }


    /// A8: a mark whose gate-FILE write failed (the gate directory is made read-only, so
    /// `markBroadcastInFlight()`'s persist fails while its in-memory cache updates) must still
    /// block the WALLET-scope predicate: the host consults the hosted actor's live gate view
    /// alongside the file, and blocked wins.
    func testIsSyncBlockedConsultsTheLiveGateWhenTheFileWriteFailed() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsReturnValue = [makeAccount(accountA)]
        welding.migrationBlockRateSamplesWindowReturnValue = []

        // A factory that hands the created actor's gate back to the test, so the test can drive
        // `markBroadcastInFlight()` directly against a broken filesystem.
        let directory = testGeneralStorageDirectory!
        let clockValue = clock!
        var capturedGates: [MigrationSyncGate] = []
        let capturingFactory: (AccountUUID, any MigrationBroadcasting) -> OrchardMigration = { accountUUID, broadcaster in
            let gate = MigrationSyncGate(
                directory: directory,
                accountUUID: accountUUID,
                tickInterval: 3600,
                now: { clockValue.now },
                logger: logger
            )
            capturedGates.append(gate)
            return OrchardMigration(
                welding: welding,
                accountUUID: accountUUID,
                broadcaster: broadcaster,
                syncGate: gate,
                logger: logger,
                now: { clockValue.now }
            )
        }
        let host = OrchardMigrationHost(
            welding: welding,
            sharedBroadcaster: ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)),
            generalStorageURL: directory,
            tickInterval: 3600,
            now: { clockValue.now },
            logger: logger,
            actorFactory: capturingFactory
        )

        // Creating the actor registers its live gate with the host; its gate file does not exist
        // yet (nothing marked).
        _ = await host.migration(for: accountA)
        let gate = try XCTUnwrap(capturedGates.first)

        // Break persistence AFTER the gate exists: chmod the storage directory read-only so the
        // atomic write inside `markBroadcastInFlight()` fails, leaving only the in-memory cache
        // updated.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        gate.markBroadcastInFlight()

        XCTAssertNil(
            MigrationSyncGate.persistedInFlightUntil(directory: directory, accountUUID: accountA, logger: logger),
            "precondition: the gate-file write must have failed for this test to prove anything"
        )
        XCTAssertNotNil(gate.currentInFlightUntil(), "precondition: the in-memory cache carries the mark the file lost")

        let blocked = await host.isSyncBlocked()
        XCTAssertTrue(blocked, "A8: the live gate cache must win when the file write failed — blocked wins")
    }

    // MARK: - Wallet-scope syncBlockedStream

    /// Subscribe-time seed: a fresh host with nothing blocked seeds `false` on the very first
    /// (synchronous) emission, before the subscription-started ticker can schedule its first recompute.
    func testSyncBlockedStreamSeedsFalseOnSubscribe() {
        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsReturnValue = []
        let host = makeHost(welding: welding, broadcaster: ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)))

        var received: [Bool] = []
        let cancellable = host.syncBlockedStream.sink { received.append($0) }
        defer { cancellable.cancel() }

        XCTAssertEqual(received, [false])
    }

    /// Emission around a hosted actor's submit: with a subscriber already attached and the
    /// account's actor created, arming the in-flight marker is observed by the host through the
    /// account's per-account stream, which re-evaluates the wallet predicate and publishes `true`
    /// without waiting for the (long) periodic ticker — and RELEASES back to `false` as soon as the
    /// outcome is recorded, since a completed broadcast leaves no timed hold behind.
    ///
    /// A ``GatedBroadcaster`` holds the submit suspended so the in-flight window is a deterministic
    /// interval rather than a race against the record that closes it.
    func testSyncBlockedStreamEmitsTrueWhileAHostedActorsSubmitIsInFlight() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsReturnValue = [makeAccount(accountA)]
        welding.migrationTakeBroadcastTransactionIdForReturnValue = PreparedMigrationTransfer(
            id: 0,
            txid: Data(repeating: 0xAB, count: 32),
            pczt: Data([0x01, 0x02])
        )
        welding.migrationRecordTransferResultTransferIdResultForClosure = { _, _, _ in }

        // A tick far longer than the timeout, so only the marking calls (never a coincidental
        // tick) can deliver these emissions.
        let broadcaster = GatedBroadcaster(outcome: MigrationBroadcastOutcome.submitted)
        let host = makeHost(
            welding: welding,
            broadcaster: broadcaster,
            tickInterval: 3600,
            gateTickInterval: 3600
        )

        var received: [Bool] = []
        var sawBlocked = false
        let blockedEmitted = expectation(description: "wallet stream emitted true while the submit was in flight")
        let releasedEmitted = expectation(description: "wallet stream returned to false once the outcome was recorded")
        let cancellable = host.syncBlockedStream.sink { value in
            received.append(value)
            if value {
                sawBlocked = true
                blockedEmitted.fulfill()
            } else if sawBlocked {
                releasedEmitted.fulfill()
            }
        }
        defer { cancellable.cancel() }

        let migration = await host.migration(for: accountA)
        let broadcastTask = Task {
            try await migration.performBroadcast(
                MigrationBroadcastInstruction(id: 0),
                options: MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: submissionEndpoint)
            )
        }

        await broadcaster.awaitBroadcastsStarted(1)
        await fulfillment(of: [blockedEmitted], timeout: 5)
        XCTAssertEqual(received.first, false, "precondition: the fresh host seeds false")

        await broadcaster.open()
        _ = try await broadcastTask.value

        await fulfillment(of: [releasedEmitted], timeout: 5)
        XCTAssertEqual(received.last, false, "a recorded broadcast must release the gate immediately")
    }

    /// Ticker re-evaluation catching a dormant account's expiry: with only the periodic ticker (no
    /// actor ever created for the account), the stream reports `true` while the dormant account's
    /// in-flight marker is live and re-evaluates to `false` once the injected clock passes its
    /// self-expiry.
    func testSyncBlockedStreamTickerCatchesADormantAccountExpiry() async throws {
        let dormantGateD = MigrationSyncGate(
            directory: testGeneralStorageDirectory,
            accountUUID: accountD,
            tickInterval: 3600,
            now: { [clock] in clock!.now },
            logger: logger
        )
        dormantGateD.markBroadcastInFlight()

        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsReturnValue = [makeAccount(accountD)]
        let host = makeHost(
            welding: welding,
            broadcaster: ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)),
            tickInterval: 0.02
        )

        var received: [Bool] = []
        var sawBlocked = false
        let blockedByTick = expectation(description: "a tick observed the dormant account's live marker")
        let unblockedByTick = expectation(description: "a tick observed the dormant account's marker expire")
        let cancellable = host.syncBlockedStream.sink { value in
            received.append(value)
            if value {
                sawBlocked = true
                blockedByTick.fulfill()
            } else if sawBlocked {
                unblockedByTick.fulfill()
            }
        }
        defer { cancellable.cancel() }

        await fulfillment(of: [blockedByTick], timeout: 5)

        clock.now = referenceDate.addingTimeInterval(MigrationSyncGate.broadcastInFlightGuardDuration + 1)
        await fulfillment(of: [unblockedByTick], timeout: 5)
        XCTAssertEqual(received.last, false)
    }

    /// Duplicate collapse: several ticks that all agree with the already-published value produce no
    /// extra emissions — pins `.removeDuplicates()` in the wallet stream's pipeline. A counting
    /// welding proves multiple recomputes actually ran.
    func testSyncBlockedStreamCollapsesConsecutiveIdenticalTicks() async throws {
        let counter = CallCounter()
        let tickedThreeTimes = expectation(description: "the ticker re-evaluated at least three times")
        let welding = ZcashRustBackendWeldingMock()
        welding.listAccountsClosure = {
            let count = await counter.increment()
            if count == 3 {
                tickedThreeTimes.fulfill()
            }
            // No accounts: every recompute agrees with the fresh-host `false` seed.
            return []
        }
        let host = makeHost(
            welding: welding,
            broadcaster: ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)),
            tickInterval: 0.02
        )

        var received: [Bool] = []
        let cancellable = host.syncBlockedStream.sink { received.append($0) }
        defer { cancellable.cancel() }
        XCTAssertEqual(received, [false], "precondition: fresh host seeds false")

        await fulfillment(of: [tickedThreeTimes], timeout: 5)
        XCTAssertEqual(received, [false], "three ticks agreeing with the seed must not add emissions")
    }

    // MARK: - Wallet-scope chain-tip estimation (U12 hosting, U7 clock injection)

    /// `estimatedChainTip()` is wallet-scoped and lives on the host: projected from the shared
    /// blocks table's samples at the host's INJECTED clock — the deterministic arithmetic only
    /// holds if the shared tip-estimation helper received the fake `now`.
    func testEstimatedChainTipProjectsFromSamplesAtTheInjectedClock() async throws {
        let welding = ZcashRustBackendWeldingMock()
        // One sample 150 s (two 75 s fallback-spacing blocks) before the frozen clock.
        let sampleTime = referenceDate.addingTimeInterval(-150)
        welding.migrationBlockRateSamplesWindowReturnValue = [
            MigrationBlockRateSample(height: 3_000_000, unixTime: Int64(sampleTime.timeIntervalSince1970))
        ]
        let host = makeHost(welding: welding, broadcaster: ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)))

        let estimated = try await host.estimatedChainTip()

        XCTAssertEqual(estimated, 3_000_002, "height + floor(150 / 75) at the injected clock")
    }

    /// With no samples at all, `estimatedChainTip()` falls back to the max SCANNED height, and
    /// throws `migrationChainTipUnavailable` when even that is unknown.
    func testEstimatedChainTipFallsBackToScannedHeightThenThrows() async throws {
        let welding = ZcashRustBackendWeldingMock()
        welding.migrationBlockRateSamplesWindowReturnValue = []
        welding.maxScannedHeightReturnValue = 2_900_000
        let host = makeHost(welding: welding, broadcaster: ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)))

        let fallback = try await host.estimatedChainTip()
        XCTAssertEqual(fallback, 2_900_000)

        welding.maxScannedHeightClosure = { nil }
        do {
            _ = try await host.estimatedChainTip()
            XCTFail("expected migrationChainTipUnavailable")
        } catch ZcashError.migrationChainTipUnavailable {
            // expected
        } catch {
            XCTFail("expected migrationChainTipUnavailable, got \(error)")
        }
    }

    /// `estimatedSecondsPerBlock()` is the same shared projection's other half: the measured mean
    /// over the samples, with the 75 s fallback under two samples.
    func testEstimatedSecondsPerBlockMeasuresTheSamplesAndFallsBack() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let base = Int64(referenceDate.timeIntervalSince1970)
        welding.migrationBlockRateSamplesWindowReturnValue = [
            MigrationBlockRateSample(height: 3_000_000, unixTime: base),
            MigrationBlockRateSample(height: 3_000_001, unixTime: base + 60),
            MigrationBlockRateSample(height: 3_000_002, unixTime: base + 120)
        ]
        let host = makeHost(welding: welding, broadcaster: ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)))

        let measured = try await host.estimatedSecondsPerBlock()
        XCTAssertEqual(measured, 60, accuracy: 0.0001)

        welding.migrationBlockRateSamplesWindowClosure = { _ in [] }
        let fallback = try await host.estimatedSecondsPerBlock()
        XCTAssertEqual(fallback, ChainTipEstimator.fallbackSecondsPerBlock)
    }

    // MARK: - Helpers

    private func makeHost(
        welding: ZcashRustBackendWeldingMock,
        broadcaster: any MigrationBroadcasting,
        tickInterval: TimeInterval = 3600,
        gateTickInterval: TimeInterval = 3600
    ) -> OrchardMigrationHost {
        // `isSyncBlocked()`/`syncBlockedStream` unconditionally read `migrationBlockRateSamples`
        // (`ChainTipEstimator`'s raw input) while computing the wallet-scope predicate; default it
        // to "no samples" so a test that never cares about the estimate does not crash on the
        // mock's un-stubbed, implicitly-unwrapped `ReturnValue` -- a test that DOES care sets it
        // itself before calling this helper, which this guard leaves untouched.
        if welding.migrationBlockRateSamplesWindowReturnValue == nil {
            welding.migrationBlockRateSamplesWindowReturnValue = []
        }
        let clockValue = clock!
        return OrchardMigrationHost(
            welding: welding,
            sharedBroadcaster: broadcaster,
            generalStorageURL: testGeneralStorageDirectory,
            tickInterval: tickInterval,
            now: { clockValue.now },
            logger: logger,
            actorFactory: makeActorFactory(welding: welding, gateTickInterval: gateTickInterval)
        )
    }

    private func makeActorFactory(
        welding: ZcashRustBackendWeldingMock,
        gateTickInterval: TimeInterval
    ) -> (AccountUUID, any MigrationBroadcasting) -> OrchardMigration {
        let storage = testGeneralStorageDirectory!
        let clockValue = clock!
        return { accountUUID, broadcaster in
            OrchardMigration(
                welding: welding,
                accountUUID: accountUUID,
                broadcaster: broadcaster,
                syncGate: MigrationSyncGate(
                    directory: storage,
                    accountUUID: accountUUID,
                    tickInterval: gateTickInterval,
                    now: { clockValue.now },
                    logger: logger
                ),
                logger: logger
            )
        }
    }

    private func makeAccount(_ uuid: AccountUUID) -> Account {
        Account(
            id: uuid,
            name: nil,
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
            uivk: nil
        )
    }

    private func assertThrowsMigrationTorUnavailable(_ task: Task<MigrationTransferResult, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Expected migrationTorUnavailable to be thrown")
        } catch ZcashError.migrationTorUnavailable {
            // expected
        } catch {
            XCTFail("Expected migrationTorUnavailable but got \(error)")
        }
    }
}

/// A generic, non-`ZcashError` failure for stubbing a welding enumeration error in the host's
/// degrade-open path.
private struct StubHostWeldingError: Error {}

/// A minimal thread-safe call counter for pinning "the ticker actually re-evaluated N times".
private actor CallCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }
}
