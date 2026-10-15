//
//  LightWalletOHTTPService.swift
//  ZODLSwiftWalletSDK
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
// swiftlint:disable:next type_body_length
final class LightWalletOHTTPService: LightWalletGRPCServiceOverTor {
    private var ohttpClientClearnet: OHTTPGRPCClient?
    private var ohttpClientTor: OHTTPGRPCClient?
    private let torClient: TorClient
    private var httpTor: TorClient?
    private let gatewayHost: String?
    private let gatewayRelayURL: String?
    private let gatewayKeyConfigURL: String?
    private let singleCallTimeoutMS: Int64
    private let streamingCallTimeoutMS: Int64
    private let sdkFlags: SDKFlags?

    // `init(endpoint:tor:)` is inherited from the superclass: this class overrides its only
    // designated initializer, so the superclass convenience initializers come along.
    override init(
        endpoint: LightWalletEndpoint,
        singleCallTimeout: Int64,
        streamingCallTimeout: Int64,
        tor: TorClient
    ) {
        self.torClient = tor
        self.singleCallTimeoutMS = singleCallTimeout
        self.streamingCallTimeoutMS = streamingCallTimeout
        self.sdkFlags = nil

        // Store gateway configuration but defer OHTTPTransport creation until first use
        if OHTTPEndpoints.isGateway(endpoint.host) {
            self.gatewayHost = endpoint.host
            do {
                self.gatewayRelayURL = try OHTTPEndpoints.relayURL(for: endpoint.host)
                self.gatewayKeyConfigURL = OHTTPEndpoints.keyConfigURL(for: endpoint.host)
            } catch {
                self.gatewayRelayURL = nil
                self.gatewayKeyConfigURL = nil
            }
        } else {
            self.gatewayHost = nil
            self.gatewayRelayURL = nil
            self.gatewayKeyConfigURL = nil
        }

        super.init(
            endpoint: endpoint,
            singleCallTimeout: singleCallTimeout,
            streamingCallTimeout: streamingCallTimeout,
            tor: tor
        )
    }

    /// Internal init that accepts SDKFlags for Tor detection
    init(
        endpoint: LightWalletEndpoint,
        singleCallTimeout: Int64,
        streamingCallTimeout: Int64,
        tor: TorClient,
        sdkFlags: SDKFlags
    ) {
        self.torClient = tor
        self.singleCallTimeoutMS = singleCallTimeout
        self.streamingCallTimeoutMS = streamingCallTimeout
        self.sdkFlags = sdkFlags

        // Store gateway configuration but defer OHTTPTransport creation until first use
        if OHTTPEndpoints.isGateway(endpoint.host) {
            self.gatewayHost = endpoint.host
            do {
                self.gatewayRelayURL = try OHTTPEndpoints.relayURL(for: endpoint.host)
                self.gatewayKeyConfigURL = OHTTPEndpoints.keyConfigURL(for: endpoint.host)
            } catch {
                self.gatewayRelayURL = nil
                self.gatewayKeyConfigURL = nil
            }
        } else {
            self.gatewayHost = nil
            self.gatewayRelayURL = nil
            self.gatewayKeyConfigURL = nil
        }

        super.init(
            endpoint: endpoint,
            singleCallTimeout: singleCallTimeout,
            streamingCallTimeout: streamingCallTimeout,
            tor: tor
        )
    }

    /// Ensures the OHTTP client is initialized with the appropriate HTTP sender.
    /// When Tor is globally enabled (via SDKFlags), we use a Tor-backed HTTP sender
    /// for the OHTTP transport so that both the key-config GET and all relay POSTs
    /// go through Tor, preventing device IP leakage.
    ///
    /// When mode != .direct, returns nil to fall back to parent's TorLwdConn implementation.
    private func ensureOHTTPClient(mode: ServiceMode) async throws -> OHTTPGRPCClient? {
        // Only use OHTTP for .direct mode; other modes use TorLwdConn
        guard mode == .direct else {
            return nil
        }

        guard let host = gatewayHost,
              let relayURL = gatewayRelayURL,
              let keyConfigURL = gatewayKeyConfigURL else {
            return nil
        }

        // Check if Tor is globally enabled
        let isTorEnabled = sdkFlags != nil ? await sdkFlags!.torEnabled : false

        // Return cached client if we have one for the current Tor state
        if isTorEnabled, let existing = ohttpClientTor {
            return existing
        }
        if !isTorEnabled, let existing = ohttpClientClearnet {
            return existing
        }

        let httpSender: OHTTPTransport.HTTPSender
        if isTorEnabled {
            // Tor-backed sender: isolate a Tor client for OHTTP HTTP requests
            if httpTor == nil {
                httpTor = try await torClient.isolatedClient()
            }
            guard let torClient = httpTor else {
                throw ZcashError.torClientUnavailable
            }

            // C-08 fix: OHTTP ciphertext must not be retried at transport layer.
            // OHTTPTransport seals every attempt afresh, each with its own ephemeral key and nonce.
            // If Tor retried (retryLimit > 0), the SAME ciphertext would be re-sent, violating
            // nonce-once. Gateway replay cache detects duplicate nonce and returns 409. Setting retryLimit: 0
            // means the Tor transport only attempts once; if it fails, the error propagates up to the OHTTP
            // layer. The OHTTP layer has its own retry for key rotation (HTTP 400/422), which is safe because
            // it re-encapsulates (new nonce, new ciphertext).
            httpSender = { request, maxBytes in
                return try await torClient.httpRequest(for: request, maxBytes: maxBytes, retryLimit: 0)
            }
        } else {
            // Clearnet sender: use the hardened session (ephemeral, no cookies, no cache, refuses redirects)
            // with bounded response reading per ZIP MUST requirement
            httpSender = { request, maxBytes in
                let (data, response) = try await OHTTPTransport.boundedData(
                    for: request,
                    maxBytes: maxBytes
                )
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OHTTPError.transportError("Invalid response type")
                }
                return (data, httpResponse)
            }
        }

        let transport = OHTTPTransport(
            gatewayHost: host,
            relayURL: relayURL,
            keyConfigURL: keyConfigURL,
            clientTraceIdPrefix: OHTTPEndpoints.clientTraceIdPrefix,
            httpSender: httpSender
        )

        let client = OHTTPGRPCClient(
            authority: host,
            transport: transport,
            singleCallTimeoutMS: Int(singleCallTimeoutMS),
            streamingCallTimeoutMS: Int(streamingCallTimeoutMS)
        )

        // Cache the client for the current Tor state
        if isTorEnabled {
            ohttpClientTor = client
        } else {
            ohttpClientClearnet = client
        }

        return client
    }

    // MARK: - LightWalletService Protocol

    override func getInfo(mode: ServiceMode) async throws -> LightWalletdInfo {
        guard let client = try await ensureOHTTPClient(mode: mode) else {
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
        guard let client = try await ensureOHTTPClient(mode: mode) else {
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
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let client = try await self.ensureOHTTPClient(mode: mode) else {
                        // Fall back to parent implementation
                        for try await block in try super.blockRange(range, mode: mode) {
                            continuation.yield(block)
                        }
                        continuation.finish()
                        return
                    }

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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    override func submit(spendTransaction: Data, mode: ServiceMode) async throws -> LightWalletServiceResponse {
        guard let client = try await ensureOHTTPClient(mode: mode) else {
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
        guard let client = try await ensureOHTTPClient(mode: mode) else {
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
        guard !tAddresses.isEmpty else {
            return AsyncThrowingStream { continuation in continuation.finish() }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let client = try await self.ensureOHTTPClient(mode: mode) else {
                        // Fall back to parent implementation
                        for try await utxo in try super.fetchUTXOs(for: tAddresses, height: height, mode: mode) {
                            continuation.yield(utxo)
                        }
                        continuation.finish()
                        return
                    }

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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    override func blockStream(
        startHeight: BlockHeight,
        endHeight: BlockHeight,
        mode: ServiceMode
    ) throws -> AsyncThrowingStream<ZcashCompactBlock, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let client = try await self.ensureOHTTPClient(mode: mode) else {
                        // Fall back to parent implementation
                        for try await block in try super.blockStream(startHeight: startHeight, endHeight: endHeight, mode: mode) {
                            continuation.yield(block)
                        }
                        continuation.finish()
                        return
                    }

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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    override func getMempoolStream() throws -> AsyncThrowingStream<RawTransaction, Error> {
        // Note: getMempoolStream doesn't take a mode parameter in the protocol
        // We default to .direct mode for backward compatibility
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let client = try await self.ensureOHTTPClient(mode: .direct) else {
                        // Fall back to parent implementation
                        for try await tx in try super.getMempoolStream() {
                            continuation.yield(tx)
                        }
                        continuation.finish()
                        return
                    }

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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    override func getSubtreeRoots(_ request: GetSubtreeRootsArg, mode: ServiceMode) throws -> AsyncThrowingStream<SubtreeRoot, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let client = try await self.ensureOHTTPClient(mode: mode) else {
                        // Fall back to parent implementation
                        for try await root in try super.getSubtreeRoots(request, mode: mode) {
                            continuation.yield(root)
                        }
                        continuation.finish()
                        return
                    }

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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    override func getTreeState(_ id: BlockID, mode: ServiceMode) async throws -> TreeState {
        guard let client = try await ensureOHTTPClient(mode: mode) else {
            return try await super.getTreeState(id, mode: mode)
        }

        return try await client.unary(
            path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetTreeState",
            request: id
        )
    }

    override func getTaddressTransactions(_ request: TransparentAddressBlockFilter, mode: ServiceMode) throws -> AsyncThrowingStream<RawTransaction, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let client = try await self.ensureOHTTPClient(mode: mode) else {
                        // Fall back to parent implementation
                        for try await tx in try super.getTaddressTransactions(request, mode: mode) {
                            continuation.yield(tx)
                        }
                        continuation.finish()
                        return
                    }

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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    override func closeConnections() async {
        // OHTTP uses URLSession with no persistent connection, so nothing to close
        await super.closeConnections()
    }
}
