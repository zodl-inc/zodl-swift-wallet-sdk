//
//  SynchronizerUsingDefaults.swift
//  TestUtils
//

import Combine
import Foundation
@testable import ZODLSwiftWalletSDK

/// A `Synchronizer` conformer that implements only the requirements without a protocol-extension default, so that a
/// test calling any other member reaches that member's default. None of its stubs run.
final class SynchronizerUsingDefaults: Synchronizer {
    private static func unused(_ member: StaticString = #function) -> Never {
        fatalError("SynchronizerUsingDefaults.\(member) is not exercised: only the protocol-extension defaults are")
    }

    var alias: ZcashSynchronizerAlias { Self.unused() }
    var latestState: SynchronizerState { Self.unused() }
    var connectionState: ConnectionState { Self.unused() }
    var stateStream: AnyPublisher<SynchronizerState, Never> { Self.unused() }
    var eventStream: AnyPublisher<SynchronizerEvent, Never> { Self.unused() }
    var exchangeRateUSDStream: AnyPublisher<FiatCurrencyResult?, Never> { Self.unused() }

    func prepare(
        with seed: [UInt8]?,
        walletBirthday: BlockHeight?,
        name: String,
        keySource: String?
    ) async throws -> Initializer.InitializationResult { Self.unused() }

    func start(retry: Bool) async throws { Self.unused() }
    func stop() { Self.unused() }

    func getSaplingAddress(accountUUID: AccountUUID) async throws -> SaplingAddress { Self.unused() }
    func getUnifiedAddress(accountUUID: AccountUUID) async throws -> UnifiedAddress { Self.unused() }
    func getTransparentAddress(accountUUID: AccountUUID) async throws -> TransparentAddress { Self.unused() }
    func getCustomUnifiedAddress(accountUUID: AccountUUID, receivers: Set<ReceiverType>) async throws -> UnifiedAddress { Self.unused() }

    func proposeTransfer(accountUUID: AccountUUID, recipient: Recipient, amount: Zatoshi, memo: Memo?) async throws -> Proposal { Self.unused() }

    func proposeSendMax(accountUUID: AccountUUID, recipient: Recipient, memo: Memo?, mode: MaxSpendMode) async throws -> Proposal { Self.unused() }

    func proposeOrchardToIronwoodMigration(accountUUID: AccountUUID) async throws -> Proposal { Self.unused() }

    func proposeShielding(
        accountUUID: AccountUUID,
        shieldingThreshold: Zatoshi,
        memo: Memo,
        transparentReceiver: TransparentAddress?
    ) async throws -> Proposal? { Self.unused() }

    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey
    ) async throws -> AsyncThrowingStream<TransactionSubmitResult, Error> { Self.unused() }

    func proposefulfillingPaymentURI(_ uri: String, accountUUID: AccountUUID) async throws -> Proposal { Self.unused() }

    func createPCZTFromProposal(accountUUID: AccountUUID, proposal: Proposal) async throws -> Pczt { Self.unused() }
    func redactPCZTForSigner(pczt: Pczt) async throws -> Pczt { Self.unused() }
    func PCZTRequiresSaplingProofs(pczt: Pczt) async -> Bool { Self.unused() }
    func addProofsToPCZT(pczt: Pczt) async throws -> Pczt { Self.unused() }

    func createTransactionFromPCZT(
        pcztWithProofs: Pczt,
        pcztWithSigs: Pczt
    ) async throws -> AsyncThrowingStream<TransactionSubmitResult, Error> { Self.unused() }

    var transactions: [ZcashTransaction.Overview] { get async { Self.unused() } }
    var sentTransactions: [ZcashTransaction.Overview] { get async { Self.unused() } }
    var receivedTransactions: [ZcashTransaction.Overview] { get async { Self.unused() } }

    func paginatedTransactions(of kind: TransactionKind) -> PaginatedTransactionRepository { Self.unused() }

    func getMemos(for rawID: Data) async throws -> [Memo] { Self.unused() }
    func getMemos(for transaction: ZcashTransaction.Overview) async throws -> [Memo] { Self.unused() }
    func getRecipients(for transaction: ZcashTransaction.Overview) async -> [TransactionRecipient] { Self.unused() }
    func getTransactionOutputs(for transaction: ZcashTransaction.Overview) async -> [ZcashTransaction.Output] { Self.unused() }
    func allTransactions() async throws -> [ZcashTransaction.Overview] { Self.unused() }
    func allTransactions(from transaction: ZcashTransaction.Overview, limit: Int) async throws -> [ZcashTransaction.Overview] { Self.unused() }
    func latestHeight() async throws -> BlockHeight { Self.unused() }
    func refreshUTXOs(address: TransparentAddress, from height: BlockHeight) async throws -> RefreshedUTXOs { Self.unused() }
    func getAccountsBalances() async throws -> [AccountUUID: AccountBalance] { Self.unused() }
    func refreshExchangeRateUSD() { Self.unused() }
    func listAccounts() async throws -> [Account] { Self.unused() }

    func importAccount(
        ufvk: String,
        seedFingerprint: [UInt8]?,
        zip32AccountIndex: Zip32AccountIndex?,
        purpose: AccountPurpose,
        name: String,
        keySource: String?,
        birthday: BlockHeight?
    ) async throws -> AccountUUID { Self.unused() }

    func fetchTxidsWithMemoContaining(searchTerm: String) async throws -> [Data] { Self.unused() }
    func rescanFrom(height: BlockHeight) async throws { Self.unused() }
    func rewind(_ policy: RewindPolicy) -> AnyPublisher<Void, Error> { Self.unused() }
    func wipe() -> AnyPublisher<Void, Error> { Self.unused() }
    func switchTo(endpoint: LightWalletEndpoint) async throws { Self.unused() }
    func isSeedRelevantToAnyDerivedAccount(seed: [UInt8]) async throws -> Bool { Self.unused() }

    func evaluateBestOf(
        endpoints: [LightWalletEndpoint],
        fetchThresholdSeconds: Double,
        nBlocksToFetch: UInt64,
        kServers: Int,
        network: NetworkType
    ) async -> [LightWalletEndpoint] { Self.unused() }

    func evaluateServerSwitch(
        current: LightWalletEndpoint,
        candidates: [LightWalletEndpoint],
        fetchThresholdSeconds: Double,
        nBlocksToFetch: UInt64,
        network: NetworkType
    ) async -> LightWalletEndpoint? { Self.unused() }

    func estimateBirthdayHeight(for date: Date) -> BlockHeight { Self.unused() }
    func estimateTimestamp(for height: BlockHeight) -> TimeInterval? { Self.unused() }
    func tor(enabled: Bool) async throws { Self.unused() }
    func exchangeRateOverTor(enabled: Bool) async throws { Self.unused() }
    func isTorSuccessfullyInitialized() async -> Bool? { Self.unused() }
    func httpRequestOverTor(for request: URLRequest, retryLimit: UInt8) async throws -> (data: Data, response: HTTPURLResponse) { Self.unused() }

    func httpGetOverTor(
        for request: URLRequest,
        retryLimit: UInt8,
        timeoutMilliseconds: UInt64
    ) async throws -> (data: Data, response: HTTPURLResponse) { Self.unused() }

    func debugDatabase(sql: String) -> String { Self.unused() }

    func getSingleUseTransparentAddress(accountUUID: AccountUUID) async throws -> SingleUseTransparentAddress { Self.unused() }
    func checkSingleUseTransparentAddresses(accountUUID: AccountUUID) async throws -> TransparentAddressCheckResult { Self.unused() }
    func updateTransparentAddressTransactions(address: String) async throws -> TransparentAddressCheckResult { Self.unused() }
    func fetchUTXOsBy(address: String, accountUUID: AccountUUID) async throws -> TransparentAddressCheckResult { Self.unused() }
    func enhanceTransactionBy(txId: TxId) async throws { Self.unused() }
    func deleteAccount(_ accountUUID: AccountUUID) async throws { Self.unused() }
}
