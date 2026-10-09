//
//  DBActorIsolationTests.swift
//  OfflineTests
//
//  Pins the read/write split's one invariant that type-checking cannot: a read-only call
//  completes while `DBActor` is HELD. If someone re-adds `@DBActor` to a converted read, the
//  read queues behind the held actor and the expectation below times out — a deterministic
//  failure, not a flake. The holder BLOCKS ITS THREAD inside the actor on a semaphore the
//  test controls. The block being synchronous is the point: an `await` inside the actor is a
//  suspension point that RELEASES the actor (reentrancy, SE-0306) and would hold nothing.
//
//  Four conversion areas are pinned, one test per converted call: the migration family
//  (blockRateSamples); the migration UI/gate reads reclassified 2026-08-05 — migrationSyncWakeups,
//  migrationProgress, migrationTransactionStatuses, migrationHasOverdueTransfers,
//  migrationHasInvalidTransfers — pinned individually so a re-add on any single one of the five
//  fails on its own, not just as a group; the turnstile proposal
//  (proposeOrchardToIronwoodMigration, which needs the account fixture); and the wallet getters
//  (maxScannedHeight). The DAO conversions are exercised transitively by the rest of OfflineTests.
//

import XCTest
import libzcashlc
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class DBActorIsolationTests: XCTestCase {
    var dbData: URL!
    var rustBackend: ZcashRustBackendWelding!
    var account: AccountUUID!

    override func setUp() async throws {
        try await super.setUp()

        dbData = try __dataDbURL()
        rustBackend = ZcashRustBackend.makeForTests(
            dbData: dbData,
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .testnet
        )

        let dbInit = try await rustBackend.initDataDb(seed: nil)
        guard case .success = dbInit else {
            XCTFail("Failed to initDataDb. Expected `.success`, got \(String(describing: dbInit))")
            return
        }

        let checkpointSource = CheckpointSourceFactory.fromBundle(for: .testnet)
        let treeState = checkpointSource.latestKnownCheckpoint().treeState()
        _ = try await rustBackend.createAccount(
            seed: Environment.seedBytes,
            treeState: treeState,
            recoverUntil: nil,
            name: "",
            keySource: nil
        )
        let accounts = try await rustBackend.listAccounts()
        account = try XCTUnwrap(accounts.first?.id)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: dbData!)
        rustBackend = nil
        account = nil
    }

    func testBlockRateSamplesReadCompletesWhileDBActorIsHeld() async throws {
        let backend = rustBackend!
        await assertCompletesWhileDBActorIsHeld("migrationBlockRateSamples completed while actor held") {
            _ = try? await backend.migrationBlockRateSamples(window: 100)
        }
    }

    func testSyncWakeupsReadCompletesWhileDBActorIsHeld() async throws {
        let backend = rustBackend!
        let accountUUID = account!
        await assertCompletesWhileDBActorIsHeld("migrationSyncWakeups completed while actor held") {
            _ = try? await backend.migrationSyncWakeups(for: accountUUID)
        }
    }

    func testProgressReadCompletesWhileDBActorIsHeld() async throws {
        let backend = rustBackend!
        let accountUUID = account!
        await assertCompletesWhileDBActorIsHeld("migrationProgress completed while actor held") {
            _ = try? await backend.migrationProgress(for: accountUUID)
        }
    }

    func testTransactionStatusesReadCompletesWhileDBActorIsHeld() async throws {
        let backend = rustBackend!
        let accountUUID = account!
        await assertCompletesWhileDBActorIsHeld("migrationTransactionStatuses completed while actor held") {
            _ = try? await backend.migrationTransactionStatuses(for: accountUUID)
        }
    }

    func testHasOverdueTransfersReadCompletesWhileDBActorIsHeld() async throws {
        let backend = rustBackend!
        let accountUUID = account!
        await assertCompletesWhileDBActorIsHeld("migrationHasOverdueTransfers completed while actor held") {
            _ = try? await backend.migrationHasOverdueTransfers(for: accountUUID, estimatedTip: nil)
        }
    }

    func testHasInvalidTransfersReadCompletesWhileDBActorIsHeld() async throws {
        let backend = rustBackend!
        let accountUUID = account!
        await assertCompletesWhileDBActorIsHeld("migrationHasInvalidTransfers completed while actor held") {
            _ = try? await backend.migrationHasInvalidTransfers(for: accountUUID)
        }
    }

    func testProposeMigrationReadCompletesWhileDBActorIsHeld() async throws {
        let backend = rustBackend!
        let accountUUID = account!
        await assertCompletesWhileDBActorIsHeld("proposeOrchardToIronwoodMigration completed while actor held") {
            // An empty fixture wallet has nothing to propose — throwing IS completing here;
            // what the assertion needs is that the call RAN while the actor was parked.
            _ = try? await backend.proposeOrchardToIronwoodMigration(accountUUID: accountUUID)
        }
    }

    func testMaxScannedHeightReadCompletesWhileDBActorIsHeld() async throws {
        let backend = rustBackend!
        await assertCompletesWhileDBActorIsHeld("maxScannedHeight completed while actor held") {
            _ = try? await backend.maxScannedHeight()
        }
    }

    /// Occupies `DBActor` with a synchronous thread-block (no suspension point — an `await`
    /// would release the actor via reentrancy), runs `read`, and requires it to complete
    /// while the actor is still blocked. Releases the holder afterwards regardless.
    private func assertCompletesWhileDBActorIsHeld(
        _ description: String,
        read: @escaping @Sendable () async -> Void
    ) async {
        let entered = XCTestExpectation(description: "holder entered DBActor")
        let release = DispatchSemaphore(value: 0)
        let holder = Task { @DBActor in
            entered.fulfill()
            release.wait()
        }
        await fulfillment(of: [entered], timeout: 5.0)

        let readCompleted = XCTestExpectation(description: description)
        let reader = Task {
            await read()
            readCompleted.fulfill()
        }

        await fulfillment(of: [readCompleted], timeout: 5.0)

        release.signal()
        _ = await holder.value
        _ = await reader.value
    }
}
