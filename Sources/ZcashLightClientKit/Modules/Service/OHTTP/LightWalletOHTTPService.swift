//
//  LightWalletOHTTPService.swift
//  ZcashLightClientKit
//
//  LightWalletService implementation using OHTTP transport for .direct mode.
//  Tor modes delegate to the parent's FFI TorLwdConn path.
//

import Foundation

/// LightWalletService implementation using OHTTP for `.direct` mode.
///
/// Server-streaming methods buffer all frames from the gateway and surface them as AsyncThrowingStreams.
/// The base class's grpc-swift connection is never created when using OHTTP (all `.direct` calls are
/// intercepted before `compactTxStreamer` is accessed).
final class LightWalletOHTTPService: LightWalletGRPCServiceOverTor {
    private let ohttpClient: OHTTPGRPCClient?

    // `init(endpoint:tor:)` is inherited from the superclass: this class overrides its only
    // designated initializer, so the superclass convenience initializers come along.
    override init(
        endpoint: LightWalletEndpoint,
        singleCallTimeout: Int64,
        streamingCallTimeout: Int64,
        tor: TorClient
    ) {
        // Initialize OHTTP client if this is an OHTTP gateway
        if OHTTPEndpoints.isGateway(endpoint.host) {
            do {
                let relayURL = try OHTTPEndpoints.relayURL(for: endpoint.host)
                let keyConfigURL = OHTTPEndpoints.keyConfigURL(for: endpoint.host)
                let transport = OHTTPTransport(relayURL: relayURL, keyConfigURL: keyConfigURL)
                self.ohttpClient = OHTTPGRPCClient(
                    authority: endpoint.host,
                    transport: transport,
                    singleCallTimeoutMS: Int(singleCallTimeout),
                    streamingCallTimeoutMS: Int(streamingCallTimeout)
                )
            } catch {
                // Log error but continue - will fall back to parent if OHTTP fails to init
                self.ohttpClient = nil
            }
        } else {
            self.ohttpClient = nil
        }

        super.init(
            endpoint: endpoint,
            singleCallTimeout: singleCallTimeout,
            streamingCallTimeout: streamingCallTimeout,
            tor: tor
        )
    }

    // MARK: - LightWalletService Protocol

    override func getInfo(mode: ServiceMode) async throws -> LightWalletdInfo {
        guard mode == .direct, let client = ohttpClient else {
            return try await super.getInfo(mode: mode)
        }

        // The protocol returns the `LightWalletdInfo` existential; decode the concrete proto message.
        let info: LightdInfo = try await client.unary(
            path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLightdInfo",
            request: Empty()
        )
        return info
    }

    override func latestBlock(mode: ServiceMode) async throws -> BlockID {
        guard mode == .direct, let client = ohttpClient else {
            return try await super.latestBlock(mode: mode)
        }

        return try await client.unary(
            path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLatestBlock",
            request: ChainSpec()
        )
    }

    override func latestBlockHeight(mode: ServiceMode) async throws -> BlockHeight {
        let blockID = try await latestBlock(mode: mode)
        guard let height = Int(exactly: blockID.height) else {
            throw LightWalletServiceError.generalError(message: "error creating blockheight from BlockID \(blockID)")
        }
        return height
    }

    override func blockRange(_ range: CompactBlockRange, mode: ServiceMode) throws -> AsyncThrowingStream<ZcashCompactBlock, Error> {
        guard mode == .direct, let client = ohttpClient else {
            return try super.blockRange(range, mode: mode)
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let blocks: [CompactBlock] = try await client.serverStreaming(
                        path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetBlockRange",
                        request: range.blockRange()
                    )

                    for block in blocks {
                        continuation.yield(ZcashCompactBlock(compactBlock: block))
                    }
                    continuation.finish()
                } catch {
                    let serviceError = error as? LightWalletServiceError ?? LightWalletServiceError.genericError(error: error)
                    continuation.finish(throwing: ZcashError.serviceBlockRangeFailed(serviceError))
                }
            }
        }
    }

    override func submit(spendTransaction: Data, mode: ServiceMode) async throws -> LightWalletServiceResponse {
        guard mode == .direct, let client = ohttpClient else {
            return try await super.submit(spendTransaction: spendTransaction, mode: mode)
        }

        var transaction = RawTransaction()
        transaction.data = spendTransaction
        let response: SendResponse = try await client.unary(
            path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/SendTransaction",
            request: transaction
        )
        return response
    }

    override func fetchTransaction(txId: Data, mode: ServiceMode) async throws -> (tx: ZcashTransaction.Fetched?, status: TransactionStatus) {
        guard mode == .direct, let client = ohttpClient else {
            return try await super.fetchTransaction(txId: txId, mode: mode)
        }

        var txFilter = TxFilter()
        txFilter.hash = txId

        do {
            let rawTx: RawTransaction = try await client.unary(
                path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetTransaction",
                request: txFilter
            )

            let isNotMined = rawTx.height == 0 || rawTx.height > UInt32.max

            return (
                tx: ZcashTransaction.Fetched(
                    rawID: txId,
                    minedHeight: isNotMined ? nil : UInt32(rawTx.height),
                    raw: rawTx.data
                ),
                status: isNotMined ? .notInMainChain : .mined(Int(rawTx.height))
            )
        } catch let error as LightWalletServiceError {
            // Map specific error messages to txidNotRecognized
            if case .failed(let code, let message) = error {
                if code == 5 || // NOT_FOUND
                   message.contains("Transaction not found") ||
                   message.contains("No such mempool or main chain transaction") ||
                   message.contains("No such mempool or blockchain transaction") {
                    return (tx: nil, .txidNotRecognized)
                }
            }
            throw ZcashError.serviceFetchTransactionFailed(error)
        } catch {
            let serviceError = error as? LightWalletServiceError ?? LightWalletServiceError.genericError(error: error)
            throw ZcashError.serviceFetchTransactionFailed(serviceError)
        }
    }

    override func fetchUTXOs(for tAddress: String, height: BlockHeight, mode: ServiceMode) throws -> AsyncThrowingStream<UnspentTransactionOutputEntity, Error> {
        return try fetchUTXOs(for: [tAddress], height: height, mode: mode)
    }

    override func fetchUTXOs(
        for tAddresses: [String],
        height: BlockHeight,
        mode: ServiceMode
    ) throws -> AsyncThrowingStream<UnspentTransactionOutputEntity, Error> {
        guard mode == .direct, let client = ohttpClient else {
            return try super.fetchUTXOs(for: tAddresses, height: height, mode: mode)
        }

        guard !tAddresses.isEmpty else {
            return AsyncThrowingStream { continuation in continuation.finish() }
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var args = GetAddressUtxosArg()
                    args.addresses = tAddresses
                    args.startHeight = UInt64(height)

                    let replies: [GetAddressUtxosReply] = try await client.serverStreaming(
                        path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetAddressUtxosStream",
                        request: args
                    )

                    for reply in replies {
                        let utxo = UTXO(
                            address: reply.address,
                            prevoutTxId: reply.txid,
                            prevoutIndex: Int(reply.index),
                            script: reply.script,
                            valueZat: Int(reply.valueZat),
                            height: Int(reply.height)
                        )
                        continuation.yield(utxo)
                    }
                    continuation.finish()
                } catch {
                    let serviceError = error as? LightWalletServiceError ?? LightWalletServiceError.genericError(error: error)
                    continuation.finish(throwing: ZcashError.serviceFetchUTXOsFailed(serviceError))
                }
            }
        }
    }

    override func blockStream(
        startHeight: BlockHeight,
        endHeight: BlockHeight,
        mode: ServiceMode
    ) throws -> AsyncThrowingStream<ZcashCompactBlock, Error> {
        guard mode == .direct, let client = ohttpClient else {
            return try super.blockStream(startHeight: startHeight, endHeight: endHeight, mode: mode)
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let blocks: [CompactBlock] = try await client.serverStreaming(
                        path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetBlockRange",
                        request: BlockRange(startHeight: startHeight, endHeight: endHeight)
                    )

                    for block in blocks {
                        continuation.yield(ZcashCompactBlock(compactBlock: block))
                    }
                    continuation.finish()
                } catch {
                    let serviceError = error as? LightWalletServiceError ?? LightWalletServiceError.genericError(error: error)
                    continuation.finish(throwing: ZcashError.serviceBlockStreamFailed(serviceError))
                }
            }
        }
    }

    override func getMempoolStream() throws -> AsyncThrowingStream<RawTransaction, Error> {
        // Note: getMempoolStream doesn't take a mode parameter in the protocol
        // For consistency, we use OHTTP if available
        guard let client = ohttpClient else {
            return try super.getMempoolStream()
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let transactions: [RawTransaction] = try await client.serverStreaming(
                        path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetMempoolStream",
                        request: Empty()
                    )

                    for tx in transactions {
                        continuation.yield(tx)
                    }
                    continuation.finish()
                } catch {
                    let serviceError = error as? LightWalletServiceError ?? LightWalletServiceError.genericError(error: error)
                    continuation.finish(throwing: ZcashError.serviceGetMempoolStreamFailed(serviceError))
                }
            }
        }
    }

    override func getSubtreeRoots(_ request: GetSubtreeRootsArg, mode: ServiceMode) throws -> AsyncThrowingStream<SubtreeRoot, Error> {
        guard mode == .direct, let client = ohttpClient else {
            return try super.getSubtreeRoots(request, mode: mode)
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let roots: [SubtreeRoot] = try await client.serverStreaming(
                        path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetSubtreeRoots",
                        request: request
                    )

                    for root in roots {
                        continuation.yield(root)
                    }
                    continuation.finish()
                } catch {
                    let serviceError = error as? LightWalletServiceError ?? LightWalletServiceError.genericError(error: error)
                    continuation.finish(throwing: ZcashError.serviceSubtreeRootsStreamFailed(serviceError))
                }
            }
        }
    }

    override func getTreeState(_ id: BlockID, mode: ServiceMode) async throws -> TreeState {
        guard mode == .direct, let client = ohttpClient else {
            return try await super.getTreeState(id, mode: mode)
        }

        return try await client.unary(
            path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetTreeState",
            request: id
        )
    }

    override func getTaddressTransactions(_ request: TransparentAddressBlockFilter, mode: ServiceMode) throws -> AsyncThrowingStream<RawTransaction, Error> {
        guard mode == .direct, let client = ohttpClient else {
            return try super.getTaddressTransactions(request, mode: mode)
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let transactions: [RawTransaction] = try await client.serverStreaming(
                        path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetTaddressTxids",
                        request: request
                    )

                    for tx in transactions {
                        continuation.yield(tx)
                    }
                    continuation.finish()
                } catch {
                    let serviceError = error as? LightWalletServiceError ?? LightWalletServiceError.genericError(error: error)
                    continuation.finish(throwing: ZcashError.serviceGetTaddressTxidsFailed(serviceError))
                }
            }
        }
    }

    override func closeConnections() async {
        // OHTTP uses URLSession with no persistent connection, so nothing to close
        await super.closeConnections()
    }
}
