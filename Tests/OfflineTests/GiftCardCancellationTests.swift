import XCTest

@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class GiftCardCancellationTests: ZcashTestCase {
    func testGiftCheckStartsSlipstreamEngine() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let host = await fixture.redeemer.cardWalletSynchronizer()
        XCTAssertTrue(host is SlipstreamSynchronizer, "Gift wallets must use the Slipstream host")
        let calls = await fixture.engine.calls
        XCTAssertTrue(calls.contains("start"), "check must start the actual host's engine")
        try await fixture.redeemer.cleanup()
    }

    func testUncancelledRedemptionCreatesAndSubmits() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let result = try await fixture.redeemer.redeem(to: fixture.card.fundingAddress, memo: nil, recordIn: nil)
        XCTAssertEqual(result.results, [.success(txId: Data(repeating: 0xA1, count: 32))])
        XCTAssertEqual(result.fee, Zatoshi(10_000))
        XCTAssertEqual(result.amount, Zatoshi(40_000))
        XCTAssertEqual(fixture.backend.createProposedTransactionsProposalUskOvkPolicyReceivedArguments?.ovkPolicy, .discard)
        XCTAssertEqual(fixture.backend.createProposedTransactionsProposalUskOvkPolicyCallsCount, 1)
        XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 1)
        try await fixture.redeemer.cleanup()
    }

    // Removing cancellation forwarding at host entry must allow a cancelled claim through.
    func testCancellationAfterHostEntryBeforeNativeCreationPreventsSubmission() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let entered = XCTestExpectation(description: "host reached backend before native admission")
        let gate = GiftCardOperationGate()
        fixture.backend.createProposedTransactionsProposalUskOvkPolicyClosure = { _, _, _ in
            entered.fulfill()
            await gate.wait()
            try GiftCardTransactionCreationContext.admission?.beginNativeCreation()
            return [Data(repeating: 0xA1, count: 32)]
        }
        let redemption = Task {
            try await fixture.redeemer.redeem(to: fixture.card.fundingAddress, memo: nil, recordIn: nil)
        }
        await fulfillment(of: [entered], timeout: 5)
        redemption.cancel()
        await gate.open()
        await assertCancellation(redemption)
        XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 0)
        try await fixture.redeemer.cleanup()
    }

    func testCancelledQueuedRedemptionDoesNotCreateOrSubmit() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let predecessorEntered = XCTestExpectation(description: "preceding check proposes fee")
        let gate = GiftCardOperationGate()
        fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeClosure = { _, _, _, _ in
            predecessorEntered.fulfill()
            await gate.wait()
            return FfiProposalFixtures.makeProposal(steps: [FfiProposalFixtures.Step(inputValues: [50_000], changeValues: [], fee: 10_000)]).inner
        }
        let predecessor = Task { try await fixture.redeemer.check() }
        await fulfillment(of: [predecessorEntered], timeout: 5)

        let redemptionEntered = XCTestExpectation(description: "redemption entered redeemer actor")
        let redemptionFinished = XCTestExpectation(description: "cancelled queued redemption finished")
        let redemption = Task {
            defer { redemptionFinished.fulfill() }
            return try await fixture.redeemer.redeemForCancellationTest(to: fixture.card.fundingAddress, entered: redemptionEntered)
        }
        await fulfillment(of: [redemptionEntered], timeout: 5)
        // The helper stays on this actor until redeem suspends in serialized. This barrier
        // cannot execute before the redemption has joined the queue behind the held check.
        _ = await fixture.redeemer.cardWalletConfirmationsPolicy()
        redemption.cancel()
        fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeClosure = { _, _, _, _ in
            XCTFail("Cancelled queued redemption must not prepare a proposal")
            return FfiProposalFixtures.makeProposal(steps: [FfiProposalFixtures.Step(inputValues: [50_000], changeValues: [], fee: 10_000)]).inner
        }
        await gate.open()
        _ = try await predecessor.value
        await fulfillment(of: [redemptionFinished], timeout: 5)
        await assertCancellation(redemption)
        fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeClosure = nil

        XCTAssertEqual(fixture.backend.createProposedTransactionsProposalUskOvkPolicyCallsCount, 0)
        XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 0)
        let following = try await fixture.redeemer.check()
        XCTAssertEqual(following.state, .ready, "a cancelled operation must not poison the queue")
        try await fixture.redeemer.cleanup()
    }

    func testCancellationDuringPreparationDoesNotCreate() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        let proposalEntered = XCTestExpectation(description: "redemption preparing proposal")
        let gate = GiftCardOperationGate()
        fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeClosure = { _, _, _, _ in
            proposalEntered.fulfill()
            await gate.wait()
            return FfiProposalFixtures.makeProposal(steps: [FfiProposalFixtures.Step(inputValues: [50_000], changeValues: [], fee: 10_000)]).inner
        }
        let finished = XCTestExpectation(description: "cancelled preparation finished")
        let redemption = Task {
            defer { finished.fulfill() }
            return try await fixture.redeemer.redeem(to: fixture.card.fundingAddress, memo: nil, recordIn: nil)
        }
        await fulfillment(of: [proposalEntered], timeout: 5)
        redemption.cancel()
        fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeClosure = nil
        await gate.open()
        await fulfillment(of: [finished], timeout: 5)
        await assertCancellation(redemption)

        XCTAssertEqual(fixture.backend.createProposedTransactionsProposalUskOvkPolicyCallsCount, 0)
        XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 0)
        let following = try await fixture.redeemer.check()
        XCTAssertEqual(following.state, .ready)
        try await fixture.redeemer.cleanup()
    }

    func testCancellationAfterNativeAdmissionStillSubmitsAndRecords() async throws {
        try await assertCancellationAfterAdmission(at: .nativeCreation)
    }

    func testCancellationDuringPostNativeLookupStillSubmitsAndRecords() async throws {
        try await assertCancellationAfterAdmission(at: .lookup)
    }

    func testCancellationDuringSubmissionStillRecordsAcceptedReceipt() async throws {
        try await assertCancellationAfterAdmission(at: .submission)
    }

    func testCancellationDuringRecordingStillCompletesReceipt() async throws {
        try await assertCancellationAfterAdmission(at: .recording)
    }

    private enum CompletionStage {
        case nativeCreation
        case lookup
        case submission
        case recording
    }

    private func assertCancellationAfterAdmission(at stage: CompletionStage) async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let destination = try GiftCardDestinationFixture.make(storageDirectory: testTempDirectory, slipstream: true)
        _ = try await fixture.redeemer.check()
        let entered = XCTestExpectation(description: "owned completion reached cancellation gate")
        let gate = GiftCardOperationGate()
        fixture.backend.createProposedTransactionsProposalUskOvkPolicyClosure = { _, _, _ in
            try GiftCardTransactionCreationContext.admission?.beginNativeCreation()
            if stage == .nativeCreation {
                entered.fulfill()
                await gate.wait()
            }
            return [Data(repeating: 0xA1, count: 32)]
        }
        if stage == .lookup {
            fixture.backend.getTransactionTxIdClosure = { id in
                entered.fulfill()
                await gate.wait()
                try Task.checkCancellation()
                return TransactionData(txId: id, raw: Data([1]), expiryHeight: 3_000_100)
            }
        }
        if stage == .submission {
            fixture.service.submitSpendTransactionModeClosure = { _, _ in
                entered.fulfill()
                await gate.wait()
                try Task.checkCancellation()
                return SendResponse()
            }
        }
        if stage == .recording {
            destination.backend.decryptAndStoreTransactionTxBytesMinedHeightClosure = { _, _ in
                entered.fulfill()
                await gate.wait()
                try Task.checkCancellation()
                return Data(repeating: 0xA1, count: 32)
            }
        }
        let redemption = Task {
            try await fixture.redeemer.redeem(to: fixture.card.fundingAddress, memo: nil, recordIn: destination.synchronizer)
        }
        await fulfillment(of: [entered], timeout: 5)
        redemption.cancel()
        // Lookup runs again during receipt recording, after the open gate no longer matters.
        if stage == .lookup {
            fixture.backend.getTransactionTxIdClosure = { id in
                try Task.checkCancellation()
                return TransactionData(txId: id, raw: Data([1]), expiryHeight: 3_000_100)
            }
        }
        await gate.open()
        let result = try await redemption.value
        XCTAssertEqual(result.results, [.success(txId: Data(repeating: 0xA1, count: 32))])
        XCTAssertTrue(result.recordedInDestination)
        XCTAssertEqual(result.fee, Zatoshi(10_000))
        XCTAssertEqual(result.amount, Zatoshi(40_000))
        XCTAssertEqual(fixture.backend.createProposedTransactionsProposalUskOvkPolicyCallsCount, 1)
        XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 1)
        XCTAssertEqual(destination.backend.setTransactionTrustTxIdTrustedCallsCount, 1)
        try await fixture.redeemer.cleanup()
        try await fixture.redeemer.cleanup()
        XCTAssertEqual(fixture.backend.createProposedTransactionsProposalUskOvkPolicyCallsCount, 1)
        XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 1)
    }

    func testCleanupWaitsForAdmittedClaimBeforeWipe() async throws {
        let clock = GiftCardCleanupTestClock()
        defer { clock.dispose() }
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory, cleanupTiming: clock.timing)
        _ = try await fixture.redeemer.check()
        let entered = XCTestExpectation(description: "native creation admitted")
        let gate = GiftCardOperationGate()
        fixture.backend.createProposedTransactionsProposalUskOvkPolicyClosure = { _, _, _ in
            try GiftCardTransactionCreationContext.admission?.beginNativeCreation()
            entered.fulfill()
            await gate.wait()
            return [Data(repeating: 0xA1, count: 32)]
        }
        let redemption = Task {
            try await fixture.redeemer.redeem(to: fixture.card.fundingAddress, memo: nil, recordIn: nil)
        }
        await fulfillment(of: [entered], timeout: 5)
        let deadline = clock.expectSleep(at: 30_000_000_000)
        let cleanup = Task { try await fixture.redeemer.cleanup() }
        await fulfillment(of: [deadline], timeout: 5)
        let beforeCompletion = await fixture.engine.calls
        XCTAssertFalse(beforeCompletion.contains(where: GatedFakeSlipstreamEngine.isStop))
        await gate.open()
        let result = try await redemption.value
        XCTAssertEqual(result.results, [.success(txId: Data(repeating: 0xA1, count: 32))])
        try await cleanup.value
        let afterCompletion = await fixture.engine.calls
        XCTAssertTrue(afterCompletion.contains("stopForWalletChange"))
        let root = testTempDirectory.appendingPathComponent(fixture.card.synchronizerAlias.description)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 1)
    }

    private func assertCancellation(_ task: Task<GiftCardRedeemer.Redemption, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Cancelled redemption must throw before creating a claim")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error.localizedDescription)")
        }
    }
}

// Test helpers stay outside the SDK. There is no suspension between the signal and the
// public call, so a subsequent redeemer actor barrier proves admission to serialized.
private extension GiftCardRedeemer {
    func redeemForCancellationTest(to recipient: UnifiedAddress, entered: XCTestExpectation) async throws -> Redemption {
        entered.fulfill()
        return try await redeem(to: recipient, memo: nil, recordIn: nil)
    }
}

actor GiftCardOperationGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}

struct GiftCardCancellationFixture {
    let card: GiftCard
    let redeemer: GiftCardRedeemer
    let synchronizer: SlipstreamSynchronizer
    let backend: ZcashRustBackendWeldingMock
    let service: LightWalletServiceMock
    let engine: GatedFakeSlipstreamEngine
    let repository: TransactionRepositoryMock
    let initializer: Initializer
    let anchor: GiftCardAnchorCapture

    static func make(
        storageDirectory: URL,
        cardLink: String = GiftCardTests.zodlTestnetLink,
        spendableValue: Zatoshi = Zatoshi(50_000),
        chainTip: UInt64 = 3_000_010,
        isTorEnabled: Bool = false,
        cleanupTiming: GiftCardCleanupTiming = .live,
        checkTiming: GiftCardCleanupTiming = .live,
        checkPolicy: GiftCardCheckPolicy? = nil,
        torClient: TorClient? = nil
    ) async throws -> GiftCardCancellationFixture {
        let card = try GiftCard(link: cardLink)
        let network = ZcashNetworkBuilder.network(for: card.network)
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
        let accountState = GiftCardFixtureAccountState(account: account)
        backend.initDataDbSeedReturnValue = .success
        backend.listAccountsClosure = { await accountState.accounts() }
        backend.createAccountSeedTreeStateRecoverUntilNameKeySourceClosure = { _, _, _, _, _ in
            await accountState.markCreated()
            return UnifiedSpendingKey(network: card.network, bytes: [])
        }
        let balance = AccountBalance(
            saplingBalance: .zero,
            orchardBalance: PoolBalance(spendableValue: spendableValue, changePendingConfirmation: .zero, valuePendingSpendability: .zero),
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
        backend.getWalletSummaryReturnValue = summary
        backend.proposeSendMaxTransferAccountUUIDToMemoModeReturnValue =
            FfiProposalFixtures.makeProposal(
                steps: [FfiProposalFixtures.Step(inputValues: [50_000], changeValues: [], fee: 10_000)]
            ).inner
        backend.createProposedTransactionsProposalUskOvkPolicyReturnValue = [Data(repeating: 0xA1, count: 32)]
        backend.getTransactionTxIdReturnValue = TransactionData(txId: Data(repeating: 0xA1, count: 32), raw: Data([1]), expiryHeight: 3_000_100)
        let service = LightWalletServiceMock()
        service.closeConnectionsClosure = {}
        service.getTreeStateModeClosure = { _, _ in throw LightWalletServiceError.timeOut }
        // The submission is judged at the height of the server it goes to, which stands where the card wallet's chain tip does.
        service.latestBlockHeightModeReturnValue = 3_000_010
        service.submitSpendTransactionModeReturnValue = SendResponse()
        let repository = TransactionRepositoryMock()
        repository.closeDBConnectionClosure = {}
        repository.findForResubmissionUpToReturnValue = []
        repository.findRawIDReturnValue = TestsData(networkType: .testnet).pendingTransactionEntity
        let storage = CompactBlockRepositoryMock()
        storage.createClosure = {}
        storage.clearClosure = {}
        container.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in backend }
        container.mock(type: LightWalletService.self, isSingleton: true) { _ in service }
        container.mock(type: TransactionRepository.self, isSingleton: true) { _ in repository }
        container.mock(type: CompactBlockRepository.self, isSingleton: true) { _ in storage }
        if let torClient { container.mock(type: TorClient.self, isSingleton: true) { _ in torClient } }
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(
            SlipstreamSnapshot(
                chainTip: 0,
                fetchedBlocks: 0,
                scannedBlocks: 0,
                enhancedTxs: 0,
                currentRangeEnd: 0,
                state: 0
            )
        )
        await engine.setSnapshotOnStart(
            SlipstreamSnapshot(
                chainTip: chainTip,
                fetchedBlocks: 0,
                scannedBlocks: 0,
                enhancedTxs: 0,
                currentRangeEnd: 0,
                state: 3,
                progressPermille: 1000,
                tipFresh: 1
            )
        )
        await engine.setNextWalletSummary(summary)
        let anchor = GiftCardAnchorCapture()
        await anchor.setResponse(SlipstreamRestoreAnchor(height: 4_460_000, treeState: nil))
        var synchronizer: SlipstreamSynchronizer!
        var capturedInitializer: Initializer!
        let redeemer = try GiftCardRedeemer(
            card: card,
            network: network,
            endpoint: LightWalletEndpoint(address: "127.0.0.1", port: 1, secure: false),
            isTorEnabled: isTorEnabled,
            storageDirectory: storageDirectory,
            loggingPolicy: .noLogging,
            container: container,
            makeSynchronizer: { initializer in
                capturedInitializer = initializer
                synchronizer = SlipstreamSynchronizer(
                    initializer: initializer,
                    alternateEndpoints: [],
                    engine: engine,
                    restoreAnchor: { isRestore, birthday, fallback, endpoint, network, torDirPath in
                        await anchor.resolve(
                            isRestore: isRestore,
                            birthday: birthday,
                            fallbackCheckpointHeight: fallback,
                            endpoint: endpoint,
                            network: network,
                            torDirPath: torDirPath
                        )
                    }
                )
                return synchronizer
            },
            cleanupTiming: cleanupTiming,
            checkTiming: checkTiming,
            checkPolicy: checkPolicy,
            saplingParamsSourceURL: .tests
        )
        return GiftCardCancellationFixture(
            card: card,
            redeemer: redeemer,
            synchronizer: synchronizer,
            backend: backend,
            service: service,
            engine: engine,
            repository: repository,
            initializer: capturedInitializer,
            anchor: anchor
        )
    }
}
