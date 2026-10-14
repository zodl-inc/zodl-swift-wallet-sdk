//
//  WalletTests.swift
//  ZODLSwiftWalletSDK
//
//  Created by Francisco Gindre on 13/09/2019.
//  Copyright © 2019 Electric Coin Company. All rights reserved.
//

import Foundation
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

class WalletTests: ZcashTestCase {
    let testFileManager = FileManager()
    var dbData: URL! = nil
    var paramDestination: URL! = nil
    var network = ZcashNetworkBuilder.network(for: .testnet)
    var seedData = Data(base64Encoded: "9VDVOZZZOWWHpZtq1Ebridp3Qeux5C+HwiRR0g7Oi7HgnMs8Gfln83+/Q1NnvClcaSwM4ADFL1uZHxypEWlWXg==")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbData = try __dataDbURL()
        paramDestination = try __documentsDirectory().appendingPathComponent("parameters")
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        if testFileManager.fileExists(atPath: dbData.absoluteString) {
            try testFileManager.trashItem(at: dbData, resultingItemURL: nil)
        }
    }

    func testWalletInitialization() async throws {
        let mockContainer = DIContainer()
        mockContainer.isTestEnvironment = true

        let serviceMock = LightWalletServiceMock()
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in serviceMock }
        let latestBlockHeight = network.constants.saplingActivationHeight + ZcashSDK.maxReorgSize + 1
        serviceMock.latestBlockHeightModeReturnValue = latestBlockHeight
        serviceMock.getTreeStateModeClosure = { _, _ in
            throw ZcashError.rustTorLwdGetTreeState("test")
        }

        let wallet = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: network,
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        let synchronizer = SDKSynchronizer(initializer: wallet)
        do {
            guard case .success = try await synchronizer.prepare(
                with: seedData.bytes,
                walletBirthday: nil,
                name: "",
                keySource: nil
            ) else {
                XCTFail("Failed to initDataDb. Expected `.success` got: `.seedRequired`")
                return
            }
        } catch {
            XCTFail("shouldn't fail here. Got error: \(error)")
        }

        XCTAssertEqual(
            serviceMock.getTreeStateModeReceivedArguments?.id.height,
            UInt64(latestBlockHeight - ZcashSDK.maxReorgSize)
        )

        // fileExists actually sucks, so attempting to delete the file and checking what happens is far better :)
        XCTAssertNoThrow( try FileManager.default.removeItem(at: dbData!) )
    }

    /// MOB-1512: when the rust layer reports that the provided seed isn't relevant to the accounts already present in the
    /// wallet database (for example, a restored `data.db` that belongs to a different wallet than the seed available to the
    /// caller), `Initializer.initialize` must surface `.seedNotRelevant` to the caller instead of silently proceeding as if
    /// initialization succeeded.
    func testInitializePropagatesSeedNotRelevantFromRustBackend() async throws {
        let rustBackendMock = ZcashRustBackendWeldingMock()
        rustBackendMock.initBlockMetadataDbClosure = { }
        rustBackendMock.initDataDbSeedClosure = { _ in DbInitResult.seedNotRelevant }

        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackendMock }

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: network,
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        let result = try await initializer.initialize(
            with: seedData.bytes,
            walletBirthday: 663194,
            name: ""
        )

        guard case .seedNotRelevant = result else {
            XCTFail("Expected `.seedNotRelevant` when rustBackend.initDataDb() reports it, got \(result) instead.")
            return
        }
    }

    /// Companion regression test for `testInitializePropagatesSeedNotRelevantFromRustBackend`: the pre-existing
    /// `.seedRequired` propagation must keep working once `initialize` switches exhaustively over `DbInitResult`.
    func testInitializePropagatesSeedRequiredFromRustBackend() async throws {
        let rustBackendMock = ZcashRustBackendWeldingMock()
        rustBackendMock.initBlockMetadataDbClosure = { }
        rustBackendMock.initDataDbSeedClosure = { _ in DbInitResult.seedRequired }

        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackendMock }

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: network,
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        let result = try await initializer.initialize(
            with: nil,
            walletBirthday: 663194,
            name: ""
        )

        guard case .seedRequired = result else {
            XCTFail("Expected `.seedRequired` when rustBackend.initDataDb() reports it, got \(result) instead.")
            return
        }
    }

    /// Pins the `initialize` seed/account integrity guard: `initialize` is idempotent for an existing wallet, so if the
    /// rust layer reports that the caller's seed doesn't derive any account already stored in `data.db` (for example,
    /// `data.db` was restored from a device backup belonging to a different wallet than the seed currently held in the
    /// keychain), `initialize` must throw `ZcashError.initializerSeedMismatch` instead of silently returning `.success`.
    /// Without this guard the wallet opens against the wrong account: the UI would show that account's balance and
    /// receive address (funds receivable but unspendable with the caller's seed) while sends fail downstream. Account
    /// creation must also be skipped entirely in this case, since accounts already exist for this database.
    func testInitializeThrowsSeedMismatchWhenSeedIsNotRelevantToDerivedAccounts() async throws {
        let existingAccount = Account(
            id: TestsData.mockedAccountUUID,
            name: nil,
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
            uivk: nil
        )

        let rustBackendMock = ZcashRustBackendWeldingMock()
        rustBackendMock.initBlockMetadataDbClosure = { }
        rustBackendMock.initDataDbSeedClosure = { _ in DbInitResult.success }
        rustBackendMock.listAccountsClosure = { [existingAccount] }
        rustBackendMock.isSeedRelevantToAnyDerivedAccountSeedReturnValue = false

        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackendMock }

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: network,
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        do {
            _ = try await initializer.initialize(
                with: seedData.bytes,
                walletBirthday: 663194,
                name: ""
            )
            XCTFail("Expected `initialize` to throw `ZcashError.initializerSeedMismatch` when the seed isn't relevant to any existing account.")
        } catch {
            guard let zcashError = error as? ZcashError, case .initializerSeedMismatch = zcashError else {
                XCTFail("Expected `ZcashError.initializerSeedMismatch`, got \(error) instead.")
                return
            }
        }

        XCTAssertEqual(rustBackendMock.createAccountSeedTreeStateRecoverUntilNameKeySourceCallsCount, 0)
    }

    /// Companion regression test for `testInitializeThrowsSeedMismatchWhenSeedIsNotRelevantToDerivedAccounts`: the seed/
    /// account guard must not false-positive on the ordinary "reopen the same wallet" path. When the rust layer reports
    /// the seed IS relevant to an already-stored account, `initialize` must still return `.success` — otherwise every
    /// normal app relaunch against an existing wallet would be bricked by the new check.
    func testInitializeSucceedsWhenSeedIsRelevantToExistingAccounts() async throws {
        let existingAccount = Account(
            id: TestsData.mockedAccountUUID,
            name: nil,
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
            uivk: nil
        )

        let rustBackendMock = ZcashRustBackendWeldingMock()
        rustBackendMock.initBlockMetadataDbClosure = { }
        rustBackendMock.initDataDbSeedClosure = { _ in DbInitResult.success }
        rustBackendMock.listAccountsClosure = { [existingAccount] }
        rustBackendMock.isSeedRelevantToAnyDerivedAccountSeedReturnValue = true

        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackendMock }

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: network,
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        let result = try await initializer.initialize(
            with: seedData.bytes,
            walletBirthday: 663194,
            name: ""
        )

        guard case .success = result else {
            XCTFail("Expected `.success` when the seed is relevant to an existing account, got \(result) instead.")
            return
        }

        XCTAssertEqual(rustBackendMock.createAccountSeedTreeStateRecoverUntilNameKeySourceCallsCount, 0)
    }

    /// Companion regression test: the seed/account guard must be skipped entirely for a brand-new wallet. When
    /// `listAccounts` returns no accounts there is nothing yet to validate the seed against, so `initialize` must go
    /// straight to account creation instead of consulting `isSeedRelevantToAnyDerivedAccount` — a relevance check with
    /// nothing to compare against must never gate first-time wallet creation or restore.
    func testInitializeSkipsSeedRelevanceCheckForEmptyWallet() async throws {
        let rustBackendMock = ZcashRustBackendWeldingMock()
        rustBackendMock.initBlockMetadataDbClosure = { }
        rustBackendMock.initDataDbSeedClosure = { _ in DbInitResult.success }
        rustBackendMock.listAccountsClosure = { [] }
        rustBackendMock.createAccountSeedTreeStateRecoverUntilNameKeySourceReturnValue = UnifiedSpendingKey(
            network: network.networkType,
            bytes: []
        )

        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackendMock }

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: network,
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        let result = try await initializer.initialize(
            with: seedData.bytes,
            walletBirthday: 663194,
            name: ""
        )

        guard case .success = result else {
            XCTFail("Expected `.success` for a fresh wallet with no existing accounts, got \(result) instead.")
            return
        }

        XCTAssertFalse(rustBackendMock.isSeedRelevantToAnyDerivedAccountSeedCalled)
    }

    /// Companion regression test: the seed/account guard requires a seed to validate against, so it must be skipped
    /// when no seed is supplied at all. View-only wallets and callers that can't fetch the seed from secure storage
    /// (e.g. background tasks) pass `nil` here; they must keep working unaffected by the new check instead of being
    /// gated on a relevance test that has no seed to test.
    func testInitializeSkipsSeedRelevanceCheckWithoutSeed() async throws {
        let existingAccount = Account(
            id: TestsData.mockedAccountUUID,
            name: nil,
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
            uivk: nil
        )

        let rustBackendMock = ZcashRustBackendWeldingMock()
        rustBackendMock.initBlockMetadataDbClosure = { }
        rustBackendMock.initDataDbSeedClosure = { _ in DbInitResult.success }
        rustBackendMock.listAccountsClosure = { [existingAccount] }

        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackendMock }

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: network,
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        let result = try await initializer.initialize(
            with: nil,
            walletBirthday: 663194,
            name: ""
        )

        guard case .success = result else {
            XCTFail("Expected `.success` when no seed is provided, got \(result) instead.")
            return
        }

        XCTAssertFalse(rustBackendMock.isSeedRelevantToAnyDerivedAccountSeedCalled)
    }
}
