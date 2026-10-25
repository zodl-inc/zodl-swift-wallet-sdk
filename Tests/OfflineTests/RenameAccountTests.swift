//
//  RenameAccountTests.swift
//  OfflineTests
//
//  How `Synchronizer.renameAccount(_:name:)` stores a new name for an account: through the rust
//  layer against a real wallet database, as `SDKSynchronizer` and `SlipstreamSynchronizer` hand the
//  rename to the backend, and from the protocol-extension default.
//

import Foundation
import Testing
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

@Suite
struct RenameAccountTests {
    /// The name the real-backend tests import their account with.
    private static let importedName = "Imported"

    /// The name the tests rename an account to. Its emoji lies outside the Basic Multilingual Plane,
    /// so the name crosses the FFI as multi-byte UTF-8 in both directions.
    private static let newName = "Renamed account 🔐"

    /// The account the synchronizer tests rename through a backend double.
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))

    /// An account no test wallet holds.
    private static let unknownAccountUUID = AccountUUID(id: [UInt8](repeating: 0x07, count: 16))

    /// What the backend double throws in the failure tests.
    private static let backendFailure = ZcashError.rustSetAccountName("The account with the given ID does not belong to this wallet.")

    // MARK: - Through the rust layer

    /// Only the name changes: the account keeps its UUID, keys, key source and every other field.
    @Test
    func renamedAccountIsListedWithTheNewName() async throws {
        try await withTestnetWalletHoldingAnImportedAccount { backend, accountUUID in
            let imported = try #require(try await backend.listAccounts().first)
            #expect(imported.name == Self.importedName)

            try await backend.setAccountName(accountUUID, name: Self.newName)

            let renamed = Account(
                id: accountUUID,
                name: Self.newName,
                keySource: imported.keySource,
                seedFingerprint: imported.seedFingerprint,
                hdAccountIndex: imported.hdAccountIndex,
                ufvk: imported.ufvk,
                uivk: imported.uivk
            )
            let accounts = try await backend.listAccounts()
            #expect(accounts == [renamed])
        }
    }

    @Test
    func unknownAccountThrows() async throws {
        try await withTestnetWalletHoldingAnImportedAccount { backend, _ in
            let error = await #expect(throws: ZcashError.self) {
                try await backend.setAccountName(Self.unknownAccountUUID, name: Self.newName)
            }
            #expect(error?.code == .rustSetAccountName)

            let names = try await backend.listAccounts().map(\.name)
            #expect(names == [Self.importedName])
        }
    }

    /// A null character would end the name early at the FFI boundary, and the rust layer would store
    /// only the part before it. The name is refused instead, and the account keeps the name it had.
    @Test
    func nameWithANullCharacterIsRefused() async throws {
        try await withTestnetWalletHoldingAnImportedAccount { backend, accountUUID in
            let error = await #expect(throws: ZcashError.self) {
                try await backend.setAccountName(accountUUID, name: "Renamed\u{0}account")
            }
            #expect(error?.code == .rustSetAccountName)

            let names = try await backend.listAccounts().map(\.name)
            #expect(names == [Self.importedName])
        }
    }

    // MARK: - Synchronizers

    @Test
    func sdkSynchronizerPassesTheAccountAndNameToTheBackend() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.setAccountNameNameClosure = { _, _ in }

        try await withTemporaryDirectory { directory in
            let synchronizer = makeSDKSynchronizer(rustBackend: rustBackend, directory: directory)
            try await synchronizer.renameAccount(Self.accountUUID, name: Self.newName)
        }

        #expect(rustBackend.setAccountNameNameCallsCount == 1)
        #expect(rustBackend.setAccountNameNameReceivedArguments?.accountUUID == Self.accountUUID)
        #expect(rustBackend.setAccountNameNameReceivedArguments?.name == Self.newName)
    }

    @Test
    func sdkSynchronizerThrowsWhatTheBackendThrows() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.setAccountNameNameThrowableError = Self.backendFailure

        try await withTemporaryDirectory { directory in
            let synchronizer = makeSDKSynchronizer(rustBackend: rustBackend, directory: directory)
            await #expect(throws: Self.backendFailure) {
                try await synchronizer.renameAccount(Self.accountUUID, name: Self.newName)
            }
        }
    }

    /// The engine never reads an account's name, so unlike `deleteAccount(_:)` a rename neither stops
    /// nor restarts a running sync pass.
    @Test
    func slipstreamSynchronizerRenamesWithoutStoppingTheSyncPass() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.setAccountNameNameClosure = { _, _ in }
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))

        try await withTemporaryDirectory { directory in
            let synchronizer = makeSlipstreamSynchronizer(rustBackend: rustBackend, engine: engine, directory: directory)
            await synchronizer.setInternalSyncStatusForTesting(.disconnected)
            try await synchronizer.start(retry: false)

            // Recorded rather than thrown, so that the pass is stopped below whatever happens.
            await #expect(throws: Never.self) {
                try await synchronizer.renameAccount(Self.accountUUID, name: Self.newName)
            }
            let calls = await engine.calls
            let stillSyncing = synchronizer.latestState.internalSyncStatus.isSyncing
            await synchronizer.stopAndWait()

            #expect(!calls.contains(where: GatedFakeSlipstreamEngine.isStop), "the rename must not stop the pass: \(calls)")
            #expect(calls.filter { $0 == "start" }.count == 1, "nor start another one: \(calls)")
            #expect(stillSyncing)
        }

        #expect(rustBackend.setAccountNameNameCallsCount == 1)
        #expect(rustBackend.setAccountNameNameReceivedArguments?.accountUUID == Self.accountUUID)
        #expect(rustBackend.setAccountNameNameReceivedArguments?.name == Self.newName)
    }

    @Test
    func slipstreamSynchronizerThrowsWhatTheBackendThrows() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.setAccountNameNameThrowableError = Self.backendFailure

        try await withTemporaryDirectory { directory in
            let synchronizer = makeSlipstreamSynchronizer(
                rustBackend: rustBackend,
                engine: GatedFakeSlipstreamEngine(),
                directory: directory
            )
            await #expect(throws: Self.backendFailure) {
                try await synchronizer.renameAccount(Self.accountUUID, name: Self.newName)
            }
        }
    }

    @Test
    func defaultImplementationThrows() async throws {
        let synchronizer: Synchronizer = SynchronizerUsingDefaults()

        let error = await #expect(throws: (any Error).self) {
            try await synchronizer.renameAccount(Self.accountUUID, name: Self.newName)
        }
        let description = (error as? LocalizedError)?.errorDescription
        #expect(description?.contains("has no default implementation") == true)
        #expect(description?.contains("renameAccount") == true)
    }

    // MARK: - Helpers

    /// Runs `body` with a backend over a new testnet wallet database that holds one account, imported
    /// view-only from the key of account 0 of the seed the offline tests use, and with that account's
    /// UUID. Each call gets a database of its own, because the tests of this suite run in parallel.
    private func withTestnetWalletHoldingAnImportedAccount(_ body: (ZcashRustBackend, AccountUUID) async throws -> Void) async throws {
        let tool = DerivationTool(networkType: .testnet)
        let usk = try tool.deriveUnifiedSpendingKey(seed: Environment.seedBytes, accountIndex: Zip32AccountIndex(0))
        let ufvk = try tool.deriveUnifiedFullViewingKey(from: usk)

        try await withTemporaryDirectory { directory in
            let backend = ZcashRustBackend.makeForTests(
                dbData: directory.appendingPathComponent("data.db", isDirectory: false),
                fsBlockDbRoot: directory,
                networkType: .testnet
            )
            try #require(try await backend.initDataDb(seed: nil) == .success)

            let accountUUID = try await backend.importAccount(
                ufvk: ufvk.stringEncoded,
                seedFingerprint: nil,
                zip32AccountIndex: nil,
                treeState: CheckpointSourceFactory.fromBundle(for: .testnet).latestKnownCheckpoint().treeState(),
                recoverUntil: nil,
                purpose: .viewOnly,
                name: Self.importedName,
                keySource: Account.viewOnlyKeySource
            )

            try await body(backend, accountUUID)
        }
    }

    /// An `Initializer` over `container`, keeping its files in `directory`.
    private func makeInitializer(container: DIContainer, directory: URL) -> Initializer {
        Initializer(
            container: container,
            cacheDbURL: nil,
            fsBlockDbRoot: directory,
            generalStorageURL: directory,
            dataDbURL: directory.appendingPathComponent("data.db", isDirectory: false),
            torDirURL: directory.appendingPathComponent("tor", isDirectory: true),
            endpoint: LightWalletEndpointBuilder.default,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: directory.appendingPathComponent("sapling-spend.params", isDirectory: false),
            outputParamsURL: directory.appendingPathComponent("sapling-output.params", isDirectory: false),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
    }

    /// An `SDKSynchronizer` that was never prepared, over `rustBackend`, keeping its files in `directory`.
    private func makeSDKSynchronizer(rustBackend: ZcashRustBackendWeldingMock, directory: URL) -> SDKSynchronizer {
        let container = DIContainer()
        container.isTestEnvironment = true
        container.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackend }

        return SDKSynchronizer(initializer: makeInitializer(container: container, directory: directory))
    }

    /// A `SlipstreamSynchronizer` that was never prepared, driving `engine` over `rustBackend` and keeping
    /// its files in `directory`. It is wired as `makeSlipstreamSynchronizer(engine:)` of the XCTest suites
    /// wires one, with the same two stubs: the generated mock crashes on a member that returns a value
    /// nobody stubbed, and `start(retry:)` lists the accounts.
    private func makeSlipstreamSynchronizer(
        rustBackend: ZcashRustBackendWeldingMock,
        engine: GatedFakeSlipstreamEngine,
        directory: URL
    ) -> SlipstreamSynchronizer {
        rustBackend.listAccountsReturnValue = []
        rustBackend.migrationBlockRateSamplesWindowReturnValue = []
        let repository = TransactionRepositoryMock()
        repository.closeDBConnectionClosure = {}

        let container = DIContainer()
        container.isTestEnvironment = true
        container.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackend }
        container.mock(type: LightWalletService.self, isSingleton: true) { _ in LightWalletServiceMock() }
        container.mock(type: TransactionRepository.self, isSingleton: true) { _ in repository }

        return SlipstreamSynchronizer(
            initializer: makeInitializer(container: container, directory: directory),
            alternateEndpoints: [],
            engine: engine
        )
    }
}
