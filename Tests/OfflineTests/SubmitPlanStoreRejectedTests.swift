//
//  SubmitPlanStoreRejectedTests.swift
//  ZODLSwiftWalletSDK
//

import Combine
import SQLite
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class SubmitPlanStoreRejectedTests: ZcashTestCase {
    private var databaseURL: URL!
    private var cancellables: [AnyCancellable] = []

    override func setUp() async throws {
        try await super.setUp()
        databaseURL = testGeneralStorageDirectory.appendingPathComponent("submit_plans_rejected_test.db")
        cancellables = []
    }

    override func tearDown() async throws {
        cancellables = []
        try await super.tearDown()
    }

    private func makeStore() -> SubmitPlanStore {
        SubmitPlanStore(databaseURL: databaseURL, logger: NullLogger())
    }

    private var endpointA: LightWalletEndpoint {
        LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
    }

    private let tooLarge = "exceeding the configured mempool maximum"

    func testARejectionIsRecordedAndSurvivesReopening() async {
        let txId = Data(repeating: 0x41, count: 32)
        let store = makeStore()
        await store.recordPlan(txId: txId, endpoints: [endpointA])

        await store.markRejected(txId: txId, code: -25, reason: tooLarge, lifecycle: await store.currentLifecycle())

        let plan = await store.plan(for: txId)
        XCTAssertEqual(plan, .rejected(code: -25, reason: tooLarge))
        let reopened = await makeStore().plan(for: txId)
        XCTAssertEqual(reopened, .rejected(code: -25, reason: tooLarge))
    }

    func testARejectionWithoutAPlanCreatesARejectedRow() async {
        let txId = Data(repeating: 0x42, count: 32)
        let store = makeStore()

        await store.markRejected(txId: txId, code: -26, reason: "bad", lifecycle: await store.currentLifecycle())

        let plan = await store.plan(for: txId)
        XCTAssertEqual(plan, .rejected(code: -26, reason: "bad"))
    }

    func testAnAcceptedTransactionIsNeverMarkedRejected() async {
        let txId = Data(repeating: 0x43, count: 32)
        let store = makeStore()
        await store.recordPlan(txId: txId, endpoints: [endpointA])
        await store.markAccepted(txId: txId, host: "a.example.com:443", lifecycle: await store.currentLifecycle())

        await store.markRejected(txId: txId, code: -26, reason: "bad", lifecycle: await store.currentLifecycle())

        let plan = await store.plan(for: txId)
        XCTAssertEqual(plan, .ready([endpointA], acceptedBy: "a.example.com:443"))
    }

    func testALaterAcceptanceClearsARejection() async throws {
        let txId = Data(repeating: 0x49, count: 32)
        let store = makeStore()
        await store.recordPlan(txId: txId, endpoints: [endpointA])
        await store.markRejected(txId: txId, code: -26, reason: "bad", lifecycle: await store.currentLifecycle())
        var latest: Set<Data>?
        store.rejectedTransactionIds.sink { latest = $0 }.store(in: &cancellables)

        await store.markAccepted(txId: txId, host: "a.example.com:443", lifecycle: await store.currentLifecycle())

        let plan = await store.plan(for: txId)
        XCTAssertEqual(plan, .ready([endpointA], acceptedBy: "a.example.com:443"))
        XCTAssertEqual(latest, [])
        // The rejection is gone from the row, not merely shadowed by the acceptance.
        let connection = try Connection(databaseURL.path)
        let code = try connection.scalar("SELECT rejected_code FROM tx_submit_plans") as? Int64
        XCTAssertNil(code)
    }

    func testAMigrationPreparationIsNeverRecordedAsRejected() async {
        let txId = Data(repeating: 0x4A, count: 32)
        let store = makeStore()
        await store.markMigrationPreparation(txId: txId)
        await store.recordPlan(txId: txId, endpoints: [endpointA])

        await store.markRejected(txId: txId, code: -26, reason: "bad", lifecycle: await store.currentLifecycle())

        let plan = await store.plan(for: txId)
        XCTAssertEqual(plan, .ready([endpointA], acceptedBy: nil))
        // The mark is on the plan's row, so a reopened store (after a restart) still honours it.
        let reopened = makeStore()
        let marked = await reopened.isMigrationPreparation(txId: txId)
        XCTAssertTrue(marked)
        await reopened.markRejected(txId: txId, code: -26, reason: "bad", lifecycle: await reopened.currentLifecycle())
        let reread = await reopened.plan(for: txId)
        XCTAssertEqual(reread, .ready([endpointA], acceptedBy: nil))
    }

    /// A migration mark set before the transaction has a plan, or even exists (a PCZT's id is
    /// known when it is created), is persisted at once and holds across a restart.
    func testAMigrationMarkWithoutAPlanSurvivesARestart() async {
        let txId = Data(repeating: 0x4B, count: 32)
        await makeStore().markMigrationPreparation(txId: txId)

        let reopened = makeStore()
        let marked = await reopened.isMigrationPreparation(txId: txId)
        XCTAssertTrue(marked)
        let unplanned = await reopened.plan(for: txId)
        XCTAssertNil(unplanned, "the mark does not create a plan")

        await reopened.recordPlan(txId: txId, endpoints: [endpointA])
        await reopened.markRejected(txId: txId, code: -26, reason: "bad-txns-vin-empty", lifecycle: await reopened.currentLifecycle())
        let plan = await reopened.plan(for: txId)
        XCTAssertEqual(plan, .ready([endpointA], acceptedBy: nil))
    }

    func testPruningAPlanRemovesItsMigrationMark() async {
        let txId = Data(repeating: 0x4C, count: 32)
        let store = makeStore()
        await store.markMigrationPreparation(txId: txId)
        await store.recordPlan(txId: txId, endpoints: [endpointA])

        await store.deletePlans(txIds: [txId])

        let marked = await makeStore().isMigrationPreparation(txId: txId)
        XCTAssertFalse(marked)
    }

    func testARejectionFromAWipedLifecycleIsDropped() async {
        let txId = Data(repeating: 0x44, count: 32)
        let store = makeStore()
        let stale = await store.currentLifecycle()
        await store.wipe()

        await store.markRejected(txId: txId, code: -26, reason: "bad", lifecycle: stale)

        let plan = await store.plan(for: txId)
        XCTAssertNil(plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path), "A stale write must not recreate the store")
    }

    func testRejectedIdsArePublishedAndLeaveWhenPruned() async {
        let rejected = Data(repeating: 0x45, count: 32)
        let other = Data(repeating: 0x46, count: 32)
        let store = makeStore()
        await store.recordPlan(txId: other, endpoints: [endpointA])
        await store.markRejected(txId: rejected, code: -26, reason: "bad", lifecycle: await store.currentLifecycle())

        let seeded = expectation(description: "seeded from the database on subscription")
        var values: [Set<Data>] = []
        store.rejectedTransactionIds
            .sink { value in
                values.append(value)
                if value == [rejected] { seeded.fulfill() }
            }
            .store(in: &cancellables)
        await fulfillment(of: [seeded], timeout: 2)

        await store.deletePlans(txIds: [rejected])
        XCTAssertEqual(values.last, [])
    }

    func testAWipeEmptiesTheRejectedIds() async {
        let txId = Data(repeating: 0x47, count: 32)
        let store = makeStore()
        await store.markRejected(txId: txId, code: -26, reason: "bad", lifecycle: await store.currentLifecycle())
        var latest: Set<Data>?
        store.rejectedTransactionIds.sink { latest = $0 }.store(in: &cancellables)

        await store.wipe()

        XCTAssertEqual(latest, [])
    }

    func testAStoreWrittenWithoutTheRejectionColumnsGainsThemOnOpen() async throws {
        let txId = Data(repeating: 0x48, count: 32)
        let connection = try Connection(databaseURL.path)
        try connection.run(
            """
            CREATE TABLE "tx_submit_plans" ("tx_id" BLOB PRIMARY KEY NOT NULL, "endpoints" TEXT DEFAULT ('[]'), "accepted_host" TEXT)
            """
        )
        try connection.run("PRAGMA user_version = 1")
        try connection.run("INSERT INTO tx_submit_plans (tx_id, endpoints) VALUES (?, '[]')", [Blob(bytes: txId.bytes)])

        let store = makeStore()
        let before = await store.plan(for: txId)
        XCTAssertEqual(before, .awaiting)
        await store.markRejected(txId: txId, code: -26, reason: "bad", lifecycle: await store.currentLifecycle())
        let after = await store.plan(for: txId)
        XCTAssertEqual(after, .rejected(code: -26, reason: "bad"))

        let version = try connection.scalar("PRAGMA user_version") as? Int64
        XCTAssertEqual(version, 1, "The columns are additive, so older SDK builds keep reading the store")
    }
}
