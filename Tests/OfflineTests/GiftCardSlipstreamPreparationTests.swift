import XCTest

@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class GiftCardSlipstreamPreparationTests: ZcashTestCase {
    func testOlderGiftExactBirthdayKeepsIndependentLatestRecoveryFallback() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let latestCheckpointHeight = CheckpointSourceFactory.fromBundle(for: .testnet).latestKnownCheckpoint().height
        fixture.service.getTreeStateModeClosure = nil
        var exact = TreeState()
        exact.height = 2_999_999
        exact.hash = "00"
        exact.time = 1
        exact.saplingTree = "00"
        fixture.service.getTreeStateModeReturnValue = exact
        _ = try await fixture.redeemer.check()
        let calls = await fixture.anchor.calls
        XCTAssertEqual(calls.first?.birthday, 2_999_999)
        XCTAssertEqual(calls.first?.fallbackCheckpointHeight, latestCheckpointHeight)
        XCTAssertEqual(fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceReceivedArguments?.treeState.height, 2_999_999)
        try await fixture.redeemer.cleanup()
    }

    func testInitializerUsesLatestKnownCheckpointIndependentlyOfBirthdayLookup() async throws {
        let fixture = try await GiftCardSlipstreamFixture.make(storageDirectory: testTempDirectory, isTorEnabled: false)
        let latestCheckpointHeight = CheckpointSourceFactory.fromBundle(for: .testnet).latestKnownCheckpoint().height
        let source = GiftCardCheckpointSource(bundled: CheckpointSourceFactory.fromBundle(for: .testnet))
        var state = TreeState()
        state.height = 2_999_999
        state.hash = "00"
        state.saplingTree = "00"
        source.use(state, forBirthday: 3_000_000)
        fixture.initializer.container.mock(type: CheckpointSource.self, isSingleton: true) { _ in source }
        let anchor = fixture.anchor
        let endpoint = fixture.initializer.endpoint
        let network = fixture.initializer.network
        fixture.initializer.slipstreamAnchorSource = { isRestore, birthday, fallback in
            await anchor.resolve(
                isRestore: isRestore,
                birthday: birthday,
                fallbackCheckpointHeight: fallback,
                endpoint: endpoint,
                network: network,
                torDirPath: nil
            )
        }
        await anchor.setResponse(SlipstreamRestoreAnchor(height: latestCheckpointHeight, treeState: nil))
        _ = try await fixture.initializer.initialize(
            with: fixture.card.seed.withBytes { $0 },
            walletBirthday: 3_000_000,
            name: "Gift card",
            keySource: nil
        )
        let calls = await anchor.calls
        XCTAssertEqual(calls.first?.fallbackCheckpointHeight, latestCheckpointHeight)
        XCTAssertEqual(fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceReceivedArguments?.treeState.height, 2_999_999)
        XCTAssertEqual(
            fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceReceivedArguments?.recoverUntil,
            UInt32(latestCheckpointHeight)
        )
    }

    func testGiftBirthdayFallbackAndRoutesUseRealHostRequests() async throws {
        let latestCheckpointHeight = CheckpointSourceFactory.fromBundle(for: .testnet).latestKnownCheckpoint().height
        for isTorEnabled in [false, true] {
            for responseHeight: UInt64? in [2_999_999, 3_000_000, nil] {
                let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory, isTorEnabled: isTorEnabled)
                if let responseHeight {
                    fixture.service.getTreeStateModeClosure = nil
                    var state = TreeState()
                    state.height = responseHeight
                    state.hash = "00"
                    state.saplingTree = "00"
                    fixture.service.getTreeStateModeReturnValue = state
                }
                _ = try await fixture.redeemer.check()
                let request = try XCTUnwrap(fixture.service.getTreeStateModeReceivedArguments)
                XCTAssertEqual(request.id.height, 2_999_999)
                XCTAssertEqual(request.mode, isTorEnabled ? .uniqueTor : .direct)
                let created = try XCTUnwrap(fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceReceivedArguments)
                XCTAssertEqual(created.treeState.height, responseHeight == 2_999_999 ? 2_999_999 : 2_990_000)
                let calls = await fixture.anchor.calls
                XCTAssertEqual(calls.first?.fallbackCheckpointHeight, latestCheckpointHeight)
                XCTAssertEqual(calls.first?.endpoint.host, "127.0.0.1")
                if isTorEnabled {
                    XCTAssertEqual(calls.first?.torDirPath, fixture.initializer.torDirURL.appendingPathComponent("slipstream").path)
                } else {
                    XCTAssertNil(calls.first?.torDirPath)
                }
                _ = try await fixture.redeemer.check()
                XCTAssertEqual(fixture.service.getTreeStateModeCallsCount, 1)
                XCTAssertEqual(fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceCallsCount, 1)
                try await fixture.redeemer.cleanup()
            }
        }
    }

    func testGiftStatesAndFeeUseEngineBalancesAndRealProposal() async throws {
        let cases: [GiftCardExpectedState] = [
            GiftCardExpectedState(spendable: 50_000, pending: 0, state: .ready, fee: 10_000, redeemable: 40_000),
            GiftCardExpectedState(spendable: 0, pending: 50_000, state: .pending, fee: nil, redeemable: 0),
            GiftCardExpectedState(spendable: 10_000, pending: 0, state: .dust, fee: nil, redeemable: 0),
            GiftCardExpectedState(spendable: 0, pending: 0, state: .empty, fee: nil, redeemable: 0)
        ]
        for expected in cases {
            let spendable = expected.spendable
            let pending = expected.pending
            let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
            let balance = AccountBalance(
                saplingBalance: .zero,
                orchardBalance: PoolBalance(
                    spendableValue: Zatoshi(spendable),
                    changePendingConfirmation: .zero,
                    valuePendingSpendability: Zatoshi(pending)
                ),
                unshielded: .zero
            )
            await fixture.engine.setNextWalletSummary(
                WalletSummary(
                    accountBalances: [TestsData.mockedAccountUUID: balance],
                    chainTipHeight: 3_000_010,
                    fullyScannedHeight: 3_000_010,
                    recoveryProgress: nil,
                    scanProgress: nil,
                    nextSaplingSubtreeIndex: 0,
                    nextOrchardSubtreeIndex: 0,
                    nextIronwoodSubtreeIndex: 0
                )
            )
            if expected.state == .dust {
                fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeThrowableError = ZcashError.rustProposalInsufficientFunds(
                    Zatoshi(10_000),
                    Zatoshi(10_000)
                )
            }
            let status = try await fixture.redeemer.check()
            XCTAssertEqual(status.state, expected.state)
            XCTAssertEqual(status.fee?.amount, expected.fee)
            XCTAssertEqual(status.redeemable.amount, expected.redeemable)
            XCTAssertEqual(status.total.amount, spendable + pending)
            try await fixture.redeemer.cleanup()
        }
    }

    func testRestoreUsesInjectedAnchorWithoutNetwork() async throws {
        let fixture = try await GiftCardSlipstreamFixture.make(
            storageDirectory: testTempDirectory,
            isTorEnabled: false
        )
        let latestCheckpointHeight = CheckpointSourceFactory.fromBundle(for: .testnet).latestKnownCheckpoint().height
        await fixture.anchor.setResponse(SlipstreamRestoreAnchor(height: latestCheckpointHeight, treeState: nil))

        let result = try await fixture.synchronizer.prepare(
            with: fixture.card.seed.withBytes { $0 },
            walletBirthday: 3_000_000,
            name: "Gift card",
            keySource: nil
        )

        guard case .success = result else {
            return XCTFail("Expected a prepared wallet")
        }
        let calls = await fixture.anchor.calls
        XCTAssertEqual(calls.count, 1, "The restore must use the injected offline resolver")
        let call = try XCTUnwrap(calls.first)
        XCTAssertTrue(call.isRestore)
        XCTAssertEqual(call.birthday, 3_000_000)
        XCTAssertEqual(call.fallbackCheckpointHeight, latestCheckpointHeight)
        XCTAssertEqual(call.endpoint.host, "127.0.0.1")
        XCTAssertEqual(call.endpoint.port, 1)
        XCTAssertEqual(call.network.networkType, .testnet)
        XCTAssertNil(call.torDirPath)

        let created = try XCTUnwrap(fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceReceivedArguments)
        XCTAssertEqual(created.treeState.height, 3_000_000)
        XCTAssertEqual(created.treeState.hash, "0031432018aa59e440804fa87974ec791ae174fa2909470f3c3a8a93842a659f")
        XCTAssertEqual(created.recoverUntil, UInt32(latestCheckpointHeight))
        XCTAssertEqual(fixture.synchronizer.latestState.accountsBalances[fixture.account.id], fixture.balance)
        XCTAssertEqual(fixture.synchronizer.latestState.latestBlockHeight, 3_000_010)
        XCTAssertEqual(fixture.service.latestBlockHeightModeCallsCount, 0)
        XCTAssertEqual(fixture.service.getTreeStateModeCallsCount, 0)
    }

    func testAbnormalNilNativeAnchorDoesNotUseLegacyNetworkOrInventRecoveryBound() async throws {
        let fixture = try await GiftCardSlipstreamFixture.make(storageDirectory: testTempDirectory, isTorEnabled: false)
        await fixture.anchor.setResponse(nil)
        _ = try await fixture.synchronizer.prepare(
            with: fixture.card.seed.withBytes { $0 },
            walletBirthday: 3_000_000,
            name: "Gift card",
            keySource: nil
        )
        let created = try XCTUnwrap(fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceReceivedArguments)
        XCTAssertNil(created.recoverUntil)
        XCTAssertEqual(created.treeState.height, 3_000_000)
        XCTAssertEqual(fixture.service.latestBlockHeightModeCallsCount, 0)
        XCTAssertEqual(fixture.service.getTreeStateModeCallsCount, 0)
    }

    func testProtectedRestorePassesTorDirectoryAndNeverCallsDirectService() async throws {
        let fixture = try await GiftCardSlipstreamFixture.make(
            storageDirectory: testTempDirectory,
            isTorEnabled: true
        )
        let latestCheckpointHeight = CheckpointSourceFactory.fromBundle(for: .testnet).latestKnownCheckpoint().height
        await fixture.anchor.setResponse(SlipstreamRestoreAnchor(height: latestCheckpointHeight, treeState: nil))

        _ = try await fixture.synchronizer.prepare(
            with: fixture.card.seed.withBytes { $0 },
            walletBirthday: 3_000_000,
            name: "Gift card",
            keySource: nil
        )

        let calls = await fixture.anchor.calls
        let call = try XCTUnwrap(calls.first)
        let expectedDirectory = fixture.torDirectory.appendingPathComponent("slipstream", isDirectory: true)
        XCTAssertEqual(call.torDirPath, expectedDirectory.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedDirectory.path))
        XCTAssertEqual(fixture.service.latestBlockHeightModeCallsCount, 0)
        XCTAssertEqual(fixture.service.getTreeStateModeCallsCount, 0)
    }

    func testDirectRestorePassesNilTorDirectory() async throws {
        let fixture = try await GiftCardSlipstreamFixture.make(
            storageDirectory: testTempDirectory,
            isTorEnabled: false
        )
        let latestCheckpointHeight = CheckpointSourceFactory.fromBundle(for: .testnet).latestKnownCheckpoint().height
        await fixture.anchor.setResponse(SlipstreamRestoreAnchor(height: latestCheckpointHeight, treeState: nil))

        _ = try await fixture.synchronizer.prepare(
            with: fixture.card.seed.withBytes { $0 },
            walletBirthday: 2_990_000,
            name: "Gift card",
            keySource: nil
        )

        let calls = await fixture.anchor.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertNil(call.torDirPath)
        XCTAssertEqual(fixture.service.latestBlockHeightModeCallsCount, 0)
        XCTAssertEqual(fixture.service.getTreeStateModeCallsCount, 0)
    }

    func testOfflineRestoreKeepsNonemptyRecoveryBeyondLatestCheckpoint() async throws {
        let fixture = try await GiftCardSlipstreamFixture.make(
            storageDirectory: testTempDirectory,
            isTorEnabled: false
        )
        // The native offline policy returns max(latest checkpoint, resolved birthday + 1).
        // A requested birthday beyond bundled checkpoints resolves to their latest entry.
        let latestCheckpointHeight = CheckpointSourceFactory.fromBundle(for: .testnet).latestKnownCheckpoint().height
        await fixture.anchor.setResponse(SlipstreamRestoreAnchor(height: latestCheckpointHeight + 1, treeState: nil))

        _ = try await fixture.synchronizer.prepare(
            with: fixture.card.seed.withBytes { $0 },
            walletBirthday: latestCheckpointHeight + 10_000,
            name: "Gift card",
            keySource: nil
        )

        let calls = await fixture.anchor.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertTrue(call.isRestore)
        XCTAssertEqual(call.birthday, latestCheckpointHeight)
        XCTAssertEqual(call.fallbackCheckpointHeight, latestCheckpointHeight)
        let created = try XCTUnwrap(fixture.backend.createAccountSeedTreeStateRecoverUntilNameKeySourceReceivedArguments)
        XCTAssertEqual(created.treeState.height, UInt64(latestCheckpointHeight))
        XCTAssertEqual(created.recoverUntil, UInt32(latestCheckpointHeight + 1))
    }
}

private struct GiftCardExpectedState {
    let spendable: Int64
    let pending: Int64
    let state: GiftCardStatus.State
    let fee: Int64?
    let redeemable: Int64
}
