import Foundation
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// Keeps the native restore boundary offline while exercising real Slipstream preparation.
actor GiftCardAnchorCapture {
    struct Call {
        let isRestore: Bool
        let birthday: BlockHeight
        let fallbackCheckpointHeight: BlockHeight
        let endpoint: LightWalletEndpoint
        let network: ZcashNetwork
        let torDirPath: String?
    }

    private(set) var calls: [Call] = []
    private var response: SlipstreamRestoreAnchor?

    func setResponse(_ response: SlipstreamRestoreAnchor?) {
        self.response = response
    }

    func resolve(
        isRestore: Bool,
        birthday: BlockHeight,
        fallbackCheckpointHeight: BlockHeight,
        endpoint: LightWalletEndpoint,
        network: ZcashNetwork,
        torDirPath: String?
    ) -> SlipstreamRestoreAnchor? {
        calls.append(Call(
            isRestore: isRestore,
            birthday: birthday,
            fallbackCheckpointHeight: fallbackCheckpointHeight,
            endpoint: endpoint,
            network: network,
            torDirPath: torDirPath
        ))
        return response
    }
}

actor GiftCardFixtureAccountState {
    let account: Account
    private var created = false

    init(account: Account) {
        self.account = account
    }

    func markCreated() {
        created = true
    }

    func accounts() -> [Account] {
        created ? [account] : []
    }
}

struct GiftCardSlipstreamFixture {
    let card: GiftCard
    let synchronizer: SlipstreamSynchronizer
    let initializer: Initializer
    let engine: GatedFakeSlipstreamEngine
    let backend: ZcashRustBackendWeldingMock
    let service: LightWalletServiceMock
    let repository: TransactionRepositoryMock
    let anchor: GiftCardAnchorCapture
    let storageRoot: URL
    let torDirectory: URL
    let account: Account
    let balance: AccountBalance

    static func make(storageDirectory: URL, isTorEnabled: Bool) async throws -> GiftCardSlipstreamFixture {
        let root = storageDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let torDirectory = root.appendingPathComponent("tor", isDirectory: true)
        let card = try GiftCard(link: GiftCardTests.zodlTestnetLink)
        let network = ZcashNetworkBuilder.network(for: .testnet)
        let endpoint = LightWalletEndpoint(address: "127.0.0.1", port: 1, secure: false)
        let account = Account(
            id: TestsData.mockedAccountUUID,
            name: "Gift card",
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
            uivk: nil
        )
        let balance = AccountBalance(
            saplingBalance: .zero,
            orchardBalance: PoolBalance(
                spendableValue: Zatoshi(50_000),
                changePendingConfirmation: .zero,
                valuePendingSpendability: .zero
            ),
            unshielded: .zero
        )
        let summary = WalletSummary(
            accountBalances: [account.id: balance],
            chainTipHeight: 3_000_010,
            fullyScannedHeight: 3_000_010,
            recoveryProgress: nil,
            scanProgress: nil,
            nextSaplingSubtreeIndex: 0,
            nextOrchardSubtreeIndex: 0,
            nextIronwoodSubtreeIndex: 0
        )
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 0, chainTip: 3_000_010))
        await engine.setNextWalletSummary(summary)

        let accountState = GiftCardFixtureAccountState(account: account)
        let backend = ZcashRustBackendWeldingMock()
        backend.initDataDbSeedReturnValue = DbInitResult.success
        backend.listAccountsClosure = { await accountState.accounts() }
        backend.createAccountSeedTreeStateRecoverUntilNameKeySourceClosure = { _, _, _, _, _ in
            await accountState.markCreated()
            return UnifiedSpendingKey(network: network.networkType, bytes: [])
        }
        let service = LightWalletServiceMock()
        let repository = TransactionRepositoryMock()
        repository.closeDBConnectionClosure = {}
        let storage = CompactBlockRepositoryMock()
        storage.createClosure = {}
        storage.clearClosure = {}
        let container = DIContainer()
        container.isTestEnvironment = true
        container.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in backend }
        container.mock(type: LightWalletService.self, isSingleton: true) { _ in service }
        container.mock(type: TransactionRepository.self, isSingleton: true) { _ in repository }
        container.mock(type: CompactBlockRepository.self, isSingleton: true) { _ in storage }

        let initializer = Initializer(
            container: container,
            cacheDbURL: nil,
            fsBlockDbRoot: root.appendingPathComponent("blocks", isDirectory: true),
            generalStorageURL: root.appendingPathComponent("general", isDirectory: true),
            dataDbURL: root.appendingPathComponent("data.db"),
            torDirURL: torDirectory,
            endpoint: endpoint,
            network: network,
            spendParamsURL: root.appendingPathComponent("sapling-spend.params"),
            outputParamsURL: root.appendingPathComponent("sapling-output.params"),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            loggingPolicy: .noLogging,
            isTorEnabled: isTorEnabled,
            isExchangeRateEnabled: false
        )
        let anchor = GiftCardAnchorCapture()
        let synchronizer = SlipstreamSynchronizer(
            initializer: initializer,
            alternateEndpoints: [],
            engine: engine,
            restoreAnchor: { isRestore, birthday, fallbackCheckpoint, endpoint, network, torDirPath in
                await anchor.resolve(
                    isRestore: isRestore,
                    birthday: birthday,
                    fallbackCheckpointHeight: fallbackCheckpoint,
                    endpoint: endpoint,
                    network: network,
                    torDirPath: torDirPath
                )
            }
        )
        return GiftCardSlipstreamFixture(
            card: card,
            synchronizer: synchronizer,
            initializer: initializer,
            engine: engine,
            backend: backend,
            service: service,
            repository: repository,
            anchor: anchor,
            storageRoot: root,
            torDirectory: torDirectory,
            account: account,
            balance: balance
        )
    }
}

/// A monotonic test clock with observable timer registration and cancellable sleeps.
final class GiftCardCleanupTestClock: @unchecked Sendable {
    private struct Sleep {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct Observer {
        let deadline: UInt64
        let count: Int
        let expectation: XCTestExpectation
    }

    private final class Registration {
        let id = UUID()
        var cancelled = false
    }

    private let lock = NSLock()
    private var disposed = false
    private var instant: UInt64 = 0
    private var deliversElapsedSleeps = true
    private var sleeps: [UUID: Sleep] = [:]
    private var registrationCounts: [UInt64: Int] = [:]
    private var observers: [Observer] = []
    private var emptyObservers: [XCTestExpectation] = []

    var timing: GiftCardCleanupTiming {
        GiftCardCleanupTiming(now: { self.withLock { self.instant } }, sleepUntil: { try await self.sleep(until: $0) })
    }

    var pendingDeadlines: [UInt64] {
        withLock { sleeps.values.map(\.deadline).sorted() }
    }

    func expectSleep(at deadline: UInt64, count: Int = 1) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "clock registered sleep at \(deadline)")
        let ready = withLock {
            if registrationCounts[deadline, default: 0] >= count { return true }
            observers.append(Observer(deadline: deadline, count: count, expectation: expectation))
            return false
        }
        if ready { expectation.fulfill() }
        return expectation
    }

    func expectNoPendingSleeps() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "clock has no pending sleeps")
        let ready = withLock {
            if sleeps.isEmpty { return true }
            emptyObservers.append(expectation)
            return false
        }
        if ready { expectation.fulfill() }
        return expectation
    }

    func dispose() {
        let pending = withLock {
            disposed = true
            let pending = Array(sleeps.values)
            sleeps = [:]
            return pending
        }
        pending.forEach { $0.continuation.resume(throwing: CancellationError()) }
        notifyEmpty()
    }

    func advance(to instant: UInt64, deliveringSleeps: Bool = true) {
        let ready: [Sleep] = withLock {
            precondition(instant >= self.instant)
            self.instant = instant
            deliversElapsedSleeps = deliveringSleeps
            guard deliveringSleeps else { return [] }
            let ready = sleeps.filter { $0.value.deadline <= instant }
            for id in ready.keys { sleeps.removeValue(forKey: id) }
            return Array(ready.values)
        }
        ready.forEach { $0.continuation.resume() }
        notifyEmpty()
    }

    private func sleep(until deadline: UInt64) async throws {
        let registration = Registration()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var result: Result<Void, Error>?
                let ready: [XCTestExpectation] = withLock {
                    registrationCounts[deadline, default: 0] += 1
                    if disposed || registration.cancelled || Task.isCancelled {
                        result = .failure(CancellationError())
                    } else if deadline <= instant && deliversElapsedSleeps {
                        result = .success(())
                    } else {
                        sleeps[registration.id] = Sleep(deadline: deadline, continuation: continuation)
                    }
                    let ready = observers.filter { registrationCounts[$0.deadline, default: 0] >= $0.count }
                    observers.removeAll { registrationCounts[$0.deadline, default: 0] >= $0.count }
                    return ready.map(\.expectation)
                }
                ready.forEach { $0.fulfill() }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let sleep = self.withLock {
                registration.cancelled = true
                return self.sleeps.removeValue(forKey: registration.id)
            }
            sleep?.continuation.resume(throwing: CancellationError())
            self.notifyEmpty()
        }
    }

    private func notifyEmpty() {
        let ready: [XCTestExpectation] = withLock {
            guard sleeps.isEmpty else { return [] }
            let ready = emptyObservers
            emptyObservers = []
            return ready
        }
        ready.forEach { $0.fulfill() }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Releases every entrant, including duplicate attempts in a failing implementation.
actor GiftCardCleanupTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let ready = continuations
        continuations = []
        ready.forEach { $0.resume() }
    }
}

/// Real destination hosts, with only their Rust storage boundary replaced for offline claims.
struct GiftCardDestinationFixture {
    let synchronizer: Synchronizer
    let backend: ZcashRustBackendWeldingMock

    static func make(storageDirectory: URL, slipstream: Bool) throws -> GiftCardDestinationFixture {
        let root = storageDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let container = DIContainer()
        container.isTestEnvironment = true
        let backend = ZcashRustBackendWeldingMock()
        backend.decryptAndStoreTransactionTxBytesMinedHeightReturnValue = Data(repeating: 0xA1, count: 32)
        backend.setTransactionTrustTxIdTrustedClosure = { _, _ in }
        container.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in backend }
        container.mock(type: LightWalletService.self, isSingleton: true) { _ in LightWalletServiceMock() }
        container.mock(type: TransactionRepository.self, isSingleton: true) { _ in TransactionRepositoryMock() }
        let initializer = Initializer(
            container: container,
            cacheDbURL: nil,
            fsBlockDbRoot: root.appendingPathComponent("blocks"),
            generalStorageURL: root.appendingPathComponent("general"),
            dataDbURL: root.appendingPathComponent("data.db"),
            torDirURL: root.appendingPathComponent("tor"),
            endpoint: LightWalletEndpoint(address: "127.0.0.1", port: 1, secure: false),
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: root.appendingPathComponent("spend.params"),
            outputParamsURL: root.appendingPathComponent("output.params"),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            loggingPolicy: .noLogging,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
        let synchronizer: Synchronizer = slipstream
            ? SlipstreamSynchronizer(initializer: initializer)
            : SDKSynchronizer(initializer: initializer)
        return GiftCardDestinationFixture(synchronizer: synchronizer, backend: backend)
    }
}
