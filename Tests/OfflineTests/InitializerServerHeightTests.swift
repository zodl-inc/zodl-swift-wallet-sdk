//
//  InitializerServerHeightTests.swift
//  OfflineTests
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// `Initializer.initialize` provisions a new account with what the server says about the chain: the tip it
/// recovers until when restoring, and a recent tree state when creating a wallet. Heights the SDK can't use
/// can only come from a broken or hostile server, and are treated as if the server had not answered.
final class InitializerServerHeightTests: ZcashTestCase {
    private let network = ZcashNetworkBuilder.network(for: .testnet)
    private let seed = [UInt8](repeating: 0x07, count: 32)
    private let restoreBirthday = 3_000_000

    private struct Fixture {
        let initializer: Initializer
        let backend: ZcashRustBackendWeldingMock
        let service: LightWalletServiceMock

        var created: (treeState: TreeState, recoverUntil: UInt32?)? {
            backend.createAccountSeedTreeStateRecoverUntilNameKeySourceReceivedArguments.map { ($0.treeState, $0.recoverUntil) }
        }
    }

    private func makeFixture() throws -> Fixture {
        let backend = ZcashRustBackendWeldingMock()
        backend.initBlockMetadataDbClosure = { }
        backend.initDataDbSeedClosure = { _ in DbInitResult.success }
        backend.listAccountsClosure = { [] }
        backend.createAccountSeedTreeStateRecoverUntilNameKeySourceReturnValue = UnifiedSpendingKey(network: network.networkType, bytes: [])
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in backend }

        let service = LightWalletServiceMock()
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in service }

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

        return Fixture(initializer: initializer, backend: backend, service: service)
    }

    private func treeState(height: UInt64) -> TreeState {
        var treeState = TreeState()
        treeState.height = height
        treeState.hash = "00"
        treeState.time = 1
        treeState.saplingTree = "00"
        return treeState
    }

    /// The latest bundled checkpoint: the base of the fallback a restore recovers until when the server can't give a tip,
    /// and what a new wallet starts from when the server gives no usable tree state.
    private var bundledCheckpoint: Checkpoint {
        CheckpointSourceFactory.fromBundle(for: .testnet).birthday(for: BlockHeight.max)
    }

    // MARK: - Restore: the tip to recover until

    func testRestoreRecoversUntilTheTipTheServerReports() async throws {
        let fixture = try makeFixture()
        fixture.service.latestBlockHeightModeReturnValue = 3_100_000

        _ = try await fixture.initializer.initialize(with: seed, walletBirthday: restoreBirthday, name: "")

        XCTAssertEqual(fixture.created?.recoverUntil, 3_100_000)
    }

    func testRestoreTreatsATipThatDoesNotFitUInt32LikeAnUnreachableServer() async throws {
        let fixture = try makeFixture()
        fixture.service.latestBlockHeightModeReturnValue = BlockHeight(UInt32.max) + 1

        _ = try await fixture.initializer.initialize(with: seed, walletBirthday: restoreBirthday, name: "")

        let fallback = max(bundledCheckpoint.height, fixture.initializer.walletBirthday + 1)
        XCTAssertEqual(fixture.created?.recoverUntil, UInt32(fallback))
    }

    func testRestoreWithAnUnreachableServerRecoversUntilTheSameFallback() async throws {
        let fixture = try makeFixture()
        fixture.service.latestBlockHeightModeThrowableError = LightWalletServiceError.timeOut

        _ = try await fixture.initializer.initialize(with: seed, walletBirthday: restoreBirthday, name: "")

        let fallback = max(bundledCheckpoint.height, fixture.initializer.walletBirthday + 1)
        XCTAssertEqual(fixture.created?.recoverUntil, UInt32(fallback))
    }

    // MARK: - New wallet: the tree state to start from

    func testNewWalletStartsFromTheTreeStateTheServerReports() async throws {
        let fixture = try makeFixture()
        fixture.service.latestBlockHeightModeReturnValue = 3_100_000
        fixture.service.getTreeStateModeReturnValue = treeState(height: 3_099_900)

        _ = try await fixture.initializer.initialize(with: seed, walletBirthday: nil, name: "")

        XCTAssertEqual(fixture.created?.treeState.height, 3_099_900)
        XCTAssertEqual(fixture.initializer.walletBirthday, 3_099_900)
    }

    func testNewWalletKeepsTheBundledCheckpointWhenTheTreeStateHeightIsUnusable() async throws {
        for unusable in [UInt64(Int32.max) + 1, UInt64(Int64.max) + 1, UInt64.max] {
            mockContainer = DIContainer()
            mockContainer.isTestEnvironment = true
            let fixture = try makeFixture()
            fixture.service.latestBlockHeightModeReturnValue = 3_100_000
            fixture.service.getTreeStateModeReturnValue = treeState(height: unusable)

            _ = try await fixture.initializer.initialize(with: seed, walletBirthday: nil, name: "")

            XCTAssertEqual(fixture.created?.treeState.height, UInt64(bundledCheckpoint.height), "\(unusable)")
            XCTAssertEqual(fixture.initializer.walletBirthday, bundledCheckpoint.height, "\(unusable)")
        }
    }

    // MARK: - Restore through the Slipstream anchor

    func testSlipstreamRestoreRecoversUntilTheAnchorsHeight() async throws {
        let fixture = try makeFixture()
        fixture.initializer.slipstreamAnchorSource = { _, _, _ in SlipstreamRestoreAnchor(height: 3_100_000, treeState: nil) }

        _ = try await fixture.initializer.initialize(with: seed, walletBirthday: restoreBirthday, name: "")

        XCTAssertEqual(fixture.created?.recoverUntil, 3_100_000)
    }

    /// The anchor at a height the SDK can't use is nil. The engine resolves a server tip above Int32.max like an
    /// unreachable server, so it reports such a height only for a birthday or checkpoint height above Int32.max. Unlike
    /// the classic restore, which falls back to the bundled checkpoint, a restore without an anchor is created without a
    /// recovery height, so it looks like a new wallet while it catches up.
    func testSlipstreamRestoreWithoutAnAnchorIsCreatedWithoutARecoveryHeight() async throws {
        for tip in [UInt64(Int32.max) + 1, UInt64(UInt32.max), UInt64(Int64.max) + 1, UInt64.max] {
            mockContainer = DIContainer()
            mockContainer.isTestEnvironment = true
            let fixture = try makeFixture()
            fixture.initializer.slipstreamAnchorSource = { _, _, _ in SlipstreamRestoreAnchor(serverHeight: tip, treeState: nil) }

            _ = try await fixture.initializer.initialize(with: seed, walletBirthday: restoreBirthday, name: "")

            XCTAssertEqual(fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceCallsCount, 1, "\(tip)")
            XCTAssertNil(fixture.created?.recoverUntil, "\(tip)")
        }
    }

    // MARK: - New wallet through the Slipstream anchor

    func testSlipstreamNewWalletStartsFromTheAnchorsTreeState() async throws {
        let fixture = try makeFixture()
        let state = treeState(height: 3_099_900)
        fixture.initializer.slipstreamAnchorSource = { _, _, _ in SlipstreamRestoreAnchor(height: 3_099_900, treeState: state) }

        _ = try await fixture.initializer.initialize(with: seed, walletBirthday: nil, name: "")

        XCTAssertEqual(fixture.created?.treeState.height, 3_099_900)
        XCTAssertEqual(fixture.initializer.walletBirthday, 3_099_900)
    }

    func testSlipstreamNewWalletKeepsTheBundledCheckpointWhenTheAnchorsTreeStateHeightIsUnusable() async throws {
        for unusable in [UInt64(Int32.max) + 1, UInt64(Int64.max) + 1, UInt64.max] {
            mockContainer = DIContainer()
            mockContainer.isTestEnvironment = true
            let fixture = try makeFixture()
            let state = treeState(height: unusable)
            fixture.initializer.slipstreamAnchorSource = { _, _, _ in SlipstreamRestoreAnchor(height: 3_099_900, treeState: state) }

            _ = try await fixture.initializer.initialize(with: seed, walletBirthday: nil, name: "")

            XCTAssertEqual(fixture.created?.treeState.height, UInt64(bundledCheckpoint.height), "\(unusable)")
            XCTAssertEqual(fixture.initializer.walletBirthday, bundledCheckpoint.height, "\(unusable)")
        }
    }
}
