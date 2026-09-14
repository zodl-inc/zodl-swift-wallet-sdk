//
//  TransactionRepository.swift
//  ZcashLightClientKit
//
//  Created by Francisco Gindre on 11/16/19.
//

import Foundation

protocol TransactionRepository {
    func closeDBConnection()
    func countAll() async throws -> Int
    func countUnmined() async throws -> Int
    func isInitialized() async throws -> Bool
    func fetchTxidsWithMemoContaining(searchTerm: String) async throws -> [Data]
    func find(rawID: Data) async throws -> ZcashTransaction.Overview
    func find(offset: Int, limit: Int, kind: TransactionKind) async throws -> [ZcashTransaction.Overview]
    func find(in range: CompactBlockRange, limit: Int, kind: TransactionKind) async throws -> [ZcashTransaction.Overview]
    func find(from: ZcashTransaction.Overview, limit: Int, kind: TransactionKind) async throws -> [ZcashTransaction.Overview]
    func findPendingTransactions(latestHeight: BlockHeight, offset: Int, limit: Int) async throws -> [ZcashTransaction.Overview]
    func findReceived(offset: Int, limit: Int) async throws -> [ZcashTransaction.Overview]
    func findSent(offset: Int, limit: Int) async throws -> [ZcashTransaction.Overview]
    func findForResubmission(upTo: BlockHeight) async throws -> [ZcashTransaction.Overview]
    // sourcery: mockedName="findMemosForRawID"
    func findMemos(for rawID: Data) async throws -> [Memo]
    // sourcery: mockedName="findMemosForZcashTransaction"
    func findMemos(for transaction: ZcashTransaction.Overview) async throws -> [Memo]
    func getRecipients(for rawID: Data) async throws -> [TransactionRecipient]
    func getTransactionOutputs(for rawID: Data) async throws -> [ZcashTransaction.Output]

    /// [MOB-1953] Every output of every transaction in `rawIDs`, keyed by the transaction's raw id
    /// — one `v_tx_outputs` query per `TransactionSQLDAO.outputsQueryChunkSize` ids instead of one
    /// per transaction. The view materialises the wallet's whole notes union on every query, so a
    /// per-row loop over a long history costs transactions × notes (1,256 queries and 25 s for a
    /// 1,255-transaction wallet on an iPhone 15); the batched read costs a handful of queries.
    /// Row order within a transaction is the view's, the same order `getTransactionOutputs(for
    /// rawID:)` returns. A transaction without outputs has no entry; a duplicated id answers once.
    // sourcery: mockedName="getTransactionOutputsForRawIDs"
    func getTransactionOutputs(for rawIDs: [Data]) async throws -> [Data: [ZcashTransaction.Output]]
    func debugDatabase(sql: String) -> String

    /// [#1755] Txids whose `account_balance_delta` is not yet final during a deep recovery — read from
    /// the slipstream-owned `ext_slipstream_v_tx_reconciled` view. A recent-first restore can scan a spend
    /// before its input's origin block, so the spend is transiently unattributed and the tx reads as a
    /// phantom "+receive". Consumers hold these txs out of the Activity list until they reconcile. The
    /// default returns an empty set: a DB without the view (legacy / non-slipstream) holds nothing back.
    /// ([v2.1 Phase 2] The former `recoveryBalances()` sibling is GONE: the engine resolves
    /// recovery balances inside `zcashlc_slipstream_wallet_summary`, one definition for every host.)
    func unreconciledTxids() async throws -> Set<Data>
}

extension TransactionRepository {
    func unreconciledTxids() async throws -> Set<Data> { [] }
}
