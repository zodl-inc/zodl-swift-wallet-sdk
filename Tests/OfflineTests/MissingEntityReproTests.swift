//
//  MissingEntityReproTests.swift
//  ZODLSwiftWalletSDK
//
//  Reproduces the `-3000 [ZTREE0001] transactionRepositoryEntityNotFound` reported from the
//  field after shielding and cross-pay sends.
//
//  The error is raised by `TransactionSQLDAO.execute(_:createEntity:)` when a single-entity
//  query over `v_transactions` returns no rows. That view is built FROM the union of received
//  outputs and spends of received outputs; `sent_notes` reaches it only through a LEFT JOIN and
//  so can never produce a row on its own. A transaction the wallet created therefore appears in
//  history only if at least one of its inputs was already recorded, or it has a wallet-internal
//  shielded output (change or self-send).
//
//  A shielding or cross-pay send normally has both halves: recorded input spends and a
//  wallet-internal change output. The field failure means neither was recorded for the affected
//  wallets — which write went missing is an open librustzcash question. These tests pin the
//  resulting behaviour rather than its upstream cause: a transaction in that state is fully
//  present in `transactions`, and invisible through the view.
//

import SQLite
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class MissingEntityReproTests: XCTestCase {
    /// Distinct from anything in the fixture, so a hit can only be the row inserted here.
    private static let orphanTxId = Data(repeating: 0x5A, count: 32)

    /// The serialized transaction and heights copied onto the orphan row, taken from a real
    /// fixture transaction. Recorded by `insertTransactionWithoutNotes` so the assertions can
    /// compare against what was actually stored.
    private struct Orphan {
        let txId: Data
        let raw: Data
        let expiryHeight: BlockHeight?
    }

    private var dbHandle: TestDbHandle!
    private var provider: SimpleConnectionProvider!
    private var transactionRepository: TransactionSQLDAO!
    private var rustBackend: ZcashRustBackend!

    override func setUp() async throws {
        try await super.setUp()

        // Work on a writable copy so the bundled fixture is never mutated.
        dbHandle = TestDbHandle(originalDb: TestDbBuilder.prePopulatedMainnetDataDbURL()!)
        try dbHandle.setUp()

        // Migrate the copy so the assertions run against the real `v_transactions` shipped by
        // the pinned librustzcash rather than a hand-written stand-in. The view's SQL is the
        // subject of the test, so substituting a same-shaped table would prove nothing.
        rustBackend = ZcashRustBackend.makeForTests(
            dbData: dbHandle.readWriteDb,
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .mainnet
        )
        switch try await rustBackend.initDataDb(seed: Environment.seedBytes) {
        case .success, .seedNotRelevant:
            break
        case .seedRequired:
            XCTFail("the fixture seed must be accepted, otherwise the schema is not migrated")
        }

        // `Connection` takes a POSIX path, so `.path` and never `.absoluteString`: a `file://`
        // URL is opened as a literal relative filename unless SQLITE_OPEN_URI is set, which it
        // is not.
        provider = SimpleConnectionProvider(path: dbHandle.readWriteDb.path, readonly: false)
        transactionRepository = TransactionSQLDAO(dbProvider: provider)
    }

    override func tearDown() async throws {
        provider?.close()
        provider = nil
        transactionRepository = nil
        rustBackend = nil
        dbHandle?.dispose()
        dbHandle = nil
        try await super.tearDown()
    }

    /// Inserts a transaction carrying no received-output and no spend row, which is the state
    /// `store_transaction_to_be_sent` leaves behind when no input matched and the transaction has
    /// no change output.
    ///
    /// `transactions` requires only `txid` and `min_observed_height`; everything the send path
    /// reads (`raw`, `expiry_height`) is nullable, and the table's three CHECK constraints are all
    /// vacuous while `block`, `mined_height` and `confirmed_unmined_at_height` are NULL. No
    /// account row, no `sent_notes` row and no foreign key is involved, because `sent_notes`
    /// contributes only counts through a LEFT JOIN and cannot affect whether the row exists.
    /// The serialized bytes and heights are copied from a real fixture transaction rather than
    /// fabricated, because `zcashlc_get_transaction` parses the stored `raw` column and re-encodes
    /// it; fabricated bytes exercise the parse-failure path instead of the readback. The heights
    /// come with them, since the consensus branch used to parse is derived from them.
    ///
    /// The row's `txid` is deliberately NOT the hash of the copied `raw` bytes. The view never
    /// parses `raw` and matches on the column alone, so the mismatch is invisible to every
    /// view-side assertion. The readback, by contrast, derives the txid from the transaction it
    /// parsed and rejects the mismatch — which is why the readback tests use
    /// `stripNotesRows()` (a real transaction made view-invisible) and this helper doubles as
    /// the fixture for the integrity-guard test.
    ///
    /// - Parameter mined: when `false`, `mined_height` is left NULL, mirroring the field state of a
    ///   freshly created transaction that has not been mined. Pass `false` only for assertions
    ///   about the view: with no mined height the consensus branch used by the readback has to come
    ///   from `expiry_height`, which the fixture does not guarantee is set.
    @discardableResult
    private func insertTransactionWithoutNotes(mined: Bool = true) throws -> Orphan {
        let connection = try provider.connection()

        var raw: Data?
        var expiryHeight: Int64?
        var minedHeight: Int64?
        for row in try connection.prepare(
            "SELECT raw, expiry_height, mined_height FROM transactions WHERE raw IS NOT NULL LIMIT 1"
        ) {
            raw = (row[0] as? Blob).map { Data(blob: $0) }
            expiryHeight = row[1] as? Int64
            minedHeight = row[2] as? Int64
        }

        let sourceRaw = try XCTUnwrap(raw, "the fixture must hold at least one serialized transaction")

        try connection.run(
            """
            INSERT INTO transactions (txid, raw, expiry_height, mined_height, min_observed_height)
            VALUES (?, ?, ?, ?, ?)
            """,
            Blob(bytes: [UInt8](Self.orphanTxId)),
            Blob(bytes: [UInt8](sourceRaw)),
            expiryHeight,
            mined ? minedHeight : nil,
            mined ? (minedHeight ?? 1) : 1
        )

        return Orphan(
            txId: Self.orphanTxId,
            raw: sourceRaw,
            expiryHeight: expiryHeight.map { BlockHeight($0) }
        )
    }

    /// Makes a REAL fixture transaction view-invisible by deleting the notes rows that connect it
    /// to the wallet: every received output it created and every spend row it contributed. The
    /// `transactions` row itself — txid, raw bytes, heights — is untouched, so `txid` still equals
    /// the hash of `raw`, exactly as for a wallet-created transaction whose bookkeeping writes
    /// went missing. This is the honest fixture for the readback tests: the readback parses the
    /// stored bytes and verifies the derived txid against the requested one, which a fabricated
    /// txid cannot survive.
    private func stripNotesRows() throws -> Orphan {
        let connection = try provider.connection()

        var idTx: Int64?
        var txId: Data?
        var raw: Data?
        var expiryHeight: Int64?
        for row in try connection.prepare(
            "SELECT id_tx, txid, raw, expiry_height FROM transactions WHERE raw IS NOT NULL LIMIT 1"
        ) {
            idTx = row[0] as? Int64
            txId = (row[1] as? Blob).map { Data(blob: $0) }
            raw = (row[2] as? Blob).map { Data(blob: $0) }
            expiryHeight = row[3] as? Int64
        }

        let donorId = try XCTUnwrap(idTx, "the fixture must hold at least one serialized transaction")
        let donorTxId = try XCTUnwrap(txId)
        let donorRaw = try XCTUnwrap(raw)

        // Received outputs this transaction created (deleting the notes cascades their spend rows),
        // and spend rows this transaction contributed against other transactions' outputs.
        for table in [
            "sapling_received_notes", "orchard_received_notes", "ironwood_received_notes",
            "transparent_received_outputs",
            "sapling_received_note_spends", "orchard_received_note_spends",
            "ironwood_received_note_spends", "transparent_received_output_spends"
        ] {
            try connection.run("DELETE FROM \(table) WHERE transaction_id = ?", donorId)
        }

        return Orphan(
            txId: donorTxId,
            raw: donorRaw,
            expiryHeight: expiryHeight.map { BlockHeight($0) }
        )
    }

    /// The reproduction. A transaction with no `notes` rows is dropped by `v_transactions`, and
    /// the lookup the send path performs raises the error the app reports.
    ///
    /// The fixture lookup is a positive control and is load-bearing: without it this test would
    /// also pass against an empty database, for the unrelated reason that nothing is there. Run
    /// against the same database, the two halves show the discrimination rather than an absence.
    func testTransactionWithoutNotesRowsIsInvisibleInVTransactions() async throws {
        let fixtureTransactions = try await transactionRepository.find(offset: 0, limit: 1, kind: .all)
        let control = try XCTUnwrap(
            fixtureTransactions.first,
            "the fixture must hold at least one transaction for the positive control to mean anything"
        )
        _ = try await transactionRepository.find(rawID: control.rawID)

        let orphan = try insertTransactionWithoutNotes()

        do {
            let found = try await transactionRepository.find(rawID: orphan.txId)
            XCTFail(
                "v_transactions returned \(found.rawID.toHexStringTxId()) for a transaction with "
                + "no received-output and no spend row"
            )
        } catch ZcashError.transactionRepositoryEntityNotFound {
            // Reproduced: this is the -3000 / ZTREE0001 surfaced to the app.
        }
    }

    /// The same result for an UNMINED transaction, which is the field state: the row is created by
    /// the send path and the failure happens before it is ever broadcast, let alone mined.
    ///
    /// The mined variant above is what the fixture hands us for free, and the view's join does not
    /// consult `mined_height`, so the two agree. Pinning both means a future change that starts
    /// filtering the view on mined height cannot quietly turn the reproduction into a
    /// mined-only curiosity.
    func testTheViewAlsoDropsAnUnminedTransactionWithoutNotesRows() async throws {
        let orphan = try insertTransactionWithoutNotes(mined: false)

        let connection = try provider.connection()
        let storedMinedHeight = try connection.scalar(
            "SELECT mined_height FROM transactions WHERE txid = ?",
            Blob(bytes: [UInt8](orphan.txId))
        )
        XCTAssertNil(storedMinedHeight, "the row must be unmined for this to mirror the field state")

        do {
            _ = try await transactionRepository.find(rawID: orphan.txId)
            XCTFail("v_transactions must drop an unmined transaction with no notes rows too")
        } catch ZcashError.transactionRepositoryEntityNotFound {
            // Reproduced, in the state the field actually reports.
        }
    }

    /// The same transaction is fully present in `transactions`, including the raw bytes and
    /// expiry height. Only the history projection drops it.
    ///
    /// This is what makes the transaction submittable in principle: `CreatedTransaction` carries
    /// exactly `txId`, `raw` and `expiryHeight`, so the send path never needed `v_transactions`.
    func testTheSameTransactionIsFullyPresentInTheTransactionsTable() async throws {
        let orphan = try insertTransactionWithoutNotes()
        let connection = try provider.connection()
        let txIdBlob = Blob(bytes: [UInt8](orphan.txId))

        let count = try connection.scalar(
            "SELECT COUNT(*) FROM transactions WHERE txid = ?",
            txIdBlob
        ) as? Int64
        XCTAssertEqual(count, 1, "the transaction the view dropped is stored")

        let raw = try connection.scalar("SELECT raw FROM transactions WHERE txid = ?", txIdBlob) as? Blob
        XCTAssertEqual(
            raw.map { Data(blob: $0) },
            orphan.raw,
            "the serialized transaction needed for submission is readable"
        )
    }

    /// Pins the mechanism rather than the symptom: the row is missing because neither half of the
    /// `notes` union matches it. If a future change makes `v_transactions` total over
    /// wallet-created transactions, this test states precisely which precondition changed.
    func testTheDroppedTransactionHasNeitherReceivedOutputsNorSpends() async throws {
        let orphan = try insertTransactionWithoutNotes()
        let connection = try provider.connection()
        let txIdBlob = Blob(bytes: [UInt8](orphan.txId))

        let idTx = try XCTUnwrap(
            try connection.scalar("SELECT id_tx FROM transactions WHERE txid = ?", txIdBlob) as? Int64
        )

        let receivedOutputs = try connection.scalar(
            "SELECT COUNT(*) FROM v_received_outputs WHERE transaction_id = ?",
            idTx
        ) as? Int64
        XCTAssertEqual(receivedOutputs, 0, "no wallet-internal output, as in a no-change send")

        let spends = try connection.scalar(
            "SELECT COUNT(*) FROM v_received_output_spends WHERE transaction_id = ?",
            idTx
        ) as? Int64
        XCTAssertEqual(spends, 0, "no input matched a recorded output")
    }

    // MARK: - The other side of the rule: what makes the view KEEP a transaction

    /// A transaction whose only connection to the wallet is a SPEND of a previously received note
    /// is visible. This is the positive half of the rule the tests above probe from one side: the
    /// `notes` union has two arms, and either one alone suffices.
    ///
    /// It is also a recovery path for the reported failure. A no-change send has no wallet-internal
    /// output, so this arm is the only thing that can make it visible, and one matched input is all
    /// it takes. If this ever stops holding, every such transaction disappears from history.
    ///
    /// Uses a note already in the fixture, so nothing here depends on hand-built note columns.
    func testATransactionVisibleOnlyThroughASpendOfAnExistingNote() async throws {
        let connection = try provider.connection()

        var noteId: Int64?
        for row in try connection.prepare("SELECT id FROM sapling_received_notes LIMIT 1") {
            noteId = row[0] as? Int64
        }
        let spentNoteId = try XCTUnwrap(noteId, "the fixture must hold at least one Sapling note")

        let spendOnlyTxId = Data(repeating: 0x77, count: 32)
        try connection.run(
            "INSERT INTO transactions (txid, min_observed_height) VALUES (?, ?)",
            Blob(bytes: [UInt8](spendOnlyTxId)),
            1
        )
        let idTx = try XCTUnwrap(
            try connection.scalar(
                "SELECT id_tx FROM transactions WHERE txid = ?",
                Blob(bytes: [UInt8](spendOnlyTxId))
            ) as? Int64
        )
        try connection.run(
            """
            INSERT INTO sapling_received_note_spends (sapling_received_note_id, transaction_id)
            VALUES (?, ?)
            """,
            spentNoteId,
            idTx
        )

        // No received output of its own, and no `sent_notes` row.
        let received = try connection.scalar(
            "SELECT COUNT(*) FROM v_received_outputs WHERE transaction_id = ?",
            idTx
        ) as? Int64
        XCTAssertEqual(received, 0, "the spend arm alone must be carrying this row")

        let found = try await transactionRepository.find(rawID: spendOnlyTxId)
        XCTAssertEqual(found.rawID, spendOnlyTxId, "one matched input is enough to be visible")
    }

    /// The same, for a transaction visible only through an Ironwood output it RECEIVED.
    ///
    /// Ironwood (pool code 4) is the newest arm of `v_received_outputs`, added separately from the
    /// Sapling and Orchard arms, and it is the pool migrated funds land in. If a schema change ever
    /// drops that arm, migrated notes vanish from history and every send that spends them
    /// reproduces the original bug. The other tests here would all still pass.
    func testATransactionVisibleOnlyThroughAReceivedIronwoodOutput() async throws {
        let connection = try provider.connection()

        let accountId = try XCTUnwrap(
            try connection.scalar("SELECT id FROM accounts LIMIT 1") as? Int64,
            "the fixture must hold an account"
        )

        let ironwoodTxId = Data(repeating: 0x66, count: 32)
        try connection.run(
            "INSERT INTO transactions (txid, min_observed_height) VALUES (?, ?)",
            Blob(bytes: [UInt8](ironwoodTxId)),
            1
        )
        let idTx = try XCTUnwrap(
            try connection.scalar(
                "SELECT id_tx FROM transactions WHERE txid = ?",
                Blob(bytes: [UInt8](ironwoodTxId))
            ) as? Int64
        )

        // The view does not interpret the note payload, so the cryptographic fields only need to
        // satisfy NOT NULL and the uniqueness constraints. `note_version` 3 is ZIP 2005.
        try connection.run(
            """
            INSERT INTO ironwood_received_notes (
                transaction_id, action_index, account_id, diversifier, value,
                rho, rseed, nf, is_change, note_version
            ) VALUES (?, 0, ?, ?, 100000, ?, ?, ?, 0, 3)
            """,
            idTx,
            accountId,
            Blob(bytes: [UInt8](repeating: 0x01, count: 11)),
            Blob(bytes: [UInt8](repeating: 0x02, count: 32)),
            Blob(bytes: [UInt8](repeating: 0x03, count: 32)),
            Blob(bytes: [UInt8](repeating: 0x04, count: 32))
        )

        let pool = try connection.scalar(
            "SELECT pool FROM v_received_outputs WHERE transaction_id = ?",
            idTx
        ) as? Int64
        XCTAssertEqual(pool, 4, "the Ironwood arm must tag its outputs with pool code 4")

        let found = try await transactionRepository.find(rawID: ironwoodTxId)
        XCTAssertEqual(found.rawID, ironwoodTxId, "a received Ironwood output alone makes it visible")
    }

    /// The fix. What `v_transactions` drops, `zcashlc_get_transaction` returns.
    ///
    /// Both halves run against the same database, so this is direct evidence that the readback
    /// recovers exactly the transaction the history projection loses, rather than the send path
    /// merely tolerating the loss. The view is deliberately re-checked here: the fix must not
    /// change what history shows, only where the broadcast path reads from.
    ///
    /// Uses a real fixture transaction stripped of its notes rows, so the txid the readback
    /// derives from the parsed bytes matches the stored one — the txid equality below is a
    /// genuine round-trip check, not an echo.
    func testGetTransactionReturnsTheRowTheHistoryViewDrops() async throws {
        let orphan = try stripNotesRows()

        do {
            _ = try await transactionRepository.find(rawID: orphan.txId)
            XCTFail("the history view must still drop the row; the fix changes the reader, not the view")
        } catch ZcashError.transactionRepositoryEntityNotFound {
            // Unchanged, as intended.
        }

        let stored = try await rustBackend.getTransaction(txId: orphan.txId)
        let transaction = try XCTUnwrap(stored, "the wallet store holds the transaction the view drops")

        XCTAssertEqual(transaction.txId, orphan.txId)
        XCTAssertEqual(
            transaction.raw,
            orphan.raw,
            "the broadcast bytes must equal the stored bytes: the readback parses and re-encodes "
            + "the row, so any divergence here would broadcast a different transaction than the "
            + "one the wallet recorded"
        )
    }

    /// The readback refuses to hand back bytes that are not the transaction they are filed under:
    /// a row whose `raw` parses to a different txid than its `txid` column is rejected rather than
    /// returned. This pins the integrity guard on the parsed-txid round trip — the property that
    /// re-encoding the parsed transaction could otherwise silently violate.
    func testGetTransactionRejectsARowWhoseBytesHashToADifferentTxId() async throws {
        let orphan = try insertTransactionWithoutNotes()

        do {
            _ = try await rustBackend.getTransaction(txId: orphan.txId)
            XCTFail("bytes filed under a foreign txid must be rejected, not broadcast")
        } catch ZcashError.rustGetTransaction {
            // Rejected, as intended: broadcasting these bytes would send a different
            // transaction than the one the caller asked for.
        }
    }

    /// A txid the wallet has never stored is reported as absent rather than as an error, so the
    /// caller can tell "not stored" from "lookup failed".
    func testGetTransactionReturnsNilForAnUnknownTxId() async throws {
        let unknown = Data(repeating: 0x11, count: 32)

        let stored = try await rustBackend.getTransaction(txId: unknown)

        XCTAssertNil(stored)
    }
}
