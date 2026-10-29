//
//  LightWalletOHTTPService.swift
//  ZODLSwiftWalletSDK
//
//  LightWalletService implementation over the OHTTP transport for a gateway endpoint, in every mode: a Tor
//  mode puts the relay leg on an isolated Tor circuit. The parent's FFI TorLwdConn path is for clearnet
//  servers only.
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
    /// The range RPC stays injectable so returned wire blocks can be validated offline.
    var blockRangeRPC: (OHTTPGRPCClient, BlockRange) async throws -> [CompactBlock] = { client, range in
        try await client.serverStreaming(
            path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetBlockRange",
            request: range
        )
    }

    var latestBlockRPC: (OHTTPGRPCClient, ChainSpec) async throws -> BlockID = { client, spec in
        try await client.unary(path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLatestBlock", request: spec)
    }
    var transactionRPC: (OHTTPGRPCClient, TxFilter) async throws -> RawTransaction = { client, filter in
        try await client.unary(path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetTransaction", request: filter)
    }
    var utxosRPC: (OHTTPGRPCClient, GetAddressUtxosArg) async throws -> [GetAddressUtxosReply] = { client, args in
        try await client.serverStreaming(path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetAddressUtxosStream", request: args)
    }
    private let torClient: TorClient
    private let gatewayHost: String?
    private let gatewayRelayURL: String?
    private let singleCallTimeoutMS: Int64
    private let streamingCallTimeoutMS: Int64
    /// The wallet's network. When set, a gateway of the other network is refused before any request.
    var walletNetwork: NetworkType?
    /// Test-only: replaces the hardened clearnet session as the relay sender of the clients made from now on.
    var testClearnetSender: OHTTPTransport.HTTPSender?
    /// Test-only: makes the relay sender of a Tor leg from the isolated client it would ride, instead of
    /// `TorClient.httpRequestSentOnce`, so a test can see which circuit each call was given.
    var testTorSender: ((TorClient) -> OHTTPTransport.HTTPSender)?
    /// Test-only: verifies the key configuration instead of the native code.
    var testKeyVerifier: OHTTPTransport.KeyVerifier?

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
        // Production services must set walletNetwork to validate gateway network binding (ZIP #10, lines 266-271).
        // Tests that need nil must explicitly set testKeyVerifier to skip the native check.
        guard let walletNetwork else {
            throw OHTTPError.transportError("walletNetwork must be set for OHTTP gateway services")
        }
        try OHTTPEndpoints.checkGatewayNetwork(host: host, network: walletNetwork)

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

        let viaTor = mode == .uniqueTor || circuit != nil
        if mode == .uniqueTor {
            return try await makeClient(host: host, relayURL: relayURL, viaTor: viaTor)
        }
        return try await clients.client(for: circuit) {
            try await self.makeClient(host: host, relayURL: relayURL, viaTor: viaTor)
        }
    }

    /// A client of the gateway `host` through `relayURL`, its relay leg on an isolated Tor circuit with
    /// `viaTor`, on the hardened clearnet session otherwise.
    private func makeClient(host: String, relayURL: String, viaTor: Bool) async throws -> OHTTPGRPCClient {
        let httpSender: OHTTPTransport.HTTPSender
        if viaTor {
            let isolated = try await torClient.isolatedClient()
            if let testTorSender {
                httpSender = testTorSender(isolated)
            } else {
                // C-08: a sealed request is never resent (the gateway answers a repeated nonce with 409); it is
                // tried again, on a new circuit, only when it failed before any of it was sent.
                // Apply 100s per-exchange deadline for non-streaming exchanges (streaming uses `streamSender`).
                httpSender = { request, maxBytes in
                    try await Self.withExchangeDeadline {
                        try await isolated.httpRequestSentOnce(for: request, maxBytes: maxBytes)
                    }
                }
            }
        } else if let testClearnetSender {
            httpSender = testClearnetSender
        } else {
            // Clearnet sender: use the hardened session (ephemeral, no cookies, no cache, refuses redirects)
            // with bounded response reading and 100s per-exchange deadline (non-streaming exchanges only)
            httpSender = { request, maxBytes in
                let (data, response) = try await OHTTPTransport.boundedDataWithDeadline(
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
            walletNetwork: walletNetwork,
            testKeyVerifier: testKeyVerifier,
            viaTor: viaTor,
            httpSender: httpSender
        )

        return OHTTPGRPCClient(
            authority: host,
            transport: transport,
            singleCallTimeoutMS: Int(singleCallTimeoutMS),
            streamingCallTimeoutMS: Int(streamingCallTimeoutMS)
        )
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
            return try await blockRangeRPC(client, BlockRange(startHeight: start, endHeight: end))
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
            return try await latestBlockRPC(client, ChainSpec())
        } catch {
            let serviceError = error as? LightWalletServiceError ?? LightWalletServiceError.genericError(error: error)
            throw ZcashError.serviceLatestBlockFailed(serviceError)
        }
    }

    override func latestBlockHeight(mode: ServiceMode) async throws -> BlockHeight {
        do {
            let blockID = try await latestBlock(mode: mode)
            guard let height = BlockHeight(serverHeight: blockID.height) else {
                throw LightWalletServiceError.generalError(message: "The server reported a latest block with a height the SDK can't use.")
            }
            return height
        } catch {
            throw ZcashError.serviceLatestBlockHeightFailed(error.mapToServiceError())
        }
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
                        continuation.yield(try ZcashCompactBlock(compactBlock: block))
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
            let rawTx = try await transactionRPC(client, txFilter)

            return ZcashTransaction.Fetched.returned(rawID: txId, raw: rawTx.data, atServerHeight: rawTx.height)
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

                    let replies = try await self.utxosRPC(client, args)

                    for reply in replies {
                        let utxo = try UTXO(reply: reply)
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
                        continuation.yield(try ZcashCompactBlock(compactBlock: block))
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

    /// Mempool long poll over OHTTP. The gateway ends it with grpc-status: 0 after ~25 seconds
    /// without messages, which the caller treats as "poll again later", not an error.
    override func getMempoolStream() throws -> AsyncThrowingStream<RawTransaction, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let client = try await self.ensureOHTTPClient(mode: .direct) else {
                        for try await tx in try super.getMempoolStream() {
                            continuation.yield(tx)
                        }
                        continuation.finish()
                        return
                    }

                    let empty = Empty()
                    let stream: AsyncThrowingStream<RawTransaction, Error> = try await client.serverStreamingIncremental(
                        path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetMempoolStream",
                        request: empty
                    )

                    for try await rawTx in stream {
                        continuation.yield(rawTx)
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

    // MARK: - Transparent-address checks

    // The wallet half (which address, its range, the storing) is `TransparentAddressWalletStore`; the server
    // half rides the OHTTP transport like every other RPC, so these never reach the Tor gRPC connector. In
    // Tor mode the synchronizers ask for `.uniqueTor`: each wallet-identifying call gets its own circuit.
    //
    // The two wallet steps of a single-use check (the address due, then the back-off after a check that
    // found nothing) are separate database handles around the network call, each reading the chain height
    // anew. The Tor path does both inside one handle, but outside a transaction too, so nothing is lost:
    // only the chain height the back-off is computed from may be a little newer here. Accepted as is.

    override func checkSingleUseTransparentAddresses(
        dbData: (String, UInt),
        networkType: NetworkType,
        accountUUID: AccountUUID,
        mode: ServiceMode
    ) async throws -> TransparentAddressCheckResult {
        guard let client = try await ensureOHTTPClient(mode: mode) else {
            return try await super.checkSingleUseTransparentAddresses(dbData: dbData, networkType: networkType, accountUUID: accountUUID, mode: mode)
        }

        guard let due = try await TransparentAddressWalletStore.singleUseAddressToCheck(
            dbData: dbData,
            networkType: networkType,
            accountUUID: accountUUID
        ) else {
            return .notFound
        }
        let found = try await storeTransactions(client, of: due.address, from: due.startHeight, to: due.endHeight, dbData: dbData, networkType: networkType)
        if !found {
            try await TransparentAddressWalletStore.scheduleNextSingleUseAddressCheck(
                address: due.address,
                dbData: dbData,
                networkType: networkType,
                accountUUID: accountUUID
            )
        }
        return found ? .found(due.address) : .notFound
    }

    // swiftlint:disable:next function_parameter_count
    override func updateTransparentAddressTransactions(
        address: String,
        start: BlockHeight,
        end: BlockHeight,
        dbData: (String, UInt),
        networkType: NetworkType,
        mode: ServiceMode
    ) async throws -> TransparentAddressCheckResult {
        guard let client = try await ensureOHTTPClient(mode: mode) else {
            return try await super.updateTransparentAddressTransactions(
                address: address,
                start: start,
                end: end,
                dbData: dbData,
                networkType: networkType,
                mode: mode
            )
        }

        // A negative end is open-ended, as `zcashlc_tor_lwd_conn_update_transparent_address_transactions` reads it.
        let found = try await storeTransactions(client, of: address, from: start, to: end < 0 ? nil : end, dbData: dbData, networkType: networkType)
        return found ? .found(address) : .notFound
    }

    override func fetchUTXOsByAddress(
        address: String,
        dbData: (String, UInt),
        networkType: NetworkType,
        accountUUID: AccountUUID,
        mode: ServiceMode
    ) async throws -> TransparentAddressCheckResult {
        guard let client = try await ensureOHTTPClient(mode: mode) else {
            return try await super.fetchUTXOsByAddress(
                address: address,
                dbData: dbData,
                networkType: networkType,
                accountUUID: accountUUID,
                mode: mode
            )
        }

        guard let start = try await TransparentAddressWalletStore.utxoStartHeight(
            address: address,
            dbData: dbData,
            networkType: networkType,
            accountUUID: accountUUID
        ) else {
            return .notFound
        }

        var args = GetAddressUtxosArg()
        args.addresses = [address]
        args.startHeight = UInt64(start)
        let replies: [GetAddressUtxosReply]
        do {
            replies = try await client.serverStreaming(
                path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetAddressUtxosStream",
                request: args
            )
        } catch {
            let serviceError = error as? LightWalletServiceError ?? LightWalletServiceError.genericError(error: error)
            throw ZcashError.serviceFetchUTXOsFailed(serviceError)
        }
        for reply in replies {
            try await TransparentAddressWalletStore.store(reply, dbData: dbData, networkType: networkType)
        }
        return replies.isEmpty ? .notFound : .found(address)
    }

    /// Fetches the transactions of `address` mined from `start` to `end` (nil: the chain tip) through
    /// `client`, stores each in the wallet, and returns whether there was one.
    // swiftlint:disable:next function_parameter_count
    private func storeTransactions(
        _ client: OHTTPGRPCClient,
        of address: String,
        from start: BlockHeight,
        to end: BlockHeight?,
        dbData: (String, UInt),
        networkType: NetworkType
    ) async throws -> Bool {
        var filter = TransparentAddressBlockFilter()
        filter.address = address
        filter.range = BlockRange(startHeight: start, endHeight: end)
        let transactions: [RawTransaction]
        do {
            transactions = try await client.serverStreaming(
                path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetTaddressTxids",
                request: filter
            )
        } catch {
            let serviceError = error as? LightWalletServiceError ?? LightWalletServiceError.genericError(error: error)
            throw ZcashError.serviceGetTaddressTxidsFailed(serviceError)
        }
        for transaction in transactions {
            try await TransparentAddressWalletStore.store(transaction, dbData: dbData, networkType: networkType)
        }
        return !transactions.isEmpty
    }

    /// Applies a 100-second per-exchange deadline to a non-streaming exchange.
    /// Streaming exchanges (mempool long poll, SSE) must not use this.
    private static func withExchangeDeadline<T>(
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        let deadlineSeconds: TimeInterval = 100
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(deadlineSeconds * 1_000_000_000))
                throw OHTTPError.transportError("Exchange deadline exceeded (100s)")
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    override func closeConnections() async {
        // OHTTP uses URLSession with no persistent connection, so nothing to close
        await super.closeConnections()
    }
}

/// The OHTTP clients of one service, by Tor circuit (nil: no Tor). Each keeps its transport, and so its
/// relay connection; the key configuration itself is shared process-wide (`OHTTPKeyCache`). A circuit's
/// client is made once: concurrent first calls wait for the one creation under way.
actor OHTTPClientPool {
    private var clients: [String: OHTTPGRPCClient] = [:]
    private var creations: [String: Task<OHTTPGRPCClient, Error>] = [:]

    /// The client of `circuit`, made by `make` when there is none and no creation is under way.
    func client(
        for circuit: String?,
        make: @escaping @Sendable () async throws -> OHTTPGRPCClient
    ) async throws -> OHTTPGRPCClient {
        let key = circuit ?? ""
        if let existing = clients[key] {
            return existing
        }
        if let running = creations[key] {
            return try await running.value
        }
        let creation = Task { try await make() }
        creations[key] = creation
        defer { creations[key] = nil }
        let client = try await creation.value
        clients[key] = client
        return client
    }
}
