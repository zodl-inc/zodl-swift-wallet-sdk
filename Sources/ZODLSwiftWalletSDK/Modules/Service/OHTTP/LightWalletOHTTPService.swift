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
    private let clients = OHTTPClientPool()
    private let torClient: TorClient
    private let gatewayHost: String?
    private let gatewayRelayURL: String?
    private let singleCallTimeoutMS: Int64
    private let streamingCallTimeoutMS: Int64
    /// The wallet's network. When set, a gateway of the other network is refused before any request.
    var walletNetwork: NetworkType?

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

        // Store gateway configuration but defer OHTTPTransport creation until first use
        if OHTTPEndpoints.isGateway(endpoint.host) {
            self.gatewayHost = endpoint.host
            self.gatewayRelayURL = try? OHTTPEndpoints.relayURL(for: endpoint.host)
        } else {
            self.gatewayHost = nil
            self.gatewayRelayURL = nil
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

        // Store gateway configuration but defer OHTTPTransport creation until first use
        if OHTTPEndpoints.isGateway(endpoint.host) {
            self.gatewayHost = endpoint.host
            self.gatewayRelayURL = try? OHTTPEndpoints.relayURL(for: endpoint.host)
        } else {
            self.gatewayHost = nil
            self.gatewayRelayURL = nil
        }

        super.init(
            endpoint: endpoint,
            singleCallTimeout: singleCallTimeout,
            streamingCallTimeout: streamingCallTimeout,
            tor: tor
        )
        self.sdkFlags = sdkFlags
    }

    /// The OHTTP client for a call in `mode`, or nil when the endpoint is not a gateway.
    ///
    /// A gateway is only ever reached through its relay, whatever the mode: a Tor mode, or `.direct` while
    /// Tor is enabled, puts the relay leg on Tor, never on a plain connection to the gateway host. The Tor
    /// circuit follows the mode: `.direct` and `.defaultTor` (block ranges, tree states, chain tip) share
    /// one circuit, each `.torInGroup` name has its own, and `.uniqueTor` gets a new one per call.
    private func ensureOHTTPClient(mode: ServiceMode) async throws -> OHTTPGRPCClient? {
        guard let host = gatewayHost, let relayURL = gatewayRelayURL else {
            return nil
        }
        if let walletNetwork {
            try OHTTPEndpoints.checkGatewayNetwork(host: host, network: walletNetwork)
        }

        let isTorEnabled = await sdkFlags?.torEnabled ?? false
        let circuit: String?
        switch mode {
        case .direct:
            circuit = isTorEnabled ? Self.sharedCircuit : nil
        case .defaultTor:
            circuit = Self.sharedCircuit
        case .torInGroup(let group):
            circuit = "group:\(group)"
        case .uniqueTor:
            circuit = nil
        }

        if mode != .uniqueTor, let existing = await clients.client(for: circuit) {
            return existing
        }

        let httpSender: OHTTPTransport.HTTPSender
        let viaTor = mode == .uniqueTor || circuit != nil
        if viaTor {
            let isolated = try await torClient.isolatedClient()
            // C-08: a sealed request is never resent (the gateway answers a repeated nonce with 409); it is
            // tried again, on a new circuit, only when it failed before any of it was sent.
            httpSender = { request, maxBytes in
                try await isolated.httpRequestSentOnce(for: request, maxBytes: maxBytes)
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
            clientTraceIdPrefix: OHTTPEndpoints.effectiveClientTraceIdPrefix,
            viaTor: viaTor,
            httpSender: httpSender
        )

        let client = OHTTPGRPCClient(
            authority: host,
            transport: transport,
            singleCallTimeoutMS: Int(singleCallTimeoutMS),
            streamingCallTimeoutMS: Int(streamingCallTimeoutMS)
        )

        if mode != .uniqueTor {
            await clients.store(client, for: circuit)
        }
        return client
    }

    /// The circuit name of the calls that carry public, non-identifying chain data.
    private static let sharedCircuit = "shared"

    /// The longest `GetBlockRange` span asked of the gateway in one exchange (ZIP "Deployment": the
    /// client's span is 2 000 blocks); a longer range is fetched in halves.
    private static let maximumSpan = 2000

    /// Below this many blocks a `GetBlockRange` refused with INVALID_ARGUMENT is not split any further:
    /// the gateway's span limit (reference 10 000 blocks) is above it, so the refusal has another cause.
    private static let minimumSplitSpan = 1000

    /// The blocks `start...end`, in halves while the span is above `maximumSpan` or when the gateway
    /// refuses it with INVALID_ARGUMENT (its own span limit).
    private func fetchBlocks(_ client: OHTTPGRPCClient, from start: BlockHeight, to end: BlockHeight) async throws -> [CompactBlock] {
        if end - start >= Self.maximumSpan {
            return try await fetchHalves(client, from: start, to: end)
        }
        do {
            return try await client.serverStreaming(
                path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetBlockRange",
                request: BlockRange(startHeight: start, endHeight: end)
            )
        } catch LightWalletServiceError.failed(let code, _) where code == OHTTPGRPCStatus.invalidArgument && end - start >= Self.minimumSplitSpan {
            return try await fetchHalves(client, from: start, to: end)
        }
    }

    private func fetchHalves(_ client: OHTTPGRPCClient, from start: BlockHeight, to end: BlockHeight) async throws -> [CompactBlock] {
        let middle = start + (end - start) / 2
        let lower = try await fetchBlocks(client, from: start, to: middle)
        let upper = try await fetchBlocks(client, from: middle + 1, to: end)
        return lower + upper
    }

    // MARK: - LightWalletService Protocol

    override func getInfo(mode: ServiceMode) async throws -> LightWalletdInfo {
        guard let client = try await ensureOHTTPClient(mode: mode) else {
            return try await super.getInfo(mode: mode)
        }

        do {
            let info: LightdInfo = try await client.unary(
                path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLightdInfo",
                request: Empty()
            )
            return info
        } catch {
            let serviceError = error as? LightWalletServiceError ?? LightWalletServiceError.genericError(error: error)
            throw ZcashError.serviceGetInfoFailed(serviceError)
        }
    }

    override func latestBlock(mode: ServiceMode) async throws -> BlockID {
        guard let client = try await ensureOHTTPClient(mode: mode) else {
            return try await super.latestBlock(mode: mode)
        }

        do {
            return try await client.unary(
                path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLatestBlock",
                request: ChainSpec()
            )
        } catch {
            let serviceError = error as? LightWalletServiceError ?? LightWalletServiceError.genericError(error: error)
            throw ZcashError.serviceLatestBlockFailed(serviceError)
        }
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

                    let blocks = try await self.fetchBlocks(client, from: range.lowerBound, to: range.upperBound)

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

        do {
            var transaction = RawTransaction()
            transaction.data = spendTransaction
            let response: SendResponse = try await client.unary(
                path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/SendTransaction",
                request: transaction
            )
            return response
        } catch {
            let serviceError = error as? LightWalletServiceError ?? LightWalletServiceError.genericError(error: error)
            throw ZcashError.serviceSubmitFailed(serviceError)
        }
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

                    let blocks = try await self.fetchBlocks(client, from: startHeight, to: endHeight)

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

    /// lightwalletd keeps `GetMempoolStream` open until the next block, longer than one OHTTP exchange
    /// can last (`grpc-timeout` 75 s, gateway upstream cut 80 s), so a gateway endpoint refuses the call
    /// before anything is sent.
    override func getMempoolStream() throws -> AsyncThrowingStream<RawTransaction, Error> {
        guard gatewayHost == nil else {
            throw ZcashError.serviceGetMempoolStreamFailed(
                LightWalletServiceError.generalError(message: "GetMempoolStream is not available over OHTTP")
            )
        }
        return try super.getMempoolStream()
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

/// The OHTTP clients of one service, by Tor circuit (nil: no Tor). Each keeps its transport, and so its
/// relay connection; the key configuration itself is shared process-wide (`OHTTPKeyCache`).
private actor OHTTPClientPool {
    private var clients: [String: OHTTPGRPCClient] = [:]

    func client(for circuit: String?) -> OHTTPGRPCClient? {
        clients[circuit ?? ""]
    }

    func store(_ client: OHTTPGRPCClient, for circuit: String?) {
        clients[circuit ?? ""] = client
    }
}
