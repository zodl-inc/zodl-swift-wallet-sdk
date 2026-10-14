import Foundation
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

struct ClassicProcessorCleanupFixture {
    let rootDirectory: URL
    let synchronizer: SDKSynchronizer
    let encoder: ClassicProcessorCleanupEncoder
    let storage: CompactBlockRepositoryMock
    let backend: ZcashRustBackendWeldingMock
    let repository: TransactionRepositoryMock
    let service: LightWalletServiceMock
    let downloader: BlockDownloaderMock
    let container: DIContainer
    let latest: LatestBlocksDataProviderMock

    static func make(storageDirectory: URL) async throws -> ClassicProcessorCleanupFixture {
        let container = DIContainer()
        container.isTestEnvironment = true
        let backend = ZcashRustBackendWeldingMock()
        let account = Account(
            id: TestsData.mockedAccountUUID,
            name: "Gift card",
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
            uivk: nil
        )
        backend.listAccountsReturnValue = [account]
        let balance = AccountBalance(
            saplingBalance: .zero,
            orchardBalance: PoolBalance(spendableValue: Zatoshi(50_000), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
            unshielded: .zero
        )
        backend.getWalletSummaryReturnValue = WalletSummary(
            accountBalances: [account.id: balance],
            chainTipHeight: 3_000_010,
            fullyScannedHeight: 3_000_010,
            recoveryProgress: nil,
            scanProgress: nil,
            nextSaplingSubtreeIndex: 0,
            nextOrchardSubtreeIndex: 0,
            nextIronwoodSubtreeIndex: 0
        )
        let service = LightWalletServiceMock()
        service.getTreeStateModeThrowableError = LightWalletServiceError.timeOut
        service.getMempoolStreamClosure = { AsyncThrowingStream { $0.finish() } }
        service.closeConnectionsClosure = { }
        let repository = TransactionRepositoryMock()
        repository.closeDBConnectionClosure = { }
        repository.findForResubmissionUpToReturnValue = []
        let storage = CompactBlockRepositoryMock()
        storage.clearClosure = { }
        let latest = LatestBlocksDataProviderMock()
        latest.underlyingLatestBlockHeight = 3_000_010
        latest.underlyingFullyScannedHeight = 3_000_010
        latest.underlyingMaxScannedHeight = 3_000_010
        latest.underlyingWalletBirthday = 3_000_000
        latest.resetClosure = { }
        latest.updateScannedDataClosure = { }
        latest.updateBlockDataClosure = { }
        container.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in backend }
        container.mock(type: LightWalletService.self, isSingleton: true) { _ in service }
        container.mock(type: TransactionRepository.self, isSingleton: true) { _ in repository }
        container.mock(type: CompactBlockRepository.self, isSingleton: true) { _ in storage }
        container.mock(type: LatestBlocksDataProvider.self, isSingleton: true) { _ in latest }
        let downloader = BlockDownloaderMock()
        downloader.stopDownloadClosure = { }
        downloader.rewindLatestDownloadedBlockHeightClosure = { _ in }
        container.mock(type: BlockDownloader.self, isSingleton: true) { _ in downloader }
        let encoder = ClassicProcessorCleanupEncoder()
        let alias = ZcashSynchronizerAlias.custom("classic-cleanup-\(UUID().uuidString)")
        let rootDirectory = storageDirectory.appendingPathComponent(alias.description, isDirectory: true)
        let initializer = Initializer(
            container: container,
            cacheDbURL: nil,
            fsBlockDbRoot: rootDirectory.appendingPathComponent("fs_cache", isDirectory: true),
            generalStorageURL: rootDirectory.appendingPathComponent("general_storage", isDirectory: true),
            dataDbURL: rootDirectory.appendingPathComponent("data.db"),
            torDirURL: rootDirectory.appendingPathComponent("tor", isDirectory: true),
            endpoint: LightWalletEndpointBuilder.default,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: rootDirectory.appendingPathComponent("sapling-spend.params"),
            outputParamsURL: rootDirectory.appendingPathComponent("sapling-output.params"),
            saplingParamsSourceURL: .default,
            alias: alias,
            loggingPolicy: .noLogging,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
        let processor = CompactBlockProcessor(initializer: initializer, walletBirthdayProvider: { initializer.walletBirthday })
        let synchronizer = SDKSynchronizer(
            status: .stopped,
            initializer: initializer,
            transactionEncoder: encoder,
            transactionRepository: repository,
            blockProcessor: processor,
            syncSessionTicker: .live
        )
        await synchronizer.updateStatus(.synced)
        return ClassicProcessorCleanupFixture(
            rootDirectory: rootDirectory,
            synchronizer: synchronizer,
            encoder: encoder,
            storage: storage,
            backend: backend,
            repository: repository,
            service: service,
            downloader: downloader,
            container: container,
            latest: latest
        )
    }

    func prepareRoot() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    func cleanup() async throws {
        // The test owns this generic wallet's root. The real classic stop/wipe/resource
        // boundaries must drain every writer before that owner can remove its files.
        let cleanup = Task {
            await synchronizer.stopAndWait()
            try? await GiftCardRedeemer.awaitCompletion(of: synchronizer.wipe())
            try await synchronizer.closeGiftCardResources()
            if FileManager.default.fileExists(atPath: rootDirectory.path) {
                try FileManager.default.removeItem(at: rootDirectory)
            }
        }
        try await cleanup.value
    }
}

/// Keeps the classic processor fixture independent from migrated gift wallet construction.
final class ClassicProcessorCleanupEncoder: TransactionEncoder {
    var propose: (() async throws -> Proposal)?
    private(set) var createdTransactions: [CreatedTransaction] = []
    private(set) var submittedTransactions: [EncodedTransaction] = []

    func proposeSendMax(accountUUID: AccountUUID, recipient: String, memoBytes: MemoBytes?, mode: MaxSpendMode) async throws -> Proposal {
        if let propose { return try await propose() }
        return FfiProposalFixtures.makeProposal(steps: [FfiProposalFixtures.Step(inputValues: [50_000], changeValues: [], fee: 10_000)])
    }

    func requiresSaplingParameters(for proposal: Proposal) throws -> Bool { false }

    func createProposedTransactions(proposal: Proposal, spendingKey: UnifiedSpendingKey, ovkPolicy: OvkPolicy) async throws -> [CreatedTransaction] {
        let transaction = CreatedTransaction(txId: Data(repeating: 0xA1, count: 32), raw: Data([1]), expiryHeight: 3_000_100)
        createdTransactions.append(transaction)
        return [transaction]
    }

    func submit(transaction: EncodedTransaction) async throws {
        submittedTransactions.append(transaction)
    }

    func fetchTransactionsForTxIds(_ txIds: [Data]) async throws -> [ZcashTransaction.Overview] { [] }
    func closeDBConnection() { }
    func isTransactionKnownToServer(txId: Data) async -> Bool { false }
    func createdTransactions(forTxIds txIds: [Data]) async throws -> [CreatedTransaction] { createdTransactions }
    func proposeTransfer(accountUUID: AccountUUID, recipient: String, amount: Zatoshi, memoBytes: MemoBytes?) async throws -> Proposal {
        throw ZcashError.giftCardNothingToRedeem
    }
    func proposeOrchardToIronwoodMigration(accountUUID: AccountUUID) async throws -> Proposal {
        throw ZcashError.giftCardNothingToRedeem
    }
    func proposeShielding(accountUUID: AccountUUID, shieldingThreshold: Zatoshi, memoBytes: MemoBytes?, transparentReceiver: String?) async throws -> Proposal? {
        throw ZcashError.giftCardNothingToRedeem
    }
    func proposeFulfillingPaymentFromURI(_ uri: String, accountUUID: AccountUUID) async throws -> Proposal {
        throw ZcashError.giftCardNothingToRedeem
    }
}
