//
//  ImportedAccountViewingKeyTests.swift
//  OfflineTests
//
//  What the rust layer reports for the accounts of a real wallet database. An account imported
//  without derivation data, such as a view-only or a Ledger account, keeps the viewing keys it was
//  imported with but has no seed fingerprint or ZIP 32 account index; an account derived from a seed
//  has all of them.
//

import Foundation
import Testing
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

@Suite
struct ImportedAccountViewingKeyTests {
    private let tool = DerivationTool(networkType: .testnet)

    // MARK: - Imported without derivation data

    @Test
    func importedViewOnlyAccountKeepsItsViewingKeys() async throws {
        let ufvk = try seedDerivedKey()

        try await withEmptyTestnetWallet { backend in
            let uuid = try await importWithoutDerivationData(ufvk, into: backend, purpose: .viewOnly, keySource: Account.viewOnlyKeySource)

            let account = try await backend.getAccount(for: uuid)
            try expectViewingKeysWithoutDerivationData(account, ufvk: ufvk)
            #expect(account.keySource == Account.viewOnlyKeySource)
            #expect(try await backend.listAccounts() == [account])
        }
    }

    /// A Ledger account is imported as a spending account, because the device signs for it, and without
    /// the seed fingerprint, which the device never reveals.
    @Test
    func importedLedgerAccountKeepsItsViewingKeys() async throws {
        let ufvk = try seedDerivedKey()

        try await withEmptyTestnetWallet { backend in
            let uuid = try await importWithoutDerivationData(ufvk, into: backend, purpose: .spending, keySource: Account.ledgerKeySource)

            let account = try await backend.getAccount(for: uuid)
            try expectViewingKeysWithoutDerivationData(account, ufvk: ufvk)
            #expect(account.keySource == Account.ledgerKeySource)
        }
    }

    // MARK: - Derived from a seed

    /// The other branch of the conversion: an account with derivation data keeps all of it next to its keys.
    @Test
    func seedDerivedAccountKeepsItsDerivationDataAndViewingKeys() async throws {
        try await withEmptyTestnetWallet { backend in
            let usk = try await backend.createAccount(
                seed: Environment.seedBytes,
                treeState: Self.checkpointTreeState,
                recoverUntil: nil,
                name: "Derived",
                keySource: nil
            )
            let ufvk = try tool.deriveUnifiedFullViewingKey(from: usk)

            let account = try #require(try await backend.listAccounts().first)
            #expect(account.ufvk == ufvk)
            let uivk = try #require(account.uivk)
            #expect(tool.isValidUnifiedIncomingViewingKey(uivk.stringEncoded))
            #expect(account.hdAccountIndex == Zip32AccountIndex(0))
            #expect(account.seedFingerprint?.count == 32)
        }
    }

    // MARK: - Key source

    /// A wallet stores the tag with its view-only accounts and compares it later, so the literal must not change.
    @Test
    func viewOnlyKeySourceIsAStableLiteral() {
        #expect(Account.viewOnlyKeySource == "view_only")
    }

    // MARK: - Helpers

    /// The tree state the accounts of these tests are created at.
    private static var checkpointTreeState: TreeState {
        CheckpointSourceFactory.fromBundle(for: .testnet).latestKnownCheckpoint().treeState()
    }

    /// The key of account 0 of the seed the offline tests use.
    private func seedDerivedKey() throws -> UnifiedFullViewingKey {
        let usk = try tool.deriveUnifiedSpendingKey(seed: Environment.seedBytes, accountIndex: Zip32AccountIndex(0))
        return try tool.deriveUnifiedFullViewingKey(from: usk)
    }

    /// Imports `ufvk` the way a wallet imports an account without derivation data: with no seed
    /// fingerprint and no ZIP 32 account index.
    private func importWithoutDerivationData(
        _ ufvk: UnifiedFullViewingKey,
        into backend: ZcashRustBackend,
        purpose: AccountPurpose,
        keySource: String?
    ) async throws -> AccountUUID {
        try await backend.importAccount(
            ufvk: ufvk.stringEncoded,
            seedFingerprint: nil,
            zip32AccountIndex: nil,
            treeState: Self.checkpointTreeState,
            recoverUntil: nil,
            purpose: purpose,
            name: "Imported",
            keySource: keySource
        )
    }

    /// Expects `account` to carry `ufvk` and an incoming viewing key, and no seed fingerprint or ZIP 32 account index. The
    /// full viewing keys are compared as typed values, so that a failure cannot print one.
    private func expectViewingKeysWithoutDerivationData(_ account: Account, ufvk: UnifiedFullViewingKey) throws {
        #expect(account.ufvk == ufvk)
        let uivk = try #require(account.uivk)
        #expect(tool.isValidUnifiedIncomingViewingKey(uivk.stringEncoded))
        #expect(account.hdAccountIndex == nil)
        #expect(account.seedFingerprint == nil)
    }

    /// Runs `body` with a backend over a new testnet wallet database that holds no account, and removes
    /// the database afterwards. Each call gets a database of its own, because the tests of this suite run
    /// in parallel.
    private func withEmptyTestnetWallet(_ body: (ZcashRustBackend) async throws -> Void) async throws {
        let directory = Environment.uniqueTestTempDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let backend = ZcashRustBackend.makeForTests(
            dbData: directory.appendingPathComponent("data.db", isDirectory: false),
            fsBlockDbRoot: directory,
            networkType: .testnet
        )
        try #require(try await backend.initDataDb(seed: nil) == .success)

        try await body(backend)
    }
}
