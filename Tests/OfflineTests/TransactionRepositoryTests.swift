//
//  TransactionRepositoryTests.swift
//  ZcashLightClientKit-Unit-Tests
//
//  Created by Francisco Gindre on 11/16/19.
//

import SQLite
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

class TransactionRepositoryTests: XCTestCase {
    enum TestError: Error {
        case fixtureHasNoSentNotes
    }

    func testZIP318KindDecodesEveryKnownClassification() {
        XCTAssertEqual(ZcashTransaction.Overview.ZIP318Kind(rawValue: 0), .notClassified)
        XCTAssertEqual(ZcashTransaction.Overview.ZIP318Kind(rawValue: 1), .nonconforming)
        XCTAssertEqual(ZcashTransaction.Overview.ZIP318Kind(rawValue: 2), .preparation)
        XCTAssertEqual(ZcashTransaction.Overview.ZIP318Kind(rawValue: 3), .transfer)
        XCTAssertEqual(ZcashTransaction.Overview.ZIP318Kind(rawValue: 4), .canonicalCrossingPayment)
        XCTAssertEqual(ZcashTransaction.Overview.ZIP318Kind(rawValue: 5), .notClassified)
    }

    var transactionRepository: TransactionRepository!

    override func setUp() async throws {
        try await super.setUp()
        let rustBackend = ZcashRustBackend.makeForTests(
            dbData: TestDbBuilder.prePopulatedMainnetDataDbURL()!,
            fsBlockDbRoot: Environment.uniqueTestTempDirectory,
            networkType: .mainnet
        )
        transactionRepository = try! await TestDbBuilder.transactionRepository(rustBackend: rustBackend)
    }

    override func tearDown() {
        super.tearDown()
        transactionRepository = nil
    }

    func testCount() async throws {
        let count = try await self.transactionRepository.countAll()
        XCTAssertNotNil(count)
        XCTAssertEqual(count, 21)
    }

    func testCountUnmined() async throws {
        let count = try await self.transactionRepository.countUnmined()
        XCTAssertNotNil(count)
        XCTAssertEqual(count, 0)
    }

    /// Regression (2026-08-04, field): every row of a real wallet decodes through `v_transactions`
    /// even though its stored `trust_status` is NULL — which it IS on every wallet today, because
    /// `set_tx_trust` is an opt-in API nothing calls yet and the column ships without a default or
    /// backfill. A strict non-optional decode threw on the FIRST row, the whole fetch failed, and
    /// the app rendered an empty transaction list over a fully-populated wallet.
    ///
    /// This is also the suite's only live test that decodes an `Overview` from the real migrated
    /// schema (the `_testFind…` family above is disabled, #1518): if a future migration adds
    /// another nullable column to the view that the decode reads strictly, this is what fails.
    func testFindAllDecodesRowsWhoseStoredTrustStatusIsNull() async throws {
        let transactions = try await self.transactionRepository.find(offset: 0, limit: Int.max, kind: .all)

        XCTAssertEqual(transactions.count, 21, "every fixture row must decode — one NULL must never empty the list")
        transactions.forEach {
            XCTAssertFalse($0.isTrusted, "an unevaluated (NULL) trust_status reads as untrusted, matching IFNULL(trust_status, 0)")
        }
    }

    // TODO: [#1518] Fix the test, https://github.com/Electric-Coin-Company/zcash-swift-wallet-sdk/issues/1518
    func _testFindInRange() async throws {
        let transactions = try await self.transactionRepository.find(in: 663218...663974, limit: 3, kind: .received)
        XCTAssertEqual(transactions.count, 3)
        XCTAssertEqual(transactions[0].minedHeight, 663974)
        XCTAssertEqual(transactions[0].isSentTransaction, false)
        XCTAssertEqual(transactions[1].minedHeight, 663953)
        XCTAssertEqual(transactions[1].isSentTransaction, false)
        XCTAssertEqual(transactions[2].minedHeight, 663229)
        XCTAssertEqual(transactions[2].isSentTransaction, false)
    }

    // TODO: [#1518] Fix the test, https://github.com/Electric-Coin-Company/zcash-swift-wallet-sdk/issues/1518
    func _testFindByTxId() async throws {
        let id = Data(fromHexEncodedString: "01af48bcc4e9667849a073b8b5c539a0fc19de71aac775377929dc6567a36eff")!
        let transaction = try await self.transactionRepository.find(rawID: id)
        XCTAssertEqual(transaction.rawID, id)
        XCTAssertEqual(transaction.minedHeight, 663922)
        XCTAssertEqual(transaction.index, 1)
    }

    // TODO: [#1518] Fix the test, https://github.com/Electric-Coin-Company/zcash-swift-wallet-sdk/issues/1518
    func _testFindAllSentTransactions() async throws {
        let transactions = try await self.transactionRepository.find(offset: 0, limit: Int.max, kind: .sent)
        XCTAssertEqual(transactions.count, 13)
        transactions.forEach { XCTAssertEqual($0.isSentTransaction, true) }
    }

    // TODO: [#1518] Fix the test, https://github.com/Electric-Coin-Company/zcash-swift-wallet-sdk/issues/1518
    func _testFindAllReceivedTransactions() async throws {
        let transactions = try await self.transactionRepository.find(offset: 0, limit: Int.max, kind: .received)
        XCTAssertEqual(transactions.count, 8)
        transactions.forEach { XCTAssertEqual($0.isSentTransaction, false) }
    }

    // TODO: [#1518] Fix the test, https://github.com/Electric-Coin-Company/zcash-swift-wallet-sdk/issues/1518
    func _testFindAllTransactions() async throws {
        let transactions = try await self.transactionRepository.find(offset: 0, limit: Int.max, kind: .all)
        XCTAssertEqual(transactions.count, 21)
    }

    // TODO: [#1518] Fix the test, https://github.com/Electric-Coin-Company/zcash-swift-wallet-sdk/issues/1518
    func _testFindReceivedOffsetLimit() async throws {
        let transactions = try await self.transactionRepository.findReceived(offset: 3, limit: 3)
        XCTAssertEqual(transactions.count, 3)
        XCTAssertEqual(transactions[0].minedHeight, 663229)
        XCTAssertEqual(transactions[1].minedHeight, 663218)
        XCTAssertEqual(transactions[2].minedHeight, 663202)
    }

    // TODO: [#1518] Fix the test, https://github.com/Electric-Coin-Company/zcash-swift-wallet-sdk/issues/1518
    func _testFindSentOffsetLimit() async throws {
        let transactions = try await self.transactionRepository.findSent(offset: 3, limit: 3)
        XCTAssertEqual(transactions.count, 3)
        XCTAssertEqual(transactions[0].minedHeight, 664022)
        XCTAssertEqual(transactions[1].minedHeight, 664012)
        XCTAssertEqual(transactions[2].minedHeight, 663956)
    }

    // TODO: [#1518] Fix the test, https://github.com/Electric-Coin-Company/zcash-swift-wallet-sdk/issues/1518
    func _testGetTransactionOutputs() async throws {
        let rawID = Data(fromHexEncodedString: "08cb5838ffd2c18ce15e7e8c50174940cd9526fff37601986f5480b7ca07e534")!

        let outputs = try await self.transactionRepository.getTransactionOutputs(for: rawID)
        XCTAssertEqual(outputs.count, 2)
    }

    // TODO: [#1518] Fix the test, https://github.com/Electric-Coin-Company/zcash-swift-wallet-sdk/issues/1518
    func _testFindMemoForTransaction() async throws {
        let rawID = Data(fromHexEncodedString: "08cb5838ffd2c18ce15e7e8c50174940cd9526fff37601986f5480b7ca07e534")!
        let transaction = ZcashTransaction.Overview(
            accountUUID: TestsData.mockedAccountUUID,
            blockTime: nil,
            expiryHeight: nil,
            fee: nil,
            index: nil,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: nil,
            raw: nil,
            rawID: rawID,
            receivedNoteCount: 0,
            sentNoteCount: 0,
            value: Zatoshi(-1000),
            isExpiredUmined: false,
            totalSpent: nil,
            totalReceived: nil,
            spentNoteCount: 0,
            poolCrossingValue: nil,
            isTrusted: false,
            zip318Kind: .notClassified
        )

        let memos = try await self.transactionRepository.findMemos(for: transaction)

        guard memos.count == 1 else {
            XCTFail("Expected transaction to have one memo, found \(memos.count)")
            return
        }

        XCTAssertEqual(memos[0].toString(), "Some funds")
    }

    // TODO: [#1518] Fix the test, https://github.com/Electric-Coin-Company/zcash-swift-wallet-sdk/issues/1518
    func _testFindMemoForReceivedTransaction() async throws {
        let rawID = Data(fromHexEncodedString: "1f49cfcfcdebd5cb9085d9ff2efbcda87121dda13f2c791113fcf2e79ba82108")!
        let transaction = ZcashTransaction.Overview(
            accountUUID: TestsData.mockedAccountUUID,
            blockTime: 1,
            expiryHeight: nil,
            fee: nil,
            index: 0,
            isShielding: false,
            hasChange: false,
            memoCount: 1,
            minedHeight: 0,
            raw: nil,
            rawID: rawID,
            receivedNoteCount: 1,
            sentNoteCount: 0,
            value: .zero,
            isExpiredUmined: false,
            totalSpent: nil,
            totalReceived: nil,
            spentNoteCount: 0,
            poolCrossingValue: nil,
            isTrusted: false,
            zip318Kind: .notClassified
        )

        let memos = try await self.transactionRepository.findMemos(for: transaction)
        XCTAssertEqual(memos.count, 1)
        XCTAssertEqual(memos[0].toString(), "first mainnet tx from the SDK")
    }

    // TODO: [#1518] Fix the test, https://github.com/Electric-Coin-Company/zcash-swift-wallet-sdk/issues/1518
    func _testFindMemoForSentTransaction() async throws {
        let rawID = Data(fromHexEncodedString: "08cb5838ffd2c18ce15e7e8c50174940cd9526fff37601986f5480b7ca07e534")!
        let transaction = ZcashTransaction.Overview(
            accountUUID: TestsData.mockedAccountUUID,
            blockTime: 1,
            expiryHeight: nil,
            fee: nil,
            index: 0,
            isShielding: false,
            hasChange: false,
            memoCount: 1,
            minedHeight: nil,
            raw: nil,
            rawID: rawID,
            receivedNoteCount: 0,
            sentNoteCount: 2,
            value: .zero,
            isExpiredUmined: false,
            totalSpent: nil,
            totalReceived: nil,
            spentNoteCount: 0,
            poolCrossingValue: nil,
            isTrusted: false,
            zip318Kind: .notClassified
        )

        let memos = try await self.transactionRepository.findMemos(for: transaction)
        XCTAssertEqual(memos.count, 1)
        XCTAssertEqual(memos[0].toString(), "Some funds")
    }

    // TODO: [#1518] Fix the test, https://github.com/Electric-Coin-Company/zcash-swift-wallet-sdk/issues/1518
    func _testFindAllPerformance() {
        // This is an example of a performance test case.
        self.measure {
            let expectation = expectation(description: "Measure")
            Task(priority: .userInitiated) {
                // Put the code you want to measure the time of here.
                do {
                    _ = try await self.transactionRepository.find(offset: 0, limit: Int.max, kind: .all)
                    expectation.fulfill()
                } catch {
                    XCTFail("find all failed")
                }
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    // TODO: [#1518] Fix the test, https://github.com/Electric-Coin-Company/zcash-swift-wallet-sdk/issues/1518
    func _testFindAllFrom() async throws {
        let rawID = Data(fromHexEncodedString: "5d9b91e31a6d3f94844a4c330e727a2d5d0643f6caa6c75573b28aefe859e8d2")!
        let transaction = try await self.transactionRepository.find(rawID: rawID)
        let transactionsFrom = try await self.transactionRepository.find(from: transaction, limit: Int.max, kind: .all)

        XCTAssertEqual(transactionsFrom.count, 15)

        transactionsFrom.forEach { preceededTransaction in
            guard let precedingHeight = preceededTransaction.minedHeight, let transactionHeight = transaction.minedHeight else {
                XCTFail("Transactions are missing mined heights.")
                return
            }

            guard let precedingBlockTime = preceededTransaction.blockTime, let transactionBlockTime = transaction.blockTime else {
                XCTFail("Transactions are missing block time.")
                return
            }

            XCTAssertLessThanOrEqual(precedingHeight, transactionHeight)
            XCTAssertLessThan(precedingBlockTime, transactionBlockTime)
        }
    }

    // MARK: - MOB-1953: batched outputs

    /// MOB-1953: the batched read must answer exactly what the per-row read answers for every
    /// transaction in the fixture, so a client can replace its per-row loop with no behaviour
    /// change. Order is part of that: both queries order by pool and then output index, and the
    /// app reads the first address of a transaction, so the arrays are compared as arrays.
    func testBatchedOutputsMatchPerRowOutputsForEveryTransaction() async throws {
        let transactions = try await transactionRepository.find(offset: 0, limit: Int.max, kind: .all)
        XCTAssertEqual(transactions.count, 21)

        let batched = try await transactionRepository.getTransactionOutputs(for: transactions.map(\.rawID))

        var transactionsWithOutputs = 0
        for transaction in transactions {
            let perRow = try await transactionRepository.getTransactionOutputs(for: transaction.rawID)
            XCTAssertEqual(
                batched[transaction.rawID] ?? [],
                perRow,
                "outputs of \(transaction.rawID.toHexStringTxId()) differ between the batched and the per-row read"
            )
            if !perRow.isEmpty {
                transactionsWithOutputs += 1
            }
        }
        XCTAssertGreaterThan(transactionsWithOutputs, 0, "the fixture must exercise at least one transaction with outputs")
        XCTAssertTrue(
            Set(batched.keys).subtracting(transactions.map(\.rawID)).isEmpty,
            "the batch must not answer for ids it was not asked about"
        )
    }

    /// MOB-1953: more ids than one statement's chunk, most of them unknown, some duplicated. The
    /// read must chunk (never trip SQLite's bound-variable limit), answer the known ids exactly
    /// as the per-row read does, produce no entry for an id the wallet has never seen, and not
    /// duplicate the rows of a duplicated id.
    func testBatchedOutputsChunkAndIgnoreUnknownIds() async throws {
        let transactions = try await transactionRepository.find(offset: 0, limit: Int.max, kind: .all)
        let unknownIDs: [Data] = (0..<(TransactionSQLDAO.outputsQueryChunkSize + 37)).map { _ in
            Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        }
        let knownIDs = transactions.map(\.rawID)

        let batched = try await transactionRepository.getTransactionOutputs(for: unknownIDs + knownIDs + knownIDs)

        for id in unknownIDs {
            XCTAssertNil(batched[id], "an id the wallet has never seen must have no entry")
        }
        for transaction in transactions {
            let perRow = try await transactionRepository.getTransactionOutputs(for: transaction.rawID)
            XCTAssertEqual(
                batched[transaction.rawID] ?? [],
                perRow,
                "a duplicated id must answer once, with the per-row rows"
            )
        }
    }

    /// MOB-1953: asking for nothing answers nothing and issues no query.
    func testBatchedOutputsForNoIdsIsEmpty() async throws {
        let batched = try await transactionRepository.getTransactionOutputs(for: [])
        XCTAssertTrue(batched.isEmpty)
    }

    /// MOB-1953: an output row that cannot be decoded must cost that row and nothing else.
    /// `ZcashTransaction.Output.init(row:)` throws on a row naming neither an address the SDK can
    /// parse nor a receiving account, and the batched read decodes up to 500 transactions' rows in
    /// one statement. Decoding that statement strictly meant one such row threw for the whole
    /// chunk, and both synchronizers answer a throw with an empty dictionary for every transaction
    /// the caller asked about — so a single bad row emptied the outputs of the entire list. Those
    /// same callers wrap the per-transaction read in `try?`, which has always confined the failure
    /// to one transaction; this pins the batched read to no worse than that.
    func testBatchedOutputsSkipOnlyTheRowThatFailsToDecode() async throws {
        let transactions = try await transactionRepository.find(offset: 0, limit: Int.max, kind: .all)
        var expectedOutputs: [Data: [ZcashTransaction.Output]] = [:]
        for transaction in transactions {
            expectedOutputs[transaction.rawID] = try await transactionRepository.getTransactionOutputs(for: transaction.rawID)
        }

        // `setUp` migrates the bundled fixture in place, so a copy taken here already carries the
        // current schema. The copy is what gets poisoned: the fixture itself stays usable by every
        // other test in the suite.
        let poisonedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("poisoned_outputs_\(UUID().uuidString).db")
        try FileManager.default.copyItem(at: TestDbBuilder.prePopulatedMainnetDataDbURL()!, to: poisonedURL)
        defer { try? FileManager.default.removeItem(at: poisonedURL) }

        let poisonedTxID = try Self.insertUndecodableOutputRow(intoDbAt: poisonedURL)
        guard let poisonedTransaction = transactions.first(where: { $0.rawID == poisonedTxID }) else {
            return XCTFail("the poisoned row must belong to a transaction the wallet reports")
        }
        XCTAssertFalse(
            expectedOutputs[poisonedTxID, default: []].isEmpty,
            "the poisoned transaction must already own decodable rows, or the test proves nothing"
        )

        let trace = TraceRecorder()
        let poisonedRepository = TransactionSQLDAO(
            dbProvider: SimpleConnectionProvider(path: poisonedURL.path, readonly: true),
            traceClosure: { trace.record($0) }
        )

        // The inserted row really is undecodable: the strict per-transaction read cannot get past it.
        do {
            _ = try await poisonedRepository.getTransactionOutputs(for: poisonedTxID)
            XCTFail("the inserted row must fail to decode, otherwise nothing is being tested")
        } catch {
            // Expected — the per-transaction read is strict, which is why its callers use `try?`.
        }

        let batched = try await poisonedRepository.getTransactionOutputs(for: transactions.map(\.rawID))

        for transaction in transactions where transaction.rawID != poisonedTxID {
            XCTAssertEqual(
                batched[transaction.rawID] ?? [],
                expectedOutputs[transaction.rawID] ?? [],
                "one bad row elsewhere must not touch \(transaction.rawID.toHexStringTxId())"
            )
        }
        XCTAssertEqual(
            batched[poisonedTxID] ?? [],
            expectedOutputs[poisonedTxID] ?? [],
            "the poisoned transaction must keep every row of its own that still decodes"
        )
        XCTAssertTrue(
            trace.messages.contains { $0.contains("skipped an output row that failed to decode") },
            "a skipped row must be reported, not swallowed silently"
        )
        XCTAssertEqual(
            poisonedTransaction.rawID,
            poisonedTxID,
            "sanity: the poisoned transaction is the one whose outputs were asserted above"
        )
    }

    /// Adds one row to `sent_notes` that `ZcashTransaction.Output.init(row:)` cannot decode, and
    /// answers the raw id of the transaction it belongs to. Every column is copied from a row that
    /// is already there, so the table's NOT NULL columns and its uniqueness constraint are
    /// satisfied without the test having to know the migrated schema by heart; exactly one thing is
    /// broken, the recipient — an address no parser accepts, and no receiving account to fall back
    /// on.
    private static func insertUndecodableOutputRow(intoDbAt url: URL) throws -> Data {
        let connection = try SimpleConnectionProvider(path: url.path, readonly: false).connection()

        guard let transactionID = try connection.scalar(
            "SELECT transaction_id FROM sent_notes ORDER BY transaction_id LIMIT 1"
        ) as? Int64 else {
            throw TestError.fixtureHasNoSentNotes
        }

        // Free across the whole view, not just `sent_notes`: `v_tx_outputs` merges a sent row and a
        // received row that share (transaction, pool, index), and a merged row borrows the received
        // row's account — which would make the poisoned row decode after all.
        let freeOutputIndex = (try connection.scalar(
            "SELECT IFNULL(MAX(output_index), -1) + 1 FROM v_tx_outputs WHERE transaction_id = ?",
            transactionID
        ) as? Int64) ?? 0

        try connection.run(
            """
            INSERT INTO sent_notes
                (transaction_id, output_pool, output_index, from_account_id, to_address, to_account_id, value, memo)
            SELECT transaction_id, output_pool, ?, from_account_id, ?, NULL, value, NULL
            FROM sent_notes WHERE transaction_id = ? LIMIT 1
            """,
            freeOutputIndex,
            "not-an-address-any-parser-accepts",
            transactionID
        )

        guard let txid = try connection.scalar(
            "SELECT txid FROM transactions WHERE id_tx = ?",
            transactionID
        ) as? Blob else {
            throw TestError.fixtureHasNoSentNotes
        }

        return Data(blob: txid)
    }
}

/// Collects what the DAO reports through its trace hook. SQLite invokes the hook synchronously on
/// whichever thread runs the statement, so the collection is locked. `NSLock` rather than
/// `OSAllocatedUnfairLock` because the package's platform floor predates the latter.
private final class TraceRecorder {
    private let lock = NSLock()
    private var collected: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        collected.append(message)
    }
}

extension Data {
    init?(fromHexEncodedString string: String) {
        // Convert 0 ... 9, a ... f, A ...F to their decimal value,
        // return nil for all other input characters
        func decodeNibble(bytes: UInt16) -> UInt8? {
            switch bytes {
            case 0x30 ... 0x39:
                return UInt8(bytes - 0x30)
            case 0x41 ... 0x46:
                return UInt8(bytes - 0x41 + 10)
            case 0x61 ... 0x66:
                return UInt8(bytes - 0x61 + 10)
            default:
                return nil
            }
        }

        self.init(capacity: string.utf16.count / 2)
        var even = true
        var byte: UInt8 = 0
        for char in string.utf16 {
            guard let val = decodeNibble(bytes: char) else { return nil }
            if even {
                byte = val << 4
            } else {
                byte += val
                self.append(byte)
            }
            even.toggle()
        }
        guard even else { return nil }
    }
}
