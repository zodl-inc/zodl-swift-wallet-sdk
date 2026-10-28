//
//  AccountKeyOverlapTests.swift
//  OfflineTests
//
//  What `Synchronizer.findAccountSharingKeyComponents(_:)` reports about the account that shares a
//  viewing key component with a key: through the rust layer against a real wallet database, as the
//  mapping of each answer the rust layer can give, as `SDKSynchronizer` passes the backend's answer
//  on, and from the protocol-extension default.
//

import Foundation
import libzcashlc
import Testing
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

@Suite
struct AccountKeyOverlapTests {
    /// The account the mapping tests have the rust layer report, and the backend double returns: one
    /// with no name, key source, derivation metadata or keys.
    private static let account = Account(
        id: AccountUUID(id: [UInt8](repeating: 0x07, count: 16)),
        name: nil,
        keySource: nil,
        seedFingerprint: nil,
        hdAccountIndex: nil,
        ufvk: nil,
        uivk: nil
    )

    /// The key of account 0 of the seed the offline tests use.
    private func seedDerivedKey(for networkType: NetworkType = .testnet) throws -> UnifiedFullViewingKey {
        let tool = DerivationTool(networkType: networkType)
        let usk = try tool.deriveUnifiedSpendingKey(seed: Environment.seedBytes, accountIndex: Zip32AccountIndex(0))
        return try tool.deriveUnifiedFullViewingKey(from: usk)
    }

    // MARK: - Through the rust layer

    @Test
    func noOverlapForAnEmptyWallet() async throws {
        let ufvk = try seedDerivedKey()

        try await withEmptyTestnetWallet { backend in
            let overlap = try await backend.findAccountKeyOverlap(ufvk: ufvk)
            #expect(overlap == nil)
        }
    }

    @Test
    func sameKeyIsAlreadyImported() async throws {
        let ufvk = try seedDerivedKey()

        try await withEmptyTestnetWallet { backend in
            let importedUUID = try await backend.importAccount(
                ufvk: ufvk.stringEncoded,
                seedFingerprint: nil,
                zip32AccountIndex: nil,
                treeState: CheckpointSourceFactory.fromBundle(for: .testnet).latestKnownCheckpoint().treeState(),
                recoverUntil: nil,
                purpose: .viewOnly,
                name: "Imported",
                keySource: nil
            )

            let overlap = try #require(try await backend.findAccountKeyOverlap(ufvk: ufvk))
            #expect(overlap.kind == .alreadyImported)
            #expect(overlap.account.id == importedUUID)
            #expect(overlap.importWouldFail)
        }
    }

    /// The rust layer refuses a key for another network and returns null. The error it sets is a
    /// fixed sentence, so it carries no part of the key.
    @Test
    func keyOfTheOtherNetworkThrowsAnErrorWithoutTheKey() async throws {
        let mainnetKey = try seedDerivedKey(for: .mainnet)

        try await withEmptyTestnetWallet { backend in
            await #expect(throws: ZcashError.rustFindAccountKeyOverlap("the unified full viewing key is for another network")) {
                try await backend.findAccountKeyOverlap(ufvk: mainnetKey)
            }
        }
    }

    // MARK: - Mapping of the rust layer's answer

    /// The three kinds that name an account each map to their own case, with that account.
    @Test
    func eachKindThatNamesAnAccountMapsToItsCase() throws {
        let alreadyImported = try #require(try reported(FfiAccountKeyOverlapKind_AlreadyImported).unsafeToAccountKeyOverlap())
        #expect(alreadyImported == AccountKeyOverlap(account: Self.account, kind: .alreadyImported))
        #expect(alreadyImported.importWouldFail)

        let wouldUpgrade = try #require(try reported(FfiAccountKeyOverlapKind_WouldUpgrade).unsafeToAccountKeyOverlap())
        #expect(wouldUpgrade == AccountKeyOverlap(account: Self.account, kind: .wouldUpgrade))
        #expect(!wouldUpgrade.importWouldFail)

        let conflicting = try #require(try reported(FfiAccountKeyOverlapKind_Conflicting).unsafeToAccountKeyOverlap())
        #expect(conflicting == AccountKeyOverlap(account: Self.account, kind: .conflicting))
        #expect(conflicting.importWouldFail)
    }

    @Test
    func noneMapsToNil() throws {
        #expect(try reported(FfiAccountKeyOverlapKind_None, reportsAccount: false).unsafeToAccountKeyOverlap() == nil)
    }

    @Test
    func multipleAccountsThrows() {
        #expect(throws: ZcashError.accountKeyOverlapMultipleAccounts) {
            try reported(FfiAccountKeyOverlapKind_MultipleAccounts, reportsAccount: false).unsafeToAccountKeyOverlap()
        }
    }

    /// A kind this version of the SDK does not know, or no account for a kind that needs one, is a
    /// failure of the lookup, not an answer.
    @Test
    func unknownKindOrMissingAccountThrows() {
        let unknownKind = #expect(throws: ZcashError.self) {
            try reported(FfiAccountKeyOverlapKind(rawValue: 5)).unsafeToAccountKeyOverlap()
        }
        #expect(unknownKind?.code == .rustFindAccountKeyOverlap)

        let missingAccount = #expect(throws: ZcashError.self) {
            try reported(FfiAccountKeyOverlapKind_Conflicting, reportsAccount: false).unsafeToAccountKeyOverlap()
        }
        #expect(missingAccount?.code == .rustFindAccountKeyOverlap)
    }

    /// The rust layer sets no error when it returns a value, so an error that an earlier failure on the
    /// same thread left unread must not become the message of these failures.
    @Test
    func unknownKindOrMissingAccountIgnoresAStaleError() {
        defer { zcashlc_clear_last_error() }

        // An unknown network id makes the call fail and leave its message as this thread's last error.
        #expect(zcashlc_describe_unified_full_viewing_key([CChar]("".utf8CString), 99) == -2)

        let unknownKind = #expect(throws: ZcashError.self) {
            try reported(FfiAccountKeyOverlapKind(rawValue: 5)).unsafeToAccountKeyOverlap()
        }
        #expect(overlapMessage(unknownKind) == "`findAccountKeyOverlap` reported an unknown kind")

        let missingAccount = #expect(throws: ZcashError.self) {
            try reported(FfiAccountKeyOverlapKind_Conflicting, reportsAccount: false).unsafeToAccountKeyOverlap()
        }
        #expect(overlapMessage(missingAccount) == "`findAccountKeyOverlap` reported no account")
    }

    // MARK: - Synchronizers

    @Test
    func sdkSynchronizerReturnsWhatTheBackendReturns() async throws {
        let ufvk = try seedDerivedKey()
        let overlap = AccountKeyOverlap(account: Self.account, kind: .wouldUpgrade)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.findAccountKeyOverlapUfvkReturnValue = overlap

        try await withTemporaryDirectory { directory in
            let synchronizer = makeStoppedSynchronizer(rustBackend: rustBackend, directory: directory)

            let returned = try await synchronizer.findAccountSharingKeyComponents(ufvk)
            #expect(returned == overlap)
        }

        #expect(rustBackend.findAccountKeyOverlapUfvkCallsCount == 1)
        #expect(rustBackend.findAccountKeyOverlapUfvkReceivedUfvk == ufvk)
    }

    @Test
    func defaultImplementationThrows() async throws {
        let ufvk = try seedDerivedKey()
        let synchronizer: Synchronizer = SynchronizerUsingDefaults()

        let error = await #expect(throws: (any Error).self) {
            try await synchronizer.findAccountSharingKeyComponents(ufvk)
        }
        let description = (error as? LocalizedError)?.errorDescription
        #expect(description?.contains("has no default implementation") == true)
        #expect(description?.contains("findAccountSharingKeyComponents") == true)
    }

    // MARK: - Helpers

    /// What `zcashlc_find_account_key_overlap` returns for `kind` when it reports `Self.account`, or,
    /// when `reportsAccount` is `false`, the all-zero account it reports for no account.
    /// `ZcashError`'s `==` compares only the code, so the message has to be read from the case itself.
    private func overlapMessage(_ error: ZcashError?) -> String? {
        guard case let .rustFindAccountKeyOverlap(message)? = error else {
            return nil
        }
        return message
    }

    private func reported(_ kind: FfiAccountKeyOverlapKind, reportsAccount: Bool = true) -> FfiAccountKeyOverlap {
        var account = FfiAccount()
        if reportsAccount {
            withUnsafeMutableBytes(of: &account.uuid_bytes) { $0.copyBytes(from: Self.account.id.id) }
        }
        // The rust layer reports an account without derivation metadata with this index.
        account.hd_account_index = UInt32.max

        var overlap = FfiAccountKeyOverlap()
        overlap.kind = kind
        overlap.account = account
        return overlap
    }

    /// Runs `body` with a backend over a new testnet wallet database that holds no account. Each call
    /// gets a database of its own, because the tests of this suite run in parallel.
    private func withEmptyTestnetWallet(_ body: (ZcashRustBackend) async throws -> Void) async throws {
        try await withTemporaryDirectory { directory in
            let backend = ZcashRustBackend.makeForTests(
                dbData: directory.appendingPathComponent("data.db", isDirectory: false),
                fsBlockDbRoot: directory,
                networkType: .testnet
            )
            try #require(try await backend.initDataDb(seed: nil) == .success)

            try await body(backend)
        }
    }

    /// An `SDKSynchronizer` that was never prepared, over `rustBackend`, keeping its files in `directory`.
    private func makeStoppedSynchronizer(rustBackend: ZcashRustBackendWeldingMock, directory: URL) -> SDKSynchronizer {
        let container = DIContainer()
        container.isTestEnvironment = true
        container.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackend }

        let initializer = Initializer(
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

        return SDKSynchronizer(initializer: initializer)
    }
}
