import Foundation
import os

/// A stable service identity for consumers that outlive an endpoint selection. Each RPC snapshots
/// its delegate before starting work, so replacement never holds a lock across network work.
final class RebindingLightWalletService: LightWalletService {
    private struct State {
        var service: LightWalletService
        var connectionStateChange: ((ConnectionState, ConnectionState) -> Void)?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(service: LightWalletService) {
        state = OSAllocatedUnfairLock(uncheckedState: State(service: service, connectionStateChange: service.connectionStateChange))
        observeConnections(of: service)
    }

    /// Also used by legacy service-aware Tor access, without changing which services support Tor.
    var currentService: LightWalletService {
        state.withLockUnchecked { $0.service }
    }

    var connectionStateChange: ((ConnectionState, ConnectionState) -> Void)? {
        get { state.withLockUnchecked { $0.connectionStateChange } }
        set { state.withLockUnchecked { $0.connectionStateChange = newValue } }
    }

    func replace(with service: LightWalletService) {
        guard service !== currentService else { return }
        observeConnections(of: service)
        let retired = state.withLockUnchecked { state in
            let retired = state.service
            state.service = service
            return retired
        }
        // Capture the retired concrete service, never the binding: a later replacement must not
        // redirect this teardown to the new connection.
        Task { await retired.closeConnections() }
    }

    private func observeConnections(of service: LightWalletService) {
        service.connectionStateChange = { [weak self, weak service] from, to in
            guard let self, let service else { return }
            let callback = self.state.withLockUnchecked { state in
                state.service === service ? state.connectionStateChange : nil
            }
            callback?(from, to)
        }
    }

    func getInfo(mode: ServiceMode) async throws -> LightWalletdInfo {
        try await currentService.getInfo(mode: mode)
    }

    func latestBlock(mode: ServiceMode) async throws -> BlockID {
        try await currentService.latestBlock(mode: mode)
    }

    func latestBlockHeight(mode: ServiceMode) async throws -> BlockHeight {
        try await currentService.latestBlockHeight(mode: mode)
    }

    func blockRange(_ range: CompactBlockRange, mode: ServiceMode) throws -> AsyncThrowingStream<ZcashCompactBlock, Error> {
        try currentService.blockRange(range, mode: mode)
    }

    func submit(spendTransaction: Data, mode: ServiceMode) async throws -> LightWalletServiceResponse {
        try await currentService.submit(spendTransaction: spendTransaction, mode: mode)
    }

    func fetchTransaction(txId: Data, mode: ServiceMode) async throws -> (tx: ZcashTransaction.Fetched?, status: TransactionStatus) {
        try await currentService.fetchTransaction(txId: txId, mode: mode)
    }

    func fetchUTXOs(for tAddress: String, height: BlockHeight, mode: ServiceMode) throws -> AsyncThrowingStream<UnspentTransactionOutputEntity, Error> {
        try currentService.fetchUTXOs(for: tAddress, height: height, mode: mode)
    }

    func fetchUTXOs(for tAddresses: [String], height: BlockHeight, mode: ServiceMode) throws -> AsyncThrowingStream<UnspentTransactionOutputEntity, Error> {
        try currentService.fetchUTXOs(for: tAddresses, height: height, mode: mode)
    }

    func blockStream(startHeight: BlockHeight, endHeight: BlockHeight, mode: ServiceMode) throws -> AsyncThrowingStream<ZcashCompactBlock, Error> {
        try currentService.blockStream(startHeight: startHeight, endHeight: endHeight, mode: mode)
    }

    func closeConnections() async {
        await currentService.closeConnections()
    }

    func getSubtreeRoots(_ request: GetSubtreeRootsArg, mode: ServiceMode) throws -> AsyncThrowingStream<SubtreeRoot, Error> {
        try currentService.getSubtreeRoots(request, mode: mode)
    }

    func getTreeState(_ id: BlockID, mode: ServiceMode) async throws -> TreeState {
        try await currentService.getTreeState(id, mode: mode)
    }

    func getTaddressTransactions(_ request: TransparentAddressBlockFilter, mode: ServiceMode) throws -> AsyncThrowingStream<RawTransaction, Error> {
        try currentService.getTaddressTransactions(request, mode: mode)
    }

    func getMempoolStream() throws -> AsyncThrowingStream<RawTransaction, Error> {
        try currentService.getMempoolStream()
    }

    func checkSingleUseTransparentAddresses(
        dbData: (String, UInt),
        networkType: NetworkType,
        accountUUID: AccountUUID,
        mode: ServiceMode
    ) async throws -> TransparentAddressCheckResult {
        try await currentService.checkSingleUseTransparentAddresses(dbData: dbData, networkType: networkType, accountUUID: accountUUID, mode: mode)
    }

    // swiftlint:disable:next function_parameter_count
    func updateTransparentAddressTransactions(
        address: String,
        start: BlockHeight,
        end: BlockHeight,
        dbData: (String, UInt),
        networkType: NetworkType,
        mode: ServiceMode
    ) async throws -> TransparentAddressCheckResult {
        try await currentService.updateTransparentAddressTransactions(
            address: address, start: start, end: end, dbData: dbData, networkType: networkType, mode: mode
        )
    }

    func fetchUTXOsByAddress(
        address: String,
        dbData: (String, UInt),
        networkType: NetworkType,
        accountUUID: AccountUUID,
        mode: ServiceMode
    ) async throws -> TransparentAddressCheckResult {
        try await currentService.fetchUTXOsByAddress(address: address, dbData: dbData, networkType: networkType, accountUUID: accountUUID, mode: mode)
    }
}
