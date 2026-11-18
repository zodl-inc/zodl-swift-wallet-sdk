//
//  MigrationResubmissionExclusionTests.swift
//  ZODLSwiftWalletSDK
//
//  `TransactionSQLDAO.findForResubmission(upTo:)` must never return a ZIP 318 migration
//  transaction: the generic retry would resend it over the app-wide Tor setting, so with migration
//  Tor on and app-wide Tor off it would go directly to a lightwalletd that already saw it over Tor.
//

import XCTest
import SQLite
@testable import ZODLSwiftWalletSDK

final class MigrationResubmissionExclusionTests: XCTestCase {
    private let plainSend = Data(repeating: 0x01, count: 32)
    private let classifiedTransfer = Data(repeating: 0x02, count: 32)
    private let preparation = Data(repeating: 0x03, count: 32)
    private let unclassifiedScheduled = Data(repeating: 0x04, count: 32)
    private let crossingPaymentToOthers = Data(repeating: 0x05, count: 32)

    private func tempDBPath() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("migration-resubmit-\(UUID().uuidString).db")
    }

    /// A same-shaped table stands in for the `v_transactions` view: the DAO reads it by name.
    private func makeWallet(withMigrationTable: Bool) throws -> String {
        let path = tempDBPath()
        let setup = try Connection(path)
        try setup.run(
            """
            CREATE TABLE v_transactions (
                account_uuid BLOB, mined_height INTEGER, tx_index INTEGER, txid BLOB, expiry_height INTEGER,
                raw BLOB, account_balance_delta INTEGER, fee_paid INTEGER, has_change INTEGER,
                sent_note_count INTEGER, received_note_count INTEGER, is_shielding INTEGER, memo_count INTEGER,
                block_time INTEGER, expired_unmined INTEGER, total_spent INTEGER, total_received INTEGER,
                spent_note_count INTEGER, pool_crossing_value INTEGER, trust_status INTEGER, zip318_kind INTEGER
            )
            """
        )
        let rows: [(Data, Int64, Int64?, Int)] = [
            (plainSend, -10_000, nil, 1),
            (classifiedTransfer, -15_000, 1_000_000, 3),
            (preparation, -10_000, nil, 2),
            (unclassifiedScheduled, -15_000, nil, 0),
            (crossingPaymentToOthers, -1_015_000, nil, 3)
        ]
        for (txid, delta, crossing, kind) in rows {
            try setup.run(
                """
                INSERT INTO v_transactions VALUES (?, NULL, NULL, ?, 100, x'00', ?, 10000, 0,
                                                   1, 0, 0, 0, NULL, 0, NULL, NULL, 1, ?, NULL, ?)
                """,
                Blob(bytes: [UInt8](Data(repeating: 0xAA, count: 16))),
                Blob(bytes: [UInt8](txid)),
                delta,
                crossing,
                kind
            )
        }
        if withMigrationTable {
            try setup.run("CREATE TABLE orchard_ironwood_migration_transactions (txid BLOB)")
            for txid in [classifiedTransfer, unclassifiedScheduled] {
                try setup.run("INSERT INTO orchard_ironwood_migration_transactions VALUES (?)", Blob(bytes: [UInt8](txid)))
            }
        }
        return path
    }

    private func candidates(_ path: String) async throws -> Set<Data> {
        let dao = TransactionSQLDAO(dbProvider: SimpleConnectionProvider(path: path, readonly: true))
        return Set(try await dao.findForResubmission(upTo: 50).map(\.rawID))
    }

    func testMigrationTransactionsAreNeverResubmissionCandidates() async throws {
        let result = try await candidates(try makeWallet(withMigrationTable: true))

        XCTAssertEqual(result, [plainSend, crossingPaymentToOthers])
    }

    func testClassificationAloneStillExcludesClassifiedMigrationTransactions() async throws {
        let result = try await candidates(try makeWallet(withMigrationTable: false))

        XCTAssertEqual(result, [plainSend, unclassifiedScheduled, crossingPaymentToOthers])
    }
}
