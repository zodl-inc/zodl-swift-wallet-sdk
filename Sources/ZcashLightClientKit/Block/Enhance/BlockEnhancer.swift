//
//  CompactBlockEnhancement.swift
//  ZcashLightClientKit
//
//  Created by Francisco Gindre on 4/10/20.
//

import Foundation

public struct EnhancementProgress: Equatable {
    /// total transactions that were detected in the `range`
    public let totalTransactions: Int
    /// enhanced transactions so far
    public let enhancedTransactions: Int
    /// last found transaction
    public let lastFoundTransaction: ZcashTransaction.Overview?
    /// block range that's being enhanced
    public let range: CompactBlockRange
    /// whether this transaction can be considered `newly mined` and not part of the
    /// wallet catching up to stale and uneventful blocks.
    public let newlyMined: Bool

    public init(
        totalTransactions: Int,
        enhancedTransactions: Int,
        lastFoundTransaction: ZcashTransaction.Overview?,
        range: CompactBlockRange,
        newlyMined: Bool
    ) {
        self.totalTransactions = totalTransactions
        self.enhancedTransactions = enhancedTransactions
        self.lastFoundTransaction = lastFoundTransaction
        self.range = range
        self.newlyMined = newlyMined
    }

    public var progress: Float {
        totalTransactions > 0 ? Float(enhancedTransactions) / Float(totalTransactions) : 0
    }

    public static var zero: EnhancementProgress {
        EnhancementProgress(totalTransactions: 0, enhancedTransactions: 0, lastFoundTransaction: nil, range: 0...0, newlyMined: false)
    }

    public static func == (lhs: EnhancementProgress, rhs: EnhancementProgress) -> Bool {
        return
            lhs.totalTransactions == rhs.totalTransactions &&
            lhs.enhancedTransactions == rhs.enhancedTransactions &&
            lhs.lastFoundTransaction?.rawID == rhs.lastFoundTransaction?.rawID &&
            lhs.range == rhs.range
    }
}

protocol BlockEnhancer {
    func enhance(at range: CompactBlockRange, didEnhance: @escaping (EnhancementProgress) async -> Void) async throws -> [ZcashTransaction.Overview]?
}

struct BlockEnhancerImpl {
    let blockDownloaderService: BlockDownloaderService
    let rustBackend: ZcashRustBackendWelding
    let transactionRepository: TransactionRepository
    let metrics: SDKMetrics
    let service: LightWalletService
    let logger: Logger
    let sdkFlags: SDKFlags
    let dataDb: URL
    let networkType: NetworkType
}

extension BlockEnhancerImpl {
    /// The last block height to ask the server for: the request's `blockRangeEnd` is exclusive
    /// while the server's range is inclusive. `nil` when the request has no end.
    static func lastHeight(of request: TransactionsInvolvingAddress) -> BlockHeight? {
        request.blockRangeEnd.map { BlockHeight($0) - 1 }
    }

    /// Serves one `transactionsInvolvingAddress` request. Returns `false` when the request has a
    /// shape the enhancer does not support yet, in which case nothing is fetched and the backend
    /// re-issues the request on a later cycle.
    ///
    /// On the direct connection the transactions stream through here and are filtered by the
    /// request's status filter before being stored. Over Tor the FFI runs the same query on a
    /// circuit dedicated to the address and stores every returned transaction itself, mined or
    /// not, so the status filter is not applied: a mined-only request over a historical range gets
    /// no mempool rows anyway, and a row stored as unmined is reconciled when the transaction is
    /// mined.
    func fetchTransactionsInvolvingAddress(_ tia: TransactionsInvolvingAddress) async throws -> Bool {
        // TODO: [#1554] Remove this guard once lightwalletd servers support open-ended ranges.
        guard let lastHeight = Self.lastHeight(of: tia) else {
            logger.error("transactionsInvolvingAddress \(tia) is missing blockRangeEnd, ignoring the request.")
            return false
        }

        // TODO: [#1551] Support this.
        if tia.requestAt != nil {
            logger.error("transactionsInvolvingAddress \(tia) has requestAt set, ignoring the unsupported request.")
            return false
        }

        // TODO: [#1552] Support the OutputStatusFilter
        if tia.outputStatusFilter == .unspent {
            return false
        }

        let address = TransparentAddress(validatedEncoding: tia.address)
        let mode = await sdkFlags.ifTor(ServiceMode.addressGroup(prefix: "taddr", address: address))

        guard mode == .direct else {
            _ = try await service.updateTransparentAddressTransactions(
                address: tia.address,
                start: BlockHeight(tia.blockRangeStart),
                end: lastHeight,
                dbData: dataDb.osStr(),
                networkType: networkType,
                mode: mode
            )
            return true
        }

        var filter = TransparentAddressBlockFilter()
        filter.address = tia.address
        filter.range = BlockRange(startHeight: Int(tia.blockRangeStart), endHeight: lastHeight)

        let stream = try service.getTaddressTransactions(filter, mode: mode)

        for try await rawTransaction in stream {
            let minedHeight = (rawTransaction.height == 0 || rawTransaction.height > UInt32.max)
            ? nil : UInt32(rawTransaction.height)

            // Ignore transactions that don't match the status filter.
            if (tia.txStatusFilter == .mined && minedHeight == nil) || (tia.txStatusFilter == .mempool && minedHeight != nil) {
                continue
            }

            _ = try await rustBackend.decryptAndStoreTransaction(
                txBytes: rawTransaction.data.bytes,
                minedHeight: minedHeight
            )
        }

        return true
    }
}

extension BlockEnhancerImpl: BlockEnhancer {
    /// Reports a sent transaction that has just transitioned from unmined to mined through
    /// `didEnhance` — the upstream producer of `SynchronizerEvent.minedTransaction`
    /// (`EnhanceAction`). This callback had not been invoked since the adoption of transaction
    /// data requests, which silently killed that event in production.
    private func notifyNewlyMined(
        rawID: Data,
        wasMined: Bool,
        enhancedTransactions: Int,
        totalTransactions: Int,
        range: CompactBlockRange,
        didEnhance: @escaping (EnhancementProgress) async -> Void
    ) async {
        guard !wasMined else { return }
        guard
            let overview = try? await transactionRepository.find(rawID: rawID),
            overview.minedHeight != nil,
            overview.isSentTransaction
        else { return }
        await didEnhance(
            EnhancementProgress(
                totalTransactions: totalTransactions,
                enhancedTransactions: enhancedTransactions,
                lastFoundTransaction: overview,
                range: range,
                newlyMined: true
            )
        )
    }

    // swiftlint:disable:next cyclomatic_complexity
    func enhance(at range: CompactBlockRange, didEnhance: @escaping (EnhancementProgress) async -> Void) async throws -> [ZcashTransaction.Overview]? {
        try Task.checkCancellation()

        logger.debug("Started Enhancing range: \(range)")

        // fetch transactions
        do {
            let transactionDataRequests = try await rustBackend.transactionDataRequests()

            guard !transactionDataRequests.isEmpty else {
                logger.debug("No transaction data requests detected.")
                logger.sync("No transaction data requests detected.")
                return nil
            }

            let cycleID = String(UUID().uuidString.prefix(6))
            logger.info("BlockEnhancer cycle started [\(cycleID)] requests=\(transactionDataRequests.count)")

            for index in 0 ..< transactionDataRequests.count {
                let transactionDataRequest = transactionDataRequests[index]
                let reqID = "\(cycleID).\(index)"
                let typeName = transactionDataRequest.typeName
                var retry = true
                var retries = 0
                let maxRetries = 5

                while retry && retries < maxRetries {
                    try Task.checkCancellation()
                    logger.info("BlockEnhancer [\(reqID)] type=\(typeName) attempt=\(retries + 1)")
                    do {
                        switch transactionDataRequest {
                        case .getStatus(let txId):
                            let response = try await blockDownloaderService.fetchTransaction(
                                txId: txId.data,
                                mode: await sdkFlags.ifTor(ServiceMode.txIdGroup(prefix: "fetch", txId: txId.data))
                            )
                            logger.info("BlockEnhancer [\(reqID)] fetch returned status=\(response.status) has_tx=\(response.tx != nil)")

                            if response.status == .txidNotRecognized {
                                try await rustBackend.setTransactionStatus(txId: txId.data, status: response.status)
                                logger.info("BlockEnhancer [\(reqID)] setTransactionStatus called (txidNotRecognized)")
                            } else if let fetchedTransaction = response.tx {
                                try await rustBackend.setTransactionStatus(txId: fetchedTransaction.rawID, status: response.status)
                                logger.info("BlockEnhancer [\(reqID)] setTransactionStatus called (status=\(response.status))")
                                // A GetStatus request only exists for a transaction whose
                                // `mined_height` is NULL, so a mined answer is by definition a
                                // nil→mined transition.
                                if case .mined = response.status {
                                    await notifyNewlyMined(
                                        rawID: fetchedTransaction.rawID,
                                        wasMined: false,
                                        enhancedTransactions: index + 1,
                                        totalTransactions: transactionDataRequests.count,
                                        range: range,
                                        didEnhance: didEnhance
                                    )
                                }
                            }
                            retry = false

                        case .enhancement(let txId):
                            let response = try await blockDownloaderService.fetchTransaction(
                                txId: txId.data,
                                mode: await sdkFlags.ifTor(ServiceMode.txIdGroup(prefix: "fetch", txId: txId.data))
                            )
                            let hasMined = response.tx?.minedHeight != nil
                            logger.info("BlockEnhancer [\(reqID)] fetch returned status=\(response.status) has_tx=\(response.tx != nil) has_mined_height=\(hasMined)")

                            if response.status == .txidNotRecognized {
                                try await rustBackend.setTransactionStatus(txId: txId.data, status: .txidNotRecognized)
                                logger.info("BlockEnhancer [\(reqID)] setTransactionStatus called (txidNotRecognized)")
                            } else if let fetchedTransaction = response.tx {
                                // Whether the wallet already knew this transaction as mined must be
                                // read BEFORE the store below flips it — the `.minedTransaction`
                                // event means a transition, not a state.
                                let wasMined = (try? await transactionRepository.find(rawID: txId.data))?.minedHeight != nil
                                _ = try await rustBackend.decryptAndStoreTransaction(
                                    txBytes: fetchedTransaction.raw.bytes,
                                    minedHeight: fetchedTransaction.minedHeight
                                )
                                logger.info("BlockEnhancer [\(reqID)] decryptAndStoreTransaction called has_mined_height=\(hasMined)")
                                if fetchedTransaction.minedHeight != nil {
                                    await notifyNewlyMined(
                                        rawID: txId.data,
                                        wasMined: wasMined,
                                        enhancedTransactions: index + 1,
                                        totalTransactions: transactionDataRequests.count,
                                        range: range,
                                        didEnhance: didEnhance
                                    )
                                }
                            }
                            retry = false

                        case .transactionsInvolvingAddress(let tia):
                            _ = try await fetchTransactionsInvolvingAddress(tia)
                            retry = false
                        }
                    } catch {
                        retries += 1
                        logger.error("BlockEnhancer [\(reqID)] type=\(typeName) attempt=\(retries) error_type=\(String(describing: type(of: error)))")
                    }
                }

                if retry {
                    logger.error("BlockEnhancer [\(reqID)] type=\(typeName) retry exhausted after \(maxRetries) attempts; will retry on next sync cycle")
                }
            }

            logger.info("BlockEnhancer cycle complete [\(cycleID)]")
        } catch {
            logger.error("error enhancing transactions! \(error)")
            throw error
        }

        if Task.isCancelled {
            logger.debug("Warning: compactBlockEnhancement on range \(range) cancelled")
        }

        return (try? await transactionRepository.find(in: range, limit: Int.max, kind: .all))
    }
}

extension TransactionDataRequest {
    /// Short, non-PII label for diagnostic logging.
    var typeName: String {
        switch self {
        case .getStatus: return "getStatus"
        case .enhancement: return "enhancement"
        case .transactionsInvolvingAddress: return "transactionsInvolvingAddress"
        }
    }
}
