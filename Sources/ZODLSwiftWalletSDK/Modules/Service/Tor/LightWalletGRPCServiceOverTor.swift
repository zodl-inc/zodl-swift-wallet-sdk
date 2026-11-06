//
//  LightWalletGRPCServiceOverTor.swift
//  ZODLSwiftWalletSDK
//
//  Created by Lukáš Korba on 2025-04-08.
//

import Foundation

actor ServiceConnections {
    var tor: TorClient
    var endpointString: String?
    var groups: [String: TorLwdConn] = [:]
    var defaultTorLwdConn: TorLwdConn?

    init(endpoint: LightWalletEndpoint, tor: TorClient) {
        self.tor = tor
        endpointString = String(format: "%@://%@:%d", endpoint.secure ? "https" : "http", endpoint.host, endpoint.port)
    }

    func connectToLightwalletd(_ mode: ServiceMode) async throws -> TorLwdConn {
        guard let endpointString else {
            throw ZcashError.torServiceMissingEndpoint
        }

        if let budget = SubmissionBudget.current {
            return try await budget.connections.connection(endpoint: endpointString, tor: tor)
        }

        // uniqueTor
        if mode == .uniqueTor {
            return try await tor.connectToLightwalletd(endpoint: endpointString)
        } else if mode == .defaultTor {
            // defaultTor
            let connection: TorLwdConn

            if let defaultTorLwdConn {
                connection = defaultTorLwdConn
            } else {
                connection = try await tor.connectToLightwalletd(endpoint: endpointString)
                defaultTorLwdConn = connection
            }

            return connection
        } else if case let .torInGroup(groupName) = mode {
            // torInGroup
            guard let torInGroup = groups[groupName] else {
                let torInGroupNamed = try await tor.connectToLightwalletd(endpoint: endpointString)

                groups[groupName] = torInGroupNamed

                return torInGroupNamed
            }

            return torInGroup
        } else {
            throw ZcashError.torServiceUnresolvedMode
        }
    }

    func responseToTorFailure(_ mode: ServiceMode) async {
        if mode == .defaultTor {
            defaultTorLwdConn = nil
        } else if case let .torInGroup(groupName) = mode {
            groups.removeValue(forKey: groupName)
        }
    }

    func closeConnections() {
        groups.removeAll()
        defaultTorLwdConn = nil
    }
}

class LightWalletGRPCServiceOverTor: LightWalletGRPCService {
    var tor: TorClient
    let serviceConnections: ServiceConnections
    /// The SDK's Tor mode. While it is on, a `.direct` call goes over the default Tor connection instead of
    /// plain gRPC, and the streaming calls, which have no Tor transport here, are refused: nothing reaches
    /// the server outside Tor. Nil (no Tor mode known) leaves `.direct` as it is.
    var sdkFlags: SDKFlags?

    convenience init(endpoint: LightWalletEndpoint, tor: TorClient) {
        self.init(
            endpoint: endpoint,
            singleCallTimeout: endpoint.singleCallTimeoutInMillis,
            streamingCallTimeout: endpoint.streamingCallTimeoutInMillis,
            tor: tor
        )
    }

    convenience init(endpoint: LightWalletEndpoint, tor: TorClient, singleCallTimeout: Int64) {
        self.init(
            endpoint: endpoint,
            singleCallTimeout: singleCallTimeout,
            streamingCallTimeout: endpoint.streamingCallTimeoutInMillis,
            tor: tor
        )
    }

    init(
        endpoint: LightWalletEndpoint,
        singleCallTimeout: Int64,
        streamingCallTimeout: Int64,
        tor: TorClient
    ) {
        self.tor = tor
        serviceConnections = ServiceConnections(endpoint: endpoint, tor: tor)

        super.init(
            host: endpoint.host,
            port: endpoint.port,
            secure: endpoint.secure,
            singleCallTimeout: singleCallTimeout,
            streamingCallTimeout: streamingCallTimeout
        )
    }

    override func getInfo(mode: ServiceMode) async throws -> LightWalletdInfo {
        let mode = await resolvedMode(mode)
        guard mode != .direct else {
            return try await super.getInfo(mode: mode)
        }

        do {
            return try await serviceConnections.connectToLightwalletd(mode).getInfo()
        } catch {
            await serviceConnections.responseToTorFailure(mode)
            throw error
        }
    }

    override func latestBlockHeight(mode: ServiceMode) async throws -> BlockHeight {
        let mode = await resolvedMode(mode)
        guard mode != .direct else {
            return try await super.latestBlockHeight(mode: mode)
        }

        let blockID = try await latestBlock(mode: mode)

        // The same bound as the direct path applies: a height above `Int32.max` is not one the SDK can use.
        guard let blockHeight = BlockHeight(serverHeight: blockID.height) else {
            throw ZcashError.serviceLatestBlockHeightFailed(
                LightWalletServiceError.generalError(message: "The server reported a latest block with a height the SDK can't use.")
            )
        }

        return blockHeight
    }

    override func latestBlock(mode: ServiceMode) async throws -> BlockID {
        let mode = await resolvedMode(mode)
        guard mode != .direct else {
            return try await super.latestBlock(mode: mode)
        }

        do {
            return try await serviceConnections.connectToLightwalletd(mode).latestBlock()
        } catch {
            await serviceConnections.responseToTorFailure(mode)
            throw error
        }
    }

    override func submit(spendTransaction: Data, mode: ServiceMode) async throws -> LightWalletServiceResponse {
        let mode = await resolvedMode(mode)
        guard mode != .direct else {
            return try await super.submit(spendTransaction: spendTransaction, mode: mode)
        }

        do {
            return try await serviceConnections.connectToLightwalletd(mode).submit(spendTransaction: spendTransaction)
        } catch {
            await serviceConnections.responseToTorFailure(mode)
            throw ZcashError.serviceSubmitFailed(LightWalletServiceError.genericError(error: error))
        }
    }

    override func fetchTransaction(txId: Data, mode: ServiceMode) async throws -> (tx: ZcashTransaction.Fetched?, status: TransactionStatus) {
        let mode = await resolvedMode(mode)
        guard mode != .direct else {
            return try await super.fetchTransaction(txId: txId, mode: mode)
        }

        do {
            return try await serviceConnections.connectToLightwalletd(mode).fetchTransaction(txId: txId)
        } catch {
            await serviceConnections.responseToTorFailure(mode)
            throw error
        }
    }

    override func getTreeState(_ id: BlockID, mode: ServiceMode) async throws -> TreeState {
        let mode = await resolvedMode(mode)
        guard mode != .direct else {
            return try await super.getTreeState(id, mode: mode)
        }

        // The height is checked before a connection is asked for: a height the SDK can't use says nothing about the
        // connection, and failing on it must not drop a healthy one.
        guard let height = BlockHeight(serverHeight: id.height) else {
            throw ZcashError.rustTorLwdGetTreeState("The tree state was requested for a block height the SDK can't use.")
        }

        do {
            return try await serviceConnections.connectToLightwalletd(mode).getTreeState(height: height)
        } catch {
            await serviceConnections.responseToTorFailure(mode)
            throw error
        }
    }

    override func checkSingleUseTransparentAddresses(
        dbData: (String, UInt),
        networkType: NetworkType,
        accountUUID: AccountUUID,
        mode: ServiceMode
    ) async throws -> TransparentAddressCheckResult {
        let mode = await resolvedMode(mode)
        guard mode != .direct else {
            return try await super.checkSingleUseTransparentAddresses(dbData: dbData, networkType: networkType, accountUUID: accountUUID, mode: mode)
        }

        do {
            return try await serviceConnections.connectToLightwalletd(mode).checkSingleUseTransparentAddresses(
                dbData: dbData,
                networkType: networkType,
                accountUUID: accountUUID
            )
        } catch {
            await serviceConnections.responseToTorFailure(mode)
            throw error
        }
    }

    override func updateTransparentAddressTransactions(
        address: String,
        start: BlockHeight,
        end: BlockHeight,
        dbData: (String, UInt),
        networkType: NetworkType,
        mode: ServiceMode
    ) async throws -> TransparentAddressCheckResult {
        let mode = await resolvedMode(mode)
        guard mode != .direct else {
            return try await super.updateTransparentAddressTransactions(
                address: address,
                start: start,
                end: end,
                dbData: dbData,
                networkType: networkType,
                mode: mode
            )
        }

        do {
            return try await serviceConnections.connectToLightwalletd(mode).updateTransparentAddressTransactions(
                address: address,
                start: start,
                end: end,
                dbData: dbData,
                networkType: networkType
            )
        } catch {
            await serviceConnections.responseToTorFailure(mode)
            throw error
        }
    }

    override func fetchUTXOsByAddress(
        address: String,
        dbData: (String, UInt),
        networkType: NetworkType,
        accountUUID: AccountUUID,
        mode: ServiceMode
    ) async throws -> TransparentAddressCheckResult {
        let mode = await resolvedMode(mode)
        guard mode != .direct else {
            return try await super.fetchUTXOsByAddress(
                address: address,
                dbData: dbData,
                networkType: networkType,
                accountUUID: accountUUID,
                mode: mode
            )
        }

        do {
            return try await serviceConnections.connectToLightwalletd(mode).fetchUTXOsByAddress(
                address: address,
                dbData: dbData,
                networkType: networkType,
                accountUUID: accountUUID
            )
        } catch {
            await serviceConnections.responseToTorFailure(mode)
            throw error
        }
    }

    override func blockRange(_ range: CompactBlockRange, mode: ServiceMode) throws -> AsyncThrowingStream<ZcashCompactBlock, Error> {
        try refusedOverTor { try super.blockRange(range, mode: mode) }
    }

    override func fetchUTXOs(for tAddress: String, height: BlockHeight, mode: ServiceMode) throws -> AsyncThrowingStream<UnspentTransactionOutputEntity, Error> {
        try refusedOverTor { try super.fetchUTXOs(for: tAddress, height: height, mode: mode) }
    }

    override func fetchUTXOs(
        for tAddresses: [String],
        height: BlockHeight,
        mode: ServiceMode
    ) throws -> AsyncThrowingStream<UnspentTransactionOutputEntity, Error> {
        try refusedOverTor { try super.fetchUTXOs(for: tAddresses, height: height, mode: mode) }
    }

    override func blockStream(
        startHeight: BlockHeight,
        endHeight: BlockHeight,
        mode: ServiceMode
    ) throws -> AsyncThrowingStream<ZcashCompactBlock, Error> {
        try refusedOverTor { try super.blockStream(startHeight: startHeight, endHeight: endHeight, mode: mode) }
    }

    override func getMempoolStream() throws -> AsyncThrowingStream<RawTransaction, Error> {
        try refusedOverTor { try super.getMempoolStream() }
    }

    override func getSubtreeRoots(_ request: GetSubtreeRootsArg, mode: ServiceMode) throws -> AsyncThrowingStream<SubtreeRoot, Error> {
        try refusedOverTor { try super.getSubtreeRoots(request, mode: mode) }
    }

    override func getTaddressTransactions(
        _ request: TransparentAddressBlockFilter,
        mode: ServiceMode
    ) throws -> AsyncThrowingStream<RawTransaction, Error> {
        try refusedOverTor { try super.getTaddressTransactions(request, mode: mode) }
    }

    override func closeConnections() async {
        await super.closeConnections()
        await serviceConnections.closeConnections()
    }

    /// `mode`, except that `.direct` becomes `.defaultTor` while Tor mode is on.
    func resolvedMode(_ mode: ServiceMode) async -> ServiceMode {
        guard mode == .direct, let sdkFlags, await sdkFlags.torEnabled else {
            return mode
        }
        return .defaultTor
    }

    /// The stream `make` opens, unless Tor mode is on: the plain gRPC stream would leave Tor, so the call
    /// fails with ``ZcashError/grpcServiceCalledWithTorMode`` instead.
    private func refusedOverTor<Element>(
        _ make: @escaping () throws -> AsyncThrowingStream<Element, Error>
    ) throws -> AsyncThrowingStream<Element, Error> {
        guard let sdkFlags else {
            return try make()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if await sdkFlags.torEnabled {
                        throw ZcashError.grpcServiceCalledWithTorMode
                    }
                    for try await element in try make() {
                        continuation.yield(element)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
