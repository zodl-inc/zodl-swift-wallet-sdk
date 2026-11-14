//
//  BroadcasterTests.swift
//  ZODLSwiftWalletSDK
//

import Combine
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class BroadcasterTests: ZcashTestCase {
    private var cancellables: [AnyCancellable] = []

    override func setUp() async throws {
        try await super.setUp()
        cancellables = []
    }

    override func tearDown() async throws {
        cancellables = []
        try await super.tearDown()
    }

    // MARK: - Create

    func testCreateProposedTransactionsReturnsCreatedTransactionsAndEmitsEvent() async throws {
        let rawTransaction = Data([0x01, 0x02, 0x03, 0x04])
        let rawID = Data(repeating: 0xAB, count: 32)
        let overviews = [makeTransaction(raw: rawTransaction, rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)

        let foundTransactionsExpectation = XCTestExpectation(description: "found transactions event")
        synchronizer.eventStream
            .sink { event in
                guard case let .foundTransactions(transactions, range) = event else { return }
                XCTAssertNil(range)
                XCTAssertEqual(transactions.map(\.rawID), [rawID])
                foundTransactionsExpectation.fulfill()
            }
            .store(in: &cancellables)

        await synchronizer.updateStatus(.stopped)

        let proposal = Proposal.testOnlyFakeProposal(totalFee: 10)
        let spendingKey = TestsData(networkType: .testnet).spendingKey

        let transactions = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: proposal,
            spendingKey: spendingKey
        )

        XCTAssertEqual(transactions.map(\.txId), [rawID])
        XCTAssertEqual(transactions.map(\.raw), [rawTransaction])
        await fulfillment(of: [foundTransactionsExpectation], timeout: 1.0)
    }

    func testCreateProposedTransactionsContinuesWhenHistoryViewDoesNotContainCreatedTransaction() async throws {
        let rawTransaction = Data([0x01, 0x02, 0x03, 0x04])
        let rawID = Data(repeating: 0xAB, count: 32)
        let overviews = [makeTransaction(raw: rawTransaction, rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(
            createdTransactions: overviews,
            fetchError: ZcashError.transactionRepositoryEntityNotFound
        )
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let transactions = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        XCTAssertEqual(transactions.map(\.txId), [rawID])
        XCTAssertEqual(transactions.map(\.raw), [rawTransaction])

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.awaiting)
    }

    func testCreateProposedTransactionsContinuesWhenHistoryEnrichmentThrowsAnotherError() async throws {
        struct TransientHistoryError: Error {}
        let rawTransaction = Data([0x01, 0x02, 0x03, 0x04])
        let rawID = Data(repeating: 0xAC, count: 32)
        let transactionEncoder = StubTransactionEncoder(
            createdTransactions: [makeTransaction(raw: rawTransaction, rawID: rawID)],
            fetchError: TransientHistoryError()
        )
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let transactions = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        XCTAssertEqual(transactions, [CreatedTransaction(txId: rawID, raw: rawTransaction, expiryHeight: 123_456)])
        let plan = await mockContainer.resolve(SubmitPlanStoring.self).plan(for: rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.awaiting)
    }

    func testCreateProposedTransactionsEmitsAvailableHistoryWhenOnlyOneOverviewIsMissing() async throws {
        let foundRawID = Data(repeating: 0xAB, count: 32)
        let missingRawID = Data(repeating: 0xCD, count: 32)
        let overviews = [
            makeTransaction(raw: Data([0x01]), rawID: foundRawID),
            makeTransaction(raw: Data([0x02]), rawID: missingRawID)
        ]
        let transactionEncoder = StubTransactionEncoder(
            createdTransactions: overviews,
            missingHistoryTxIds: [missingRawID]
        )
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        let foundTransactionsExpectation = XCTestExpectation(description: "available history event")
        synchronizer.eventStream
            .sink { event in
                guard case let .foundTransactions(transactions, range) = event else { return }
                XCTAssertNil(range)
                XCTAssertEqual(transactions.map(\.rawID), [foundRawID])
                foundTransactionsExpectation.fulfill()
            }
            .store(in: &cancellables)
        await synchronizer.updateStatus(.stopped)

        let transactions = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        XCTAssertEqual(transactions.map(\.txId), [foundRawID, missingRawID])
        await fulfillment(of: [foundTransactionsExpectation], timeout: 1.0)
    }

    func testCreateMarksTransactionsAwaitingSubmission() async throws {
        let rawID = Data(repeating: 0xAB, count: 32)
        let overviews = [makeTransaction(raw: Data([0x01]), rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        _ = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.awaiting)
    }

    func testWalletTransactionEncoderReadsCreatedTransactionThroughGeneralFFI() async throws {
        let rawID = Data(repeating: 0xBC, count: 32)
        let transactionData = TransactionData(
            txId: rawID,
            raw: Data([0x01, 0x02, 0x03]),
            expiryHeight: 123_456
        )
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.createProposedTransactionsProposalUskOvkPolicySizeBoundReturnValue = [rawID]
        rustBackend.getTransactionTxIdReturnValue = transactionData
        let encoder = WalletTransactionEncoder(
            rustBackend: rustBackend,
            dataDb: try __dataDbURL(),
            fsBlockDbRoot: testTempDirectory,
            service: LightWalletServiceMock(),
            repository: TransactionRepositoryMock(),
            outputParams: try __outputParamsURL(),
            spendParams: try __spendParamsURL(),
            networkType: .testnet,
            logger: submissionLifecycleLogger(),
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        )

        let transactions = try await encoder.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        XCTAssertEqual(transactions, [CreatedTransaction(transactionData: transactionData)])
        XCTAssertEqual(rustBackend.getTransactionTxIdReceivedTxId, rawID)
    }

    func testWalletTransactionEncoderReportsFailedAndAlreadyReadTransactionIds() async throws {
        let firstTxId = Data(repeating: 0xBC, count: 32)
        let missingTxId = Data(repeating: 0xBD, count: 32)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.createProposedTransactionsProposalUskOvkPolicySizeBoundReturnValue = [firstTxId, missingTxId]
        rustBackend.getTransactionTxIdClosure = { txId in
            guard txId == firstTxId else { return nil }
            return TransactionData(txId: firstTxId, raw: Data([0x01]), expiryHeight: 123_456)
        }
        let encoder = WalletTransactionEncoder(
            rustBackend: rustBackend,
            dataDb: try __dataDbURL(),
            fsBlockDbRoot: testTempDirectory,
            service: LightWalletServiceMock(),
            repository: TransactionRepositoryMock(),
            outputParams: try __outputParamsURL(),
            spendParams: try __spendParamsURL(),
            networkType: .testnet,
            logger: submissionLifecycleLogger(),
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        )

        do {
            _ = try await encoder.createProposedTransactions(
                proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
                spendingKey: TestsData(networkType: .testnet).spendingKey
            )
            XCTFail("Expected wallet-store readback to fail")
        } catch ZcashError.rustGetTransaction(let message) {
            XCTAssertTrue(message.contains(missingTxId.toHexStringTxId()))
            XCTAssertTrue(message.contains(firstTxId.toHexStringTxId()))
        } catch {
            XCTFail("Expected rustGetTransaction but got \(error.localizedDescription)")
        }
    }

    func testCreateTransactionFromPCZTMarksAwaitingAndEmitsEvent() async throws {
        let rawID = Data(repeating: 0xCD, count: 32)
        let overviews = [makeTransaction(raw: Data([0x05, 0x06]), rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.extractAndStoreTxFromPCZTPcztWithProofsPcztWithSigsReturnValue = rawID
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder, rustBackend: rustBackend)
        await synchronizer.updateStatus(.stopped)

        let transactions = try await synchronizer.broadcaster.createTransactionFromPCZT(
            pcztWithProofs: Pczt([0x10, 0x11]),
            pcztWithSigs: Pczt([0x12, 0x13])
        )

        XCTAssertEqual(transactions.map(\.txId), [rawID])
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.awaiting)
    }

    func testCreateTransactionFromPCZTContinuesWhenHistoryViewDoesNotContainCreatedTransaction() async throws {
        let rawID = Data(repeating: 0xCD, count: 32)
        let rawTransaction = Data([0x05, 0x06])
        let overviews = [makeTransaction(raw: rawTransaction, rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(
            createdTransactions: overviews,
            fetchError: ZcashError.transactionRepositoryEntityNotFound
        )
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.extractAndStoreTxFromPCZTPcztWithProofsPcztWithSigsReturnValue = rawID
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder, rustBackend: rustBackend)
        await synchronizer.updateStatus(.stopped)

        let transactions = try await synchronizer.broadcaster.createTransactionFromPCZT(
            pcztWithProofs: Pczt([0x10, 0x11]),
            pcztWithSigs: Pczt([0x12, 0x13])
        )

        XCTAssertEqual(transactions, [CreatedTransaction(txId: rawID, raw: rawTransaction, expiryHeight: 123_456)])
    }

    // MARK: - Outgoing viewing key policy

    func testCreateProposedTransactionsDefaultsToTheSenderOvkPolicy() async throws {
        let rawID = Data(repeating: 0xA1, count: 32)
        let transactionEncoder = StubTransactionEncoder(createdTransactions: [makeTransaction(raw: Data([0x01]), rawID: rawID)])
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        _ = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        XCTAssertEqual(transactionEncoder.receivedOvkPolicy, .sender)
    }

    func testBroadcasterPassesTheDiscardOvkPolicyToTheEncoder() async throws {
        let rawID = Data(repeating: 0xA2, count: 32)
        let transactionEncoder = StubTransactionEncoder(createdTransactions: [makeTransaction(raw: Data([0x01]), rawID: rawID)])
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let transactions = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey,
            ovkPolicy: .discard,
            sizeBound: .consensus
        )

        XCTAssertEqual(transactions.map(\.txId), [rawID])
        XCTAssertEqual(transactionEncoder.receivedOvkPolicy, .discard)
    }

    func testSynchronizerPassesTheDiscardOvkPolicyToTheEncoder() async throws {
        let rawID = Data(repeating: 0xA3, count: 32)
        let transactionEncoder = StubTransactionEncoder(createdTransactions: [makeTransaction(raw: Data([0x01]), rawID: rawID)])
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let stream = try await synchronizer.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey,
            ovkPolicy: .discard
        )
        var results: [TransactionSubmitResult] = []
        for try await result in stream {
            results.append(result)
        }

        XCTAssertEqual(results, [.success(txId: rawID)])
        XCTAssertEqual(transactionEncoder.receivedOvkPolicy, .discard)
    }

    func testWalletTransactionEncoderPassesTheOvkPolicyToTheRustBackend() async throws {
        let rawID = Data(repeating: 0xA4, count: 32)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.createProposedTransactionsProposalUskOvkPolicySizeBoundReturnValue = [rawID]
        rustBackend.getTransactionTxIdReturnValue = TransactionData(txId: rawID, raw: Data([0x01]), expiryHeight: 1)
        let encoder = makeWalletTransactionEncoder(rustBackend: rustBackend)

        for policy in [OvkPolicy.sender, .discard] {
            _ = try await encoder.createProposedTransactions(
                proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
                spendingKey: TestsData(networkType: .testnet).spendingKey,
                ovkPolicy: policy,
                sizeBound: .consensus
            )
            XCTAssertEqual(rustBackend.createProposedTransactionsProposalUskOvkPolicySizeBoundReceivedArguments?.ovkPolicy, policy)
        }
    }

    func testOvkPolicyFFIValues() {
        XCTAssertEqual(OvkPolicy.sender.ffiValue, 0)
        XCTAssertEqual(OvkPolicy.discard.ffiValue, 1)
    }

    func testDefaultBroadcasterOverloadRefusesToDiscardTheOvk() async throws {
        let broadcaster = SenderOnlyBroadcaster()
        let spendingKey = TestsData(networkType: .testnet).spendingKey

        _ = try await broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: spendingKey,
            ovkPolicy: .sender
        )
        XCTAssertEqual(broadcaster.createCallsCount, 1)

        do {
            _ = try await broadcaster.createProposedTransactions(
                proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
                spendingKey: spendingKey,
                ovkPolicy: .discard
            )
            XCTFail("A conformer without a discarding implementation must refuse OvkPolicy.discard")
        } catch is OvkPolicyUnsupported {
            XCTAssertEqual(broadcaster.createCallsCount, 1)
        }
    }

    // MARK: - Sapling parameters

    func testProposalSaplingRequirementIsDecidedByTheRustLayer() throws {
        XCTAssertFalse(try ZcashRustBackend.proposalRequiresSaplingParams(Self.proposal(inputPool: .orchard, paymentPool: .orchard)))
        XCTAssertFalse(try ZcashRustBackend.proposalRequiresSaplingParams(Self.proposal(inputPool: .ironwood, paymentPool: .ironwood)))
        XCTAssertFalse(
            try ZcashRustBackend.proposalRequiresSaplingParams(
                Self.proposal(inputPool: .orchard, paymentPool: .ironwood, changePool: .ironwood)
            )
        )
        XCTAssertTrue(try ZcashRustBackend.proposalRequiresSaplingParams(Self.proposal(inputPool: .sapling, paymentPool: .orchard)))
        XCTAssertTrue(try ZcashRustBackend.proposalRequiresSaplingParams(Self.proposal(inputPool: .orchard, paymentPool: .sapling)))
        XCTAssertTrue(
            try ZcashRustBackend.proposalRequiresSaplingParams(
                Self.proposal(inputPool: .orchard, paymentPool: .orchard, changePool: .sapling)
            )
        )
        XCTAssertTrue(
            try ZcashRustBackend.proposalRequiresSaplingParams(
                Self.proposal(inputPool: .orchard, paymentPool: .orchard, saplingDummies: 1)
            )
        )
    }

    func testWalletTransactionEncoderCreatesNonSaplingProposalsWithoutParameters() async throws {
        let rawID = Data(repeating: 0xA5, count: 32)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.createProposedTransactionsProposalUskOvkPolicySizeBoundReturnValue = [rawID]
        rustBackend.getTransactionTxIdReturnValue = TransactionData(txId: rawID, raw: Data([0x01]), expiryHeight: 1)
        let missing = testTempDirectory.appendingPathComponent("missing", isDirectory: true)
        let encoder = makeWalletTransactionEncoder(
            rustBackend: rustBackend,
            spendParams: missing.appendingPathComponent("sapling-spend.params"),
            outputParams: missing.appendingPathComponent("sapling-output.params")
        )
        let spendingKey = TestsData(networkType: .testnet).spendingKey

        let transactions = try await encoder.createProposedTransactions(
            proposal: Proposal(inner: Self.proposal(inputPool: .ironwood, paymentPool: .ironwood)),
            spendingKey: spendingKey,
            ovkPolicy: .discard,
            sizeBound: .consensus
        )
        XCTAssertEqual(transactions.map(\.txId), [rawID])

        do {
            _ = try await encoder.createProposedTransactions(
                proposal: Proposal(inner: Self.proposal(inputPool: .sapling, paymentPool: .orchard)),
                spendingKey: spendingKey,
                ovkPolicy: .sender,
                sizeBound: .consensus
            )
            XCTFail("A Sapling proposal needs the parameters")
        } catch ZcashError.walletTransEncoderCreateTransactionMissingSaplingParams {
            XCTAssertEqual(rustBackend.createProposedTransactionsProposalUskOvkPolicySizeBoundCallsCount, 1)
        }
    }

    func testBroadcasterSkipsTheSaplingParameterDownloadForNonSaplingProposals() async throws {
        let rawID = Data(repeating: 0xA6, count: 32)
        let transactionEncoder = StubTransactionEncoder(createdTransactions: [makeTransaction(raw: Data([0x01]), rawID: rawID)])
        transactionEncoder.requiresSaplingParameters = false
        // Parameters that are neither on disk nor downloadable: any download attempt fails.
        let missing = testTempDirectory.appendingPathComponent("missing", isDirectory: true)
        let unreachable = SaplingParamsSourceURL(
            spendParamFileURL: missing.appendingPathComponent("source-spend.params"),
            outputParamFileURL: missing.appendingPathComponent("source-output.params")
        )
        let synchronizer = try makeSynchronizer(
            transactionEncoder: transactionEncoder,
            spendParamsURL: missing.appendingPathComponent("sapling-spend.params"),
            outputParamsURL: missing.appendingPathComponent("sapling-output.params"),
            saplingParamsSourceURL: unreachable
        )
        await synchronizer.updateStatus(.stopped)

        let transactions = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey,
            ovkPolicy: .discard
        )
        XCTAssertEqual(transactions.map(\.txId), [rawID])
        XCTAssertEqual(transactionEncoder.requiresSaplingParametersCallsCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.appendingPathComponent("sapling-spend.params").path))

        // The same setup fails for a proposal that needs the parameters, because the download is attempted.
        transactionEncoder.requiresSaplingParameters = true
        do {
            _ = try await synchronizer.broadcaster.createProposedTransactions(
                proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
                spendingKey: TestsData(networkType: .testnet).spendingKey
            )
            XCTFail("The parameter download should have been attempted and failed")
        } catch {
            XCTAssertEqual(transactionEncoder.requiresSaplingParametersCallsCount, 2)
        }
    }

    func testBroadcasterThrowsWhenNotPrepared() async throws {
        let transactionEncoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)

        do {
            _ = try await synchronizer.broadcaster.createProposedTransactions(
                proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
                spendingKey: TestsData(networkType: .testnet).spendingKey
            )
            XCTFail("Should throw when synchronizer is not prepared")
        } catch {
            XCTAssertTrue(error is ZcashError, "Expected ZcashError but got \(error)")
        }
    }

    func testBroadcasterThrowsWhenSynchronizerIsReleased() async throws {
        let transactionEncoder = StubTransactionEncoder(createdTransactions: [])
        var synchronizer: SDKSynchronizer? = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer?.updateStatus(.stopped)

        let broadcaster = try XCTUnwrap(synchronizer?.broadcaster)
        synchronizer = nil
        await Task.yield()

        do {
            _ = try await broadcaster.createProposedTransactions(
                proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
                spendingKey: TestsData(networkType: .testnet).spendingKey
            )
            XCTFail("Should throw when the owning synchronizer has been released")
        } catch ZcashError.synchronizerNotPrepared {
            // expected
        } catch {
            XCTFail("Expected synchronizerNotPrepared but got \(error)")
        }
    }

    // MARK: - Submit (single, via real local gRPC servers)

    func testSubmitRecordsPlanAndDeliversToEndpoint() async throws {
        let acceptingService = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: 0, errorMessage: ""))
        defer { try? acceptingService.stop() }
        let synchronizer = try makeSubmittingSynchronizer()
        let transaction = makeCreatedTransaction()

        let outcome = await synchronizer.broadcaster.submit(
            transaction: transaction,
            to: [acceptingService.endpoint]
        )

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.accepted(by: acceptingService.endpoint))
        XCTAssertEqual(acceptingService.recordedTransactions(), [transaction.raw])

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: transaction.txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([acceptingService.endpoint], acceptedBy: "\(acceptingService.endpoint.host):\(acceptingService.endpoint.port)"))
    }

    // MARK: - Wipe race: a late acceptance for a submission started before wipe()

    /// A `wipe()` that lands while a foreground `submit` is still racing its network call must win:
    /// the acceptance that eventually arrives belongs to a submission the caller already asked to
    /// forget, and applying it would recreate the submit-plan store file `wipe()` just deleted.
    func testWipeDuringSubmissionDropsALateAcceptance() async throws {
        let endpoint = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let endpointSubmitterMock = EndpointSubmitterMock()
        let gate = Gate()
        endpointSubmitterMock.set(behavior: .gated(gate, then: .succeed), for: endpoint)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let transaction = makeCreatedTransaction()
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plansDatabaseURL = submitPlanDatabaseURL(for: synchronizer)

        let submitTask = Task {
            await synchronizer.broadcaster.submit(transaction: transaction, to: [endpoint])
        }
        await endpointSubmitterMock.awaitSubmissionStarted(to: endpoint)

        await store.wipe()
        gate.open()

        let outcome = await submitTask.value
        XCTAssertEqual(outcome, TransactionSubmissionOutcome.accepted(by: endpoint))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plansDatabaseURL.path),
            "a late acceptance for a submission that started before wipe() must not recreate the store file"
        )
        let plan = await store.plan(for: transaction.txId)
        XCTAssertNil(plan)
    }

    /// Control: a wipe racing a submission that ends up rejected (rather than accepted) must not
    /// change the outcome reported to the caller, and must still leave no plan behind — the drop is
    /// specific to a stale acceptance, not a side effect of wiping mid-flight.
    func testWipeDuringSubmissionDoesNotAffectALateRejection() async throws {
        let endpoint = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let endpointSubmitterMock = EndpointSubmitterMock()
        let gate = Gate()
        endpointSubmitterMock.set(behavior: .gated(gate, then: .reject(code: -25, message: "rejected")), for: endpoint)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let transaction = makeCreatedTransaction()
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plansDatabaseURL = submitPlanDatabaseURL(for: synchronizer)

        let submitTask = Task {
            await synchronizer.broadcaster.submit(transaction: transaction, to: [endpoint])
        }
        await endpointSubmitterMock.awaitSubmissionStarted(to: endpoint)

        await store.wipe()
        gate.open()

        let outcome = await submitTask.value
        XCTAssertEqual(
            outcome,
            TransactionSubmissionOutcome.rejected(code: -25, message: "rejected"),
            "a concurrent wipe must not change the outcome reported to the caller"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: plansDatabaseURL.path))
        let plan = await store.plan(for: transaction.txId)
        XCTAssertNil(plan)
    }

    /// Two simultaneous foreground submissions straddling a `wipe()`: the one that started before it
    /// has its late acceptance dropped, while one recorded after the wipe — a new lifecycle — accepts
    /// normally. Proves the drop is scoped to the specific submission the wipe raced, not to every
    /// acceptance the store sees afterward.
    func testWipeDropsOnlyThePreWipeSubmissionsAcceptance() async throws {
        let staleEndpoint = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let freshEndpoint = LightWalletEndpoint(address: "b.example.com", port: 9067, secure: false)
        let endpointSubmitterMock = EndpointSubmitterMock()
        let staleGate = Gate()
        endpointSubmitterMock.set(behavior: .gated(staleGate, then: .succeed), for: staleEndpoint)
        endpointSubmitterMock.set(behavior: .succeed, for: freshEndpoint)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let staleTransaction = makeCreatedTransaction(seed: 0x41)
        let freshTransaction = makeCreatedTransaction(seed: 0x42)
        let store = mockContainer.resolve(SubmitPlanStoring.self)

        let staleTask = Task {
            await synchronizer.broadcaster.submit(transaction: staleTransaction, to: [staleEndpoint])
        }
        await endpointSubmitterMock.awaitSubmissionStarted(to: staleEndpoint)
        await store.wipe()

        let freshOutcome = await synchronizer.broadcaster.submit(transaction: freshTransaction, to: [freshEndpoint])
        XCTAssertEqual(freshOutcome, TransactionSubmissionOutcome.accepted(by: freshEndpoint))

        staleGate.open()
        let staleOutcome = await staleTask.value
        XCTAssertEqual(staleOutcome, TransactionSubmissionOutcome.accepted(by: staleEndpoint))

        let stalePlan = await store.plan(for: staleTransaction.txId)
        XCTAssertNil(stalePlan, "the pre-wipe submission's late acceptance must not resurrect a plan")
        let freshPlan = await store.plan(for: freshTransaction.txId)
        XCTAssertEqual(
            freshPlan,
            StoredSubmitPlan.ready([freshEndpoint], acceptedBy: "\(freshEndpoint.host):\(freshEndpoint.port)")
        )
    }

    // MARK: - Release for resubmission

    /// A host that created transactions but could not hand them to a server itself releases them
    /// to the SDK's background resubmission: each transaction's plan moves straight to `.ready`
    /// with the given endpoints, and no network attempt is made.
    func testReleaseForResubmissionRecordsPlansWithoutSubmitting() async throws {
        let endpointA = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let endpointB = LightWalletEndpoint(address: "b.example.com", port: 9067, secure: false)
        let endpointSubmitterMock = EndpointSubmitterMock()
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let created = [makeCreatedTransaction(seed: 0xAB), makeCreatedTransaction(seed: 0xCD)]
        // A release always follows a creation, which already marked these transactions awaiting —
        // the store row that gives its backing file a reason to exist before this release call.
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let lifecycle = await store.currentLifecycle()
        await store.markAwaitingSubmission(txIds: created.map(\.txId), lifecycle: lifecycle)

        await synchronizer.broadcaster.releaseForResubmission(transactions: created, to: [endpointA, endpointB])

        XCTAssertTrue(endpointSubmitterMock.recordedSubmissions().isEmpty, "Releasing must not itself submit")
        for transaction in created {
            let plan = await store.plan(for: transaction.txId)
            XCTAssertEqual(plan, StoredSubmitPlan.ready([endpointA, endpointB], acceptedBy: nil))
        }
    }

    /// An empty endpoint list records nothing: a transaction already marked `.awaiting` by
    /// creation stays that way, so it remains excluded from background resubmission until the
    /// host releases it with real endpoints.
    func testReleaseForResubmissionWithEmptyEndpointsLeavesTransactionAwaiting() async throws {
        let rawID = Data(repeating: 0xEF, count: 32)
        let rawTransaction = Data([0x01, 0x02])
        let overviews = [makeTransaction(raw: rawTransaction, rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let created = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let planBefore = await store.plan(for: rawID)
        XCTAssertEqual(planBefore, StoredSubmitPlan.awaiting)

        await synchronizer.broadcaster.releaseForResubmission(transactions: created, to: [])

        let planAfter = await store.plan(for: rawID)
        XCTAssertEqual(planAfter, StoredSubmitPlan.awaiting, "An empty endpoint list must record nothing; the transaction stays awaiting")
    }

    // MARK: - Wipe race: a stale awaiting-mark for a transaction created before wipe()

    /// A `wipe()` that lands while a transaction is still being created (proving, PCZT
    /// extraction) must not have the eventual `markAwaitingSubmission` call recreate the deleted
    /// submit-plan store: the lifecycle token is captured before creation starts, so by the time
    /// `finishCreation` writes the awaiting mark, a wipe that landed meanwhile makes the token
    /// provably stale — mirroring the existing guard on a late `submit` acceptance.
    func testCreationDropsAwaitingMarkWhenWipedDuringCreation() async throws {
        let rawID = Data(repeating: 0xFA, count: 32)
        let rawTransaction = Data([0x01, 0x02, 0x03])
        let overviews = [makeTransaction(raw: rawTransaction, rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plansDatabaseURL = submitPlanDatabaseURL(for: synchronizer)
        transactionEncoder.onCreateProposedTransactions = {
            await store.wipe()
        }

        let created = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )
        XCTAssertEqual(created.map(\.txId), [rawID])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plansDatabaseURL.path),
            "a mark-awaiting call for a transaction created before wipe() must not recreate the store file"
        )
        let plan = await store.plan(for: rawID)
        XCTAssertNil(plan, "A wipe landing during creation must not be undone by a stale awaiting-mark")
    }

    /// The same race for a migration proposal: the migration mark written after creation carries
    /// the lifecycle captured before it, so a wipe meanwhile drops it and the store stays deleted.
    func testMigrationCreationDropsItsMarkWhenWipedDuringCreation() async throws {
        let rawID = Data(repeating: 0xFB, count: 32)
        let overviews = [makeTransaction(raw: Data([0x01, 0x02, 0x03]), rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plansDatabaseURL = submitPlanDatabaseURL(for: synchronizer)
        transactionEncoder.onCreateProposedTransactions = {
            await store.wipe()
        }
        var proposal = Proposal.testOnlyFakeProposal(totalFee: 10)
        proposal.isMigration = true

        let created = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: proposal,
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )
        XCTAssertEqual(created.map(\.txId), [rawID])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plansDatabaseURL.path),
            "a migration mark for a transaction created before wipe() must not recreate the store file"
        )
        let plan = await store.plan(for: rawID)
        XCTAssertNil(plan)
        let marked = await store.isMigrationPreparation(txId: rawID)
        XCTAssertFalse(marked, "the wiped wallet's migration mark is not recorded")
    }

    /// The same race through the PCZT path: a wipe while a migration PCZT is created drops its mark.
    func testMigrationPCZTCreationDropsItsMarkWhenWipedDuringCreation() async throws {
        let rawID = Data(repeating: 0xFC, count: 32)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.pcztTxidPcztReturnValue = rawID
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []), rustBackend: rustBackend)
        await synchronizer.updateStatus(.stopped)

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plansDatabaseURL = submitPlanDatabaseURL(for: synchronizer)
        rustBackend.createPCZTFromProposalAccountUUIDProposalSizeBoundClosure = { _, _, _ in
            await store.wipe()
            return Pczt([0x01])
        }
        var proposal = Proposal.testOnlyFakeProposal(totalFee: 10)
        proposal.isMigration = true

        _ = try await synchronizer.createPCZTFromProposal(accountUUID: TestsData.mockedAccountUUID, proposal: proposal)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plansDatabaseURL.path),
            "a migration PCZT's mark from before wipe() must not recreate the store file"
        )
        let marked = await store.isMigrationPreparation(txId: rawID)
        XCTAssertFalse(marked, "the wiped wallet's migration mark is not recorded")
    }

    // MARK: - Submission status reported to the host

    func testSubmissionStatusIsAwaitingBeforeTheAppSubmits() async throws {
        let rawID = Data(repeating: 0xAB, count: 32)
        let transactionEncoder = StubTransactionEncoder(createdTransactions: [makeTransaction(raw: Data([0x01]), rawID: rawID)])
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        _ = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        let status = await synchronizer.transactionSubmissionStatus(for: rawID)
        XCTAssertEqual(status, TransactionSubmissionStatus.awaiting)
    }

    func testSubmissionStatusIsAcceptedWithTheServerThatTookTheTransaction() async throws {
        let acceptingService = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: 0, errorMessage: ""))
        defer { try? acceptingService.stop() }
        let synchronizer = try makeSubmittingSynchronizer()
        let transaction = makeCreatedTransaction()

        _ = await synchronizer.broadcaster.submit(transaction: transaction, to: [acceptingService.endpoint])

        let endpoint = try XCTUnwrap(acceptingService.endpoint)
        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.accepted(host: "\(endpoint.host):\(endpoint.port)"))
    }

    func testSubmissionStatusIsSubmittedWhenNoServerAccepted() async throws {
        let rejectingService = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: -25, errorMessage: "rejected"))
        defer { try? rejectingService.stop() }
        let synchronizer = try makeSubmittingSynchronizer()
        let transaction = makeCreatedTransaction()

        _ = await synchronizer.broadcaster.submit(transaction: transaction, to: [rejectingService.endpoint])

        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.submitted)
    }

    func testSubmissionStatusIsNilForATransactionTheStoreNeverSaw() async throws {
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []))

        let status = await synchronizer.transactionSubmissionStatus(for: Data(repeating: 0xFE, count: 32))
        XCTAssertNil(status)
    }

    func testSubmitToRejectingEndpointIsRejected() async throws {
        let rejectingService = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: -25, errorMessage: "rejected"))
        defer { try? rejectingService.stop() }
        let synchronizer = try makeSubmittingSynchronizer()

        let outcome = await synchronizer.broadcaster.submit(
            transaction: makeCreatedTransaction(),
            to: [rejectingService.endpoint]
        )

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.rejected(code: -25, message: "rejected"))
    }

    func testSubmitRejectedTerminallyByEveryEndpointIsRecordedAsRejected() async throws {
        let first = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: -26, errorMessage: "bad-txns-vout-negative"))
        defer { try? first.stop() }
        let second = try HeightReportingLightwalletd(
            sendResponse: makeSendResponse(errorCode: -25, errorMessage: "tx size exceeding the configured mempool maximum")
        )
        defer { try? second.stop() }
        let synchronizer = try makeSubmittingSynchronizer()
        let transaction = makeCreatedTransaction()
        var rejected: [Set<Data>] = []
        synchronizer.rejectedTransactionIdsStream
            .sink { rejected.append($0) }
            .store(in: &cancellables)

        let outcome = await synchronizer.broadcaster.submit(transaction: transaction, to: [first.endpoint, second.endpoint])

        XCTAssertNotNil(outcome.rejection)
        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        guard case .rejected = status else {
            return XCTFail("Expected a rejected status, got \(String(describing: status))")
        }
        XCTAssertEqual(rejected.last, [transaction.txId])
    }

    func testOneExplicitRejectionBesideATransientRefusalStaysPending() async throws {
        let terminal = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: -26, errorMessage: "bad-txns-vout-negative"))
        defer { try? terminal.stop() }
        let transient = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: -25, errorMessage: "Missing inputs"))
        defer { try? transient.stop() }
        let synchronizer = try makeSubmittingSynchronizer()
        let transaction = makeCreatedTransaction()

        let outcome = await synchronizer.broadcaster.submit(transaction: transaction, to: [terminal.endpoint, transient.endpoint])

        XCTAssertNil(outcome.rejection)
        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.submitted, "the transient refusal may clear on a later attempt")
    }

    /// A transport failure may hide an acceptance whose reply was lost: beside a terminal refusal it
    /// keeps the transaction pending, and background resubmission goes on.
    func testAnExplicitRejectionBesideATransportFailureStaysPending() async throws {
        let rejecting = LightWalletEndpoint(address: "rejecting.example.com", port: 443, secure: true)
        let lost = LightWalletEndpoint(address: "lost.example.com", port: 443, secure: true)
        let endpointSubmitter = EndpointSubmitterMock()
        endpointSubmitter.set(behavior: .reject(code: -25, message: "tx size exceeding the configured mempool maximum"), for: rejecting)
        endpointSubmitter.set(behavior: .failTransport, for: lost)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitter
        )
        let transaction = makeCreatedTransaction()
        var rejected: [Set<Data>] = []
        synchronizer.rejectedTransactionIdsStream
            .sink { rejected.append($0) }
            .store(in: &cancellables)

        let outcome = await synchronizer.broadcaster.submit(transaction: transaction, to: [rejecting, lost])

        XCTAssertEqual(outcome, .timedOut, "pending, not failed")
        XCTAssertNil(outcome.rejection, "no terminal rejection the SDK did not record")
        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.submitted, "inconclusive: the transport failure may hide an acceptance")
        let plan = await mockContainer.resolve(SubmitPlanStoring.self).plan(for: transaction.txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([rejecting, lost], acceptedBy: nil), "resubmission keeps retrying it")
        XCTAssertFalse(rejected.contains { $0.contains(transaction.txId) }, "it is never reported rejected")
    }

    // MARK: - The outcome agrees with the stored plan

    private let invalidMessage = "16: bad-txns-sapling-bundle-invalid"

    /// A server accepted the transaction, then refuses it with `-26` on a later submission: the
    /// plan stays accepted and resubmitted, so the outcome reports the acceptance, not a rejection.
    func testAMinus26RefusalAfterAnAcceptanceReportsTheAcceptance() async throws {
        let endpoint = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let endpointSubmitter = EndpointSubmitterMock()
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitter
        )
        let transaction = makeCreatedTransaction()

        let first = await synchronizer.broadcaster.submit(transaction: transaction, to: [endpoint])
        XCTAssertEqual(first, .accepted(by: endpoint))

        endpointSubmitter.set(behavior: .reject(code: -26, message: invalidMessage), for: endpoint)
        let second = await synchronizer.broadcaster.submit(transaction: transaction, to: [endpoint])

        XCTAssertEqual(second, .accepted(by: endpoint))
        XCTAssertNil(second.rejection)
        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.accepted(host: endpointKey(endpoint)))
    }

    /// The same, when the later refusal comes from a server other than the one that accepted it:
    /// the outcome is not a rejection.
    func testAMinus26RefusalElsewhereAfterAnAcceptanceIsNotARejection() async throws {
        let accepting = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let refusing = LightWalletEndpoint(address: "b.example.com", port: 443, secure: true)
        let endpointSubmitter = EndpointSubmitterMock()
        endpointSubmitter.set(behavior: .reject(code: -26, message: invalidMessage), for: refusing)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitter
        )
        let transaction = makeCreatedTransaction()

        _ = await synchronizer.broadcaster.submit(transaction: transaction, to: [accepting])
        let outcome = await synchronizer.broadcaster.submit(transaction: transaction, to: [refusing])

        XCTAssertNil(outcome.rejection)
        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.accepted(host: endpointKey(accepting)))
    }

    /// Background resubmission records an acceptance while the foreground submission is still
    /// waiting on a refusal: the outcome reports the acceptance the store holds.
    func testAnAcceptanceRecordedDuringTheRaceWinsOverItsRefusal() async throws {
        let endpoint = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let endpointSubmitter = EndpointSubmitterMock()
        let gate = Gate()
        endpointSubmitter.set(behavior: .gated(gate, then: .reject(code: -26, message: invalidMessage)), for: endpoint)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitter
        )
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let transaction = makeCreatedTransaction()

        let submission = Task {
            await synchronizer.broadcaster.submit(transaction: transaction, to: [endpoint])
        }
        await endpointSubmitter.awaitSubmissionStarted(to: endpoint)
        await store.markAccepted(txId: transaction.txId, host: endpointKey(endpoint), lifecycle: await store.currentLifecycle())
        gate.open()
        let outcome = await submission.value

        XCTAssertEqual(outcome, .accepted(by: endpoint))
        let plan = await store.plan(for: transaction.txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([endpoint], acceptedBy: endpointKey(endpoint)))
    }

    // MARK: - Deadline: an endpoint still in flight keeps the transaction pending

    private let tooLargeMessage = "tx size exceeding the configured mempool maximum"
    private let deadline = SubmissionTiming(responseTimeout: 0.3, postAcceptanceGraceDelay: 0.1)

    /// A terminal refusal from one endpoint while another is still in flight at the deadline is not
    /// a verdict: the transaction stays pending, and when the other endpoint accepts it afterwards
    /// (work that ignores cancellation, as on Tor) the acceptance is recorded and resubmission goes on.
    func testARejectionThenALateAcceptanceAfterTheDeadlineEndsAccepted() async throws {
        let rejecting = LightWalletEndpoint(address: "rejecting.example.com", port: 443, secure: true)
        let late = LightWalletEndpoint(address: "late.example.com", port: 443, secure: true)
        let endpointSubmitter = EndpointSubmitterMock()
        let gate = Gate()
        endpointSubmitter.set(behavior: .reject(code: -25, message: tooLargeMessage), for: rejecting)
        endpointSubmitter.set(behavior: .gated(gate, then: .succeed), for: late)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitter
        )
        let transaction = makeCreatedTransaction()
        var rejected: [Set<Data>] = []
        synchronizer.rejectedTransactionIdsStream
            .sink { rejected.append($0) }
            .store(in: &cancellables)

        let outcome = await synchronizer.broadcaster.submit(transaction: transaction, to: [rejecting, late], timing: deadline)

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertNil(outcome.rejection)
        let atDeadline = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(atDeadline, TransactionSubmissionStatus.submitted, "an endpoint in flight keeps it pending")

        gate.open()
        await settledSubmissions(of: synchronizer)

        let settled = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(settled, TransactionSubmissionStatus.accepted(host: endpointKey(late)))
        let plan = await mockContainer.resolve(SubmitPlanStoring.self).plan(for: transaction.txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([rejecting, late], acceptedBy: endpointKey(late)), "resubmission keeps retrying it")
        XCTAssertFalse(rejected.contains { $0.contains(transaction.txId) }, "it is never reported rejected")
    }

    /// An endpoint that never answers (its submission ends by cancellation) leaves the transaction
    /// pending, beside a terminal refusal.
    func testATimeoutWithAnEndpointThatNeverAnswersStaysPending() async throws {
        let rejecting = LightWalletEndpoint(address: "rejecting.example.com", port: 443, secure: true)
        let silent = LightWalletEndpoint(address: "silent.example.com", port: 443, secure: true)
        let endpointSubmitter = EndpointSubmitterMock()
        endpointSubmitter.set(behavior: .reject(code: -25, message: tooLargeMessage), for: rejecting)
        endpointSubmitter.set(behavior: .hang, for: silent)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitter
        )
        let transaction = makeCreatedTransaction()

        let outcome = await synchronizer.broadcaster.submit(transaction: transaction, to: [rejecting, silent], timing: deadline)
        await settledSubmissions(of: synchronizer)

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(endpointSubmitter.recordedCancellations(), [silent])
        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.submitted, "an endpoint that never answered may still hold it")
    }

    /// Answers that arrive after the deadline complete the verdict: once every endpoint has answered,
    /// none accepted and every refusal was for good, the transaction is rejected.
    func testLateAnswersAfterTheDeadlineCompleteARejection() async throws {
        let rejecting = LightWalletEndpoint(address: "rejecting.example.com", port: 443, secure: true)
        let late = LightWalletEndpoint(address: "late.example.com", port: 443, secure: true)
        let endpointSubmitter = EndpointSubmitterMock()
        let gate = Gate()
        endpointSubmitter.set(behavior: .reject(code: -25, message: tooLargeMessage), for: rejecting)
        endpointSubmitter.set(behavior: .gated(gate, then: .reject(code: -26, message: "bad-txns-vout-negative")), for: late)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitter
        )
        let transaction = makeCreatedTransaction()

        let outcome = await synchronizer.broadcaster.submit(transaction: transaction, to: [rejecting, late], timing: deadline)
        XCTAssertEqual(outcome, .timedOut)

        gate.open()
        await settledSubmissions(of: synchronizer)

        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.rejected(.tooLarge))
    }

    // MARK: - The outcome carries the recorded terminal refusal

    /// One endpoint refuses for good (the size limit), another in a way that may be transient (a
    /// mempool chain limit), in either order: the transaction is not rejected, the outcome carries
    /// no terminal refusal, and background resubmission keeps it.
    func testATerminalRefusalBesideATransientOneInEitherOrderStaysPending() async throws {
        for terminalFirst in [true, false] {
            let terminal = LightWalletEndpoint(address: "terminal.example.com", port: 443, secure: true)
            let transient = LightWalletEndpoint(address: "transient.example.com", port: 443, secure: true)
            let endpointSubmitter = EndpointSubmitterMock()
            endpointSubmitter.set(
                behavior: .rejectAfter(terminalFirst ? 0 : 0.2, code: -25, message: tooLargeMessage),
                for: terminal
            )
            endpointSubmitter.set(
                behavior: .rejectAfter(terminalFirst ? 0.2 : 0, code: -26, message: "too-long-mempool-chain"),
                for: transient
            )
            let synchronizer = try makeSynchronizer(
                transactionEncoder: StubTransactionEncoder(createdTransactions: []),
                endpointSubmitter: endpointSubmitter
            )
            let transaction = makeCreatedTransaction(seed: terminalFirst ? 0x51 : 0x52)

            let outcome = await synchronizer.broadcaster.submit(
                transaction: transaction,
                to: [transient, terminal],
                timing: SubmissionTiming(responseTimeout: 5, postAcceptanceGraceDelay: 0.1)
            )
            await settledSubmissions(of: synchronizer)

            XCTAssertNil(outcome.rejection, "terminal first: \(terminalFirst)")
            let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
            XCTAssertEqual(status, TransactionSubmissionStatus.submitted, "terminal first: \(terminalFirst)")
        }
    }

    /// Both endpoints refuse for good, in either order: the transaction is rejected, and the outcome
    /// carries the terminal refusal the SDK recorded.
    func testTerminalRefusalsFromEveryEndpointInEitherOrderAreRejected() async throws {
        for tooLargeFirst in [true, false] {
            let tooLarge = LightWalletEndpoint(address: "toolarge.example.com", port: 443, secure: true)
            let invalid = LightWalletEndpoint(address: "invalid.example.com", port: 443, secure: true)
            let endpointSubmitter = EndpointSubmitterMock()
            endpointSubmitter.set(
                behavior: .rejectAfter(tooLargeFirst ? 0 : 0.2, code: -25, message: tooLargeMessage),
                for: tooLarge
            )
            endpointSubmitter.set(
                behavior: .rejectAfter(tooLargeFirst ? 0.2 : 0, code: -26, message: "bad-txns-vout-negative"),
                for: invalid
            )
            let synchronizer = try makeSynchronizer(
                transactionEncoder: StubTransactionEncoder(createdTransactions: []),
                endpointSubmitter: endpointSubmitter
            )
            let transaction = makeCreatedTransaction(seed: tooLargeFirst ? 0x53 : 0x54)

            let outcome = await synchronizer.broadcaster.submit(
                transaction: transaction,
                to: [tooLarge, invalid],
                timing: SubmissionTiming(responseTimeout: 5, postAcceptanceGraceDelay: 0.1)
            )

            XCTAssertEqual(outcome, .rejected(code: -25, message: tooLargeMessage), "too large first: \(tooLargeFirst)")
            XCTAssertEqual(outcome.rejection, .tooLarge, "too large first: \(tooLargeFirst)")
            let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
            XCTAssertEqual(status, TransactionSubmissionStatus.rejected(.tooLarge), "too large first: \(tooLargeFirst)")
        }
    }

    /// Only transient refusals: the outcome reports no terminal rejection and the transaction stays
    /// pending, resubmitted as before.
    func testOnlyTransientRefusalsReportNoRejectionAndStayPending() async throws {
        let first = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let second = LightWalletEndpoint(address: "b.example.com", port: 443, secure: true)
        let endpointSubmitter = EndpointSubmitterMock()
        endpointSubmitter.set(behavior: .reject(code: -25, message: "Missing inputs"), for: first)
        endpointSubmitter.set(behavior: .rejectAfter(0.1, code: -26, message: "mempool full"), for: second)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitter
        )
        let transaction = makeCreatedTransaction()

        let outcome = await synchronizer.broadcaster.submit(transaction: transaction, to: [first, second])

        guard case .rejected = outcome else {
            return XCTFail("Expected rejected, got \(outcome)")
        }
        XCTAssertNil(outcome.rejection)
        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.submitted)
    }

    /// A migration preparation keeps main's behaviour whatever its endpoints answer, and whenever:
    /// the outcome reports the first refusal, and the transaction is never recorded as rejected.
    func testAMigrationPreparationIsUnchangedByMixedOrLateRefusals() async throws {
        let terminal = LightWalletEndpoint(address: "terminal.example.com", port: 443, secure: true)
        let transient = LightWalletEndpoint(address: "transient.example.com", port: 443, secure: true)
        let endpointSubmitter = EndpointSubmitterMock()
        let gate = Gate()
        endpointSubmitter.set(behavior: .reject(code: -25, message: "Missing inputs"), for: transient)
        endpointSubmitter.set(behavior: .gated(gate, then: .reject(code: -25, message: tooLargeMessage)), for: terminal)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitter
        )
        let store = mockContainer.resolve(SubmitPlanStoring.self)

        let mixed = makeCreatedTransaction(seed: 0x61)
        await store.markMigrationPreparation(txId: mixed.txId, lifecycle: await store.currentLifecycle())
        let mixedTask = Task {
            await synchronizer.broadcaster.submit(transaction: mixed, to: [transient, terminal])
        }
        await endpointSubmitter.awaitSubmissionStarted(to: terminal)
        try await Task.sleep(nanoseconds: 100_000_000)
        gate.open()
        let mixedOutcome = await mixedTask.value
        XCTAssertEqual(mixedOutcome, .rejected(code: -25, message: "Missing inputs"), "the first refusal, as on main")
        let mixedStatus = await synchronizer.transactionSubmissionStatus(for: mixed.txId)
        XCTAssertEqual(mixedStatus, TransactionSubmissionStatus.submitted)

        gate.close()
        let timedOut = makeCreatedTransaction(seed: 0x62)
        await store.markMigrationPreparation(txId: timedOut.txId, lifecycle: await store.currentLifecycle())
        let timedOutOutcome = await synchronizer.broadcaster.submit(transaction: timedOut, to: [transient, terminal], timing: deadline)
        XCTAssertEqual(timedOutOutcome, .timedOut)
        gate.open()
        await settledSubmissions(of: synchronizer)
        let timedOutStatus = await synchronizer.transactionSubmissionStatus(for: timedOut.txId)
        XCTAssertEqual(timedOutStatus, TransactionSubmissionStatus.submitted, "resubmission keeps retrying it until it expires")
    }

    private func settledSubmissions(of synchronizer: SDKSynchronizer) async {
        guard let broadcaster = synchronizer.broadcaster as? SDKBroadcaster else {
            return XCTFail("Expected the SDK's broadcaster")
        }
        await broadcaster.waitForSettledSubmissions()
    }

    func testOnlyTransientRefusalsStaySubmitted() async throws {
        let transient = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: -25, errorMessage: "Missing inputs"))
        defer { try? transient.stop() }
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []))
        let transaction = makeCreatedTransaction()

        _ = await synchronizer.broadcaster.submit(transaction: transaction, to: [transient.endpoint])

        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.submitted)
    }

    func testARejectionBesideAnAcceptanceIsNotRejected() async throws {
        let rejecting = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: -26, errorMessage: "bad-txns-vout-negative"))
        defer { try? rejecting.stop() }
        let accepting = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: 0, errorMessage: ""))
        defer { try? accepting.stop() }
        let synchronizer = try makeSubmittingSynchronizer()
        let transaction = makeCreatedTransaction()

        _ = await synchronizer.broadcaster.submit(
            transaction: transaction,
            to: [rejecting.endpoint, accepting.endpoint],
            timing: SubmissionTiming(responseTimeout: 5, postAcceptanceGraceDelay: 0.2)
        )

        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.accepted(host: endpointKey(accepting.endpoint)))
    }

    func testLegacySubmitWithoutAPlanRecordsNoRejection() async throws {
        let rawID = Data(repeating: 0xE1, count: 32)
        let transactionEncoder = StubTransactionEncoder(createdTransactions: [makeTransaction(raw: Data([0x01]), rawID: rawID)])
        transactionEncoder.submitError = TransactionEncoderError.submitError(code: -26, message: "bad-txns-vout-negative")
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let stream = try await synchronizer.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )
        var results: [TransactionSubmitResult] = []
        for try await result in stream { results.append(result) }

        XCTAssertEqual(results.map(\.rejection), [.invalid], "the refusal is still classified for the caller")
        let plan = await mockContainer.resolve(SubmitPlanStoring.self).plan(for: rawID)
        XCTAssertNil(plan, "one endpoint's refusal without a plan is not a unanimous verdict")
    }

    func testLegacySubmitRecordsNothingForATransientRefusal() async throws {
        let rawID = Data(repeating: 0xE2, count: 32)
        let transactionEncoder = StubTransactionEncoder(createdTransactions: [makeTransaction(raw: Data([0x01]), rawID: rawID)])
        transactionEncoder.submitError = TransactionEncoderError.submitError(code: -25, message: "Missing inputs")
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let stream = try await synchronizer.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )
        for try await _ in stream {}

        let plan = await mockContainer.resolve(SubmitPlanStoring.self).plan(for: rawID)
        XCTAssertNil(plan, "A refusal that may be transient leaves the transaction to resubmission")
    }

    func testCreateProposedTransactionsPassesTheSizeBoundToTheEncoder() async throws {
        let rawID = Data(repeating: 0xE3, count: 32)
        let transactionEncoder = StubTransactionEncoder(createdTransactions: [makeTransaction(raw: Data([0x01]), rawID: rawID)])
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)
        let bound = TransactionSizeBound(maxShieldedActions: 75)

        _ = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey,
            ovkPolicy: .sender,
            sizeBound: bound
        )
        XCTAssertEqual(transactionEncoder.receivedSizeBound, bound)

        let stream = try await synchronizer.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )
        for try await _ in stream {}
        XCTAssertEqual(transactionEncoder.receivedSizeBound, .consensus, "The unbounded overload stays consensus only")
    }

    /// The wallet app's send path: create through the broadcaster (an awaiting plan), then submit
    /// each transaction to the chosen endpoints. A unanimous terminal refusal is recorded.
    func testCreateThenSubmitThroughTheBroadcasterRecordsAUnanimousRejection() async throws {
        let rawID = Data(repeating: 0xE4, count: 32)
        let rawTransaction = Data([0x01, 0x02])
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: [makeTransaction(raw: rawTransaction, rawID: rawID)]),
            rustBackend: ZcashRustBackendWeldingMock()
        )
        await synchronizer.updateStatus(.stopped)
        let first = try HeightReportingLightwalletd(
            sendResponse: makeSendResponse(errorCode: -25, errorMessage: "exceeding the next block's ZIP 218 limit")
        )
        defer { try? first.stop() }
        let second = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: -26, errorMessage: "bad-txns-vout-negative"))
        defer { try? second.stop() }

        let transactions = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )
        let awaiting = await synchronizer.transactionSubmissionStatus(for: rawID)
        XCTAssertEqual(awaiting, TransactionSubmissionStatus.awaiting)

        let reports = await synchronizer.broadcaster.submit(transactions: transactions, to: [first.endpoint, second.endpoint])

        XCTAssertNotNil(reports.first?.outcome.rejection)
        let status = await synchronizer.transactionSubmissionStatus(for: rawID)
        guard case .rejected = status else {
            return XCTFail("Expected a rejected status, got \(String(describing: status))")
        }
    }

    func testAMigrationPreparationRejectedByEveryEndpointStaysSubmitted() async throws {
        let rejecting = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: -26, errorMessage: "bad-txns-vout-negative"))
        defer { try? rejecting.stop() }
        let synchronizer = try makeSubmittingSynchronizer()
        let transaction = makeCreatedTransaction()
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        await store.markMigrationPreparation(txId: transaction.txId, lifecycle: await store.currentLifecycle())

        let outcome = await synchronizer.broadcaster.submit(transaction: transaction, to: [rejecting.endpoint])

        XCTAssertEqual(outcome.rejection, .invalid, "the result is still classified")
        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.submitted, "resubmission keeps retrying it, as on main")
    }

    func testALaterAcceptanceClearsARejection() async throws {
        let rejecting = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: -26, errorMessage: "bad-txns-vout-negative"))
        defer { try? rejecting.stop() }
        let accepting = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: 0, errorMessage: ""))
        defer { try? accepting.stop() }
        let synchronizer = try makeSubmittingSynchronizer()
        let transaction = makeCreatedTransaction()

        _ = await synchronizer.broadcaster.submit(transaction: transaction, to: [rejecting.endpoint])
        let rejected = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(rejected, TransactionSubmissionStatus.rejected(.invalid))

        _ = await synchronizer.broadcaster.submit(transaction: transaction, to: [accepting.endpoint])
        let accepted = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(accepted, TransactionSubmissionStatus.accepted(host: endpointKey(accepting.endpoint)))
    }

    func testSubmitFirstAcceptanceWinsAcrossEndpoints() async throws {
        let acceptingService = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: 0, errorMessage: ""))
        defer { try? acceptingService.stop() }
        let rejectingService = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: -25, errorMessage: "rejected"))
        defer { try? rejectingService.stop() }
        let synchronizer = try makeSubmittingSynchronizer()
        let transaction = makeCreatedTransaction()

        let outcome = await synchronizer.broadcaster.submit(
            transaction: transaction,
            to: [rejectingService.endpoint, acceptingService.endpoint],
            timing: SubmissionTiming(responseTimeout: 5, postAcceptanceGraceDelay: 0.2)
        )

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.accepted(by: acceptingService.endpoint))

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: transaction.txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready(
            [rejectingService.endpoint, acceptingService.endpoint],
            acceptedBy: "\(acceptingService.endpoint.host):\(acceptingService.endpoint.port)"
        ))
    }

    func testEmptySubmissionDoesNotAttributeEarlierTraffic() async throws {
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []))
        let route = OHTTPHealthRoute(network: .testnet, gatewayHost: "\(UUID().uuidString).test", relayURL: "https://relay.test/", viaTor: false)
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let attempt = OHTTPHealthAttempt(operation: operation)
        let result = await OHTTPHealthContext.withOperation(operation) {
            await OHTTPHealthContext.withAttempt(attempt) {
                OHTTPHealthCenter.shared.begin(route: route, scope: .lightwalletd).record(outcome: .transportUnavailable, stage: .connection)
                return await synchronizer.broadcaster.submit(transaction: self.makeCreatedTransaction(), to: [])
            }
        }
        XCTAssertEqual(result, .unreachable)
        let updates = session.updates()
        await OHTTPHealthContext.complete(operation, failed: true, failedAttempt: attempt)
        for await update in updates {
            if case .operationCompleted(_, _, let observations) = update {
                XCTAssertTrue(observations.isEmpty)
                break
            }
        }
    }

    func testSubmitWithEmptyEndpointsIsUnreachableAndRecordsNoPlan() async throws {
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []))
        let transaction = makeCreatedTransaction()

        let outcome = await synchronizer.broadcaster.submit(transaction: transaction, to: [])

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.unreachable)
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: transaction.txId)
        XCTAssertNil(plan)
    }

    // MARK: - Submit (batch)

    func testBatchSubmitStopsAfterFirstFailureAndMarksRestNotAttempted() async throws {
        let rejectingService = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: -25, errorMessage: "rejected"))
        defer { try? rejectingService.stop() }
        let synchronizer = try makeSubmittingSynchronizer()
        let first = makeCreatedTransaction(seed: 0x01)
        let second = makeCreatedTransaction(seed: 0x02)

        let reports = await synchronizer.broadcaster.submit(
            transactions: [first, second],
            to: [rejectingService.endpoint]
        )

        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[0].txId, first.txId)
        XCTAssertEqual(reports[0].outcome, TransactionSubmissionOutcome.rejected(code: -25, message: "rejected"))
        XCTAssertEqual(reports[1].txId, second.txId)
        XCTAssertEqual(reports[1].outcome, TransactionSubmissionOutcome.notAttempted)

        // The second transaction was never released — its plan must not exist.
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let secondPlan = await store.plan(for: second.txId)
        XCTAssertNil(secondPlan)
    }

    func testBatchSubmitAllAccepted() async throws {
        let acceptingService = try HeightReportingLightwalletd(sendResponse: makeSendResponse(errorCode: 0, errorMessage: ""))
        defer { try? acceptingService.stop() }
        let synchronizer = try makeSubmittingSynchronizer()
        let first = makeCreatedTransaction(seed: 0x03)
        let second = makeCreatedTransaction(seed: 0x04)

        let reports = await synchronizer.broadcaster.submit(
            transactions: [first, second],
            to: [acceptingService.endpoint]
        )

        XCTAssertEqual(reports.map(\.outcome), [
            TransactionSubmissionOutcome.accepted(by: acceptingService.endpoint),
            TransactionSubmissionOutcome.accepted(by: acceptingService.endpoint)
        ])
        XCTAssertEqual(acceptingService.recordedTransactions(), [first.raw, second.raw])
    }

    // MARK: - Legacy Synchronizer APIs (behavior unchanged, no plan rows)

    func testLegacyCreateProposedTransactionsSubmitsOnceAndRecordsNoPlan() async throws {
        let rawID = Data(repeating: 0xAB, count: 32)
        let rawTransaction = Data([0x01, 0x02, 0x03, 0x04])
        let overviews = [makeTransaction(raw: rawTransaction, rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let stream = try await synchronizer.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )
        var iterator = stream.makeAsyncIterator()

        let maybeSubmitResult = try await iterator.next()
        let submitResult = try XCTUnwrap(maybeSubmitResult)
        XCTAssertEqual(submitResult, TransactionSubmitResult.success(txId: rawID))
        let nextSubmitResult = try await iterator.next()
        XCTAssertNil(nextSubmitResult)
        XCTAssertEqual(
            transactionEncoder.submittedTransactions,
            [EncodedTransaction(transactionId: rawID, raw: rawTransaction)]
        )

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: rawID)
        XCTAssertNil(plan, "Legacy path must not register submit plans")
    }

    func testLegacyCreateTransactionFromPCZTSubmitsOnceAndRecordsNoPlan() async throws {
        let rawID = Data(repeating: 0xCD, count: 32)
        let rawTransaction = Data([0x05, 0x06, 0x07, 0x08])
        let overviews = [makeTransaction(raw: rawTransaction, rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.extractAndStoreTxFromPCZTPcztWithProofsPcztWithSigsReturnValue = rawID
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder, rustBackend: rustBackend)
        await synchronizer.updateStatus(.stopped)

        let stream = try await synchronizer.createTransactionFromPCZT(
            pcztWithProofs: Pczt([0x10, 0x11]),
            pcztWithSigs: Pczt([0x12, 0x13])
        )
        var iterator = stream.makeAsyncIterator()

        let maybeSubmitResult = try await iterator.next()
        let submitResult = try XCTUnwrap(maybeSubmitResult)
        XCTAssertEqual(submitResult, TransactionSubmitResult.success(txId: rawID))

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: rawID)
        XCTAssertNil(plan, "Legacy path must not register submit plans")
    }

    // MARK: - Refusal classes

    /// An endpoint that refuses the transaction because it already holds it has accepted it: a
    /// terminal refusal from another endpoint does not reject it, and it is recorded as accepted.
    func testARefusalSayingTheServerHoldsTheTransactionIsItsAcceptance() async throws {
        let holding = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let refusing = LightWalletEndpoint(address: "b.example.com", port: 443, secure: true)
        let endpointSubmitter = EndpointSubmitterMock()
        endpointSubmitter.set(behavior: .reject(code: -26, message: "18: txn-already-in-mempool"), for: holding)
        endpointSubmitter.set(behavior: .reject(code: -26, message: "16: bad-txns-sapling-bundle-invalid"), for: refusing)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitter
        )
        let transaction = makeCreatedTransaction()

        let outcome = await synchronizer.broadcaster.submit(transaction: transaction, to: [refusing, holding])

        XCTAssertEqual(outcome, .accepted(by: holding))
        XCTAssertNil(outcome.rejection)
        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.accepted(host: endpointKey(holding)))
    }

    /// The reproduced refusal: a server that has not reached the wallet's Orchard or Sapling anchor
    /// refuses the transaction, and may accept it once it catches up. It is never rejected, and
    /// resubmission keeps retrying it.
    func testAnUnknownAnchorRefusalKeepsTheTransactionPending() async throws {
        let endpoint = LightWalletEndpoint(address: "custom.example.com", port: 443, secure: true)
        let endpointSubmitter = EndpointSubmitterMock()
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitter
        )
        for (seed, message) in [(UInt8(0xA1), "16: bad-txns-orchard-unknown-anchor"), (UInt8(0xA2), "16: bad-txns-sapling-unknown-anchor")] {
            endpointSubmitter.set(behavior: .reject(code: -26, message: message), for: endpoint)
            let transaction = makeCreatedTransaction(seed: seed)

            let outcome = await synchronizer.broadcaster.submit(transaction: transaction, to: [endpoint])

            XCTAssertEqual(outcome, .rejected(code: -26, message: message), "the refusal is still reported")
            XCTAssertNil(outcome.rejection, message)
            let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
            XCTAssertEqual(status, TransactionSubmissionStatus.submitted, "resubmission keeps retrying it: \(message)")
        }
    }

    // MARK: - Migration sweeps are never rejected

    /// An immediate migration sweep created through the broadcaster from a migration proposal
    /// keeps main's resubmission until expiry: a unanimous terminal refusal does not reject it.
    func testAMigrationSweepCreatedThroughTheBroadcasterIsNeverRejected() async throws {
        let rawID = Data(repeating: 0xE7, count: 32)
        let endpoint = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let endpointSubmitter = EndpointSubmitterMock()
        endpointSubmitter.set(behavior: .reject(code: -26, message: "bad-txns-vout-negative"), for: endpoint)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: [makeTransaction(raw: Data([0x01]), rawID: rawID)]),
            endpointSubmitter: endpointSubmitter
        )
        await synchronizer.updateStatus(.stopped)
        var sweep = Proposal.testOnlyFakeProposal(totalFee: 10)
        sweep.isMigration = true

        let transactions = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: sweep,
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )
        let outcome = await synchronizer.broadcaster.submit(transaction: try XCTUnwrap(transactions.first), to: [endpoint])

        XCTAssertEqual(outcome.rejection, .invalid, "the result is still classified, as on main")
        let status = await synchronizer.transactionSubmissionStatus(for: rawID)
        XCTAssertEqual(status, TransactionSubmissionStatus.submitted, "resubmission keeps retrying it until it expires")
    }

    /// End to end, through a restart: a migration proposal's PCZT is created, moved to a signer and
    /// back (serialized and parsed again), proved, and only then built and submitted, by a new
    /// process with a new submit-plan store over the same file. Every server refuses it for good,
    /// and it is still never recorded as rejected, before or after another restart.
    func testAMigrationPCZTSurvivesReparseAndRestartAndIsNeverRejected() async throws {
        let rawID = Data(repeating: 0xE8, count: 32)
        let created = Pczt([0x50, 0x43, 0x5A, 0x54, 0x01])
        let proved = Pczt([0x50, 0x43, 0x5A, 0x54, 0x02])
        let endpoint = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let endpointSubmitter = EndpointSubmitterMock()
        endpointSubmitter.set(behavior: .reject(code: -25, message: "exceeding the configured mempool maximum"), for: endpoint)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.createPCZTFromProposalAccountUUIDProposalSizeBoundReturnValue = created
        // The id a PCZT commits to is the same before and after proving.
        rustBackend.pcztTxidPcztClosure = { pczt in [created, proved].contains(pczt) ? rawID : nil }
        rustBackend.extractAndStoreTxFromPCZTPcztWithProofsPcztWithSigsReturnValue = rawID
        let encoder = StubTransactionEncoder(createdTransactions: [makeTransaction(raw: Data([0x01]), rawID: rawID)])

        // Process 1: propose and create the PCZT, then hand it off.
        let first = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend, endpointSubmitter: endpointSubmitter)
        await first.updateStatus(.stopped)
        var sweep = Proposal.testOnlyFakeProposal(totalFee: 10)
        sweep.isMigration = true
        let pczt = try await first.createPCZTFromProposal(accountUUID: TestsData.mockedAccountUUID, proposal: sweep)
        let transported = Pczt(Array(pczt))
        XCTAssertEqual(rustBackend.pcztTxidPcztReceivedPczt, created)
        let databaseURL = submitPlanDatabaseURL(for: first)

        // Process 2: a restart, with a fresh store over the same file. Build and submit the proved PCZT.
        mockContainer.mock(type: SubmitPlanStoring.self, isSingleton: true) { _ in
            SubmitPlanStore(databaseURL: databaseURL, logger: submissionLifecycleLogger())
        }
        let second = try makeSynchronizer(transactionEncoder: encoder, rustBackend: rustBackend, endpointSubmitter: endpointSubmitter)
        await second.updateStatus(.stopped)
        XCTAssertEqual(transported, created)
        let transactions = try await second.broadcaster.createTransactionFromPCZT(pcztWithProofs: proved, pcztWithSigs: proved)
        let outcome = await second.broadcaster.submit(transaction: try XCTUnwrap(transactions.first), to: [endpoint])

        XCTAssertEqual(outcome.rejection, .tooLarge, "the result is still classified, as on main")
        let status = await second.transactionSubmissionStatus(for: rawID)
        XCTAssertEqual(status, TransactionSubmissionStatus.submitted, "never rejected: resubmitted until it expires")

        // Process 3: another restart still holds the mark and the plan.
        let reopened = SubmitPlanStore(databaseURL: databaseURL, logger: submissionLifecycleLogger())
        let marked = await reopened.isMigrationPreparation(txId: rawID)
        XCTAssertTrue(marked)
        await reopened.markRejected(txId: rawID, code: -25, reason: "exceeding the configured mempool maximum", lifecycle: await reopened.currentLifecycle())
        let plan = await reopened.plan(for: rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([endpoint], acceptedBy: nil))
    }

    /// An ordinary proposal's PCZT is not marked: its submission can be rejected.
    func testAnOrdinaryPCZTIsNotMarkedAsAMigration() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.createPCZTFromProposalAccountUUIDProposalSizeBoundReturnValue = Pczt([0x01])
        rustBackend.pcztTxidPcztReturnValue = Data(repeating: 0xE9, count: 32)
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []), rustBackend: rustBackend)
        await synchronizer.updateStatus(.stopped)

        _ = try await synchronizer.createPCZTFromProposal(
            accountUUID: TestsData.mockedAccountUUID,
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10)
        )

        XCTAssertFalse(rustBackend.pcztTxidPcztCalled)
        let marked = await mockContainer.resolve(SubmitPlanStoring.self).isMigrationPreparation(txId: Data(repeating: 0xE9, count: 32))
        XCTAssertFalse(marked)
    }

    // MARK: - Unaccepted transactions after the user moves to another server

    /// A transaction stuck because its recorded server cannot be reached goes out once through the server the
    /// user moved to. Its plan keeps the recorded server first and gains the new one last, and the acceptance is
    /// recorded, so background resubmission prefers the recorded server again once it is back.
    func testResubmitUnacceptedSendsAStuckTransactionThroughTheNewServer() async throws {
        let gateway = LightWalletEndpoint(address: "gateway.example.com", port: 443, secure: true)
        let publicServer = LightWalletEndpoint(address: "public.example.com", port: 443, secure: true)
        let endpointSubmitterMock = EndpointSubmitterMock()
        endpointSubmitterMock.set(behavior: .succeed, for: publicServer)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let stuck = makeTransaction(raw: Data([0x01, 0x02]), rawID: Data(repeating: 0x11, count: 32))
        try reportPending([stuck])
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        await store.recordPlan(txId: stuck.rawID, endpoints: [gateway])

        let reports = await synchronizer.broadcaster.resubmitUnacceptedTransactions(through: publicServer)

        XCTAssertEqual(reports, [TransactionSubmissionReport(txId: stuck.rawID, outcome: .accepted(by: publicServer))])
        XCTAssertEqual(endpointSubmitterMock.recordedSubmissions(), [publicServer], "Sent once, through the new server only")
        let plan = await store.plan(for: stuck.rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([gateway, publicServer], acceptedBy: "public.example.com:443"))
    }

    /// Only stuck transactions follow the user to the new server: one a server already accepted, one the host
    /// created but never released, and one without a plan are neither sent nor changed.
    func testResubmitUnacceptedLeavesAcceptedAwaitingAndUnplannedTransactionsAlone() async throws {
        let gateway = LightWalletEndpoint(address: "gateway.example.com", port: 443, secure: true)
        let publicServer = LightWalletEndpoint(address: "public.example.com", port: 443, secure: true)
        let endpointSubmitterMock = EndpointSubmitterMock()
        endpointSubmitterMock.set(behavior: .succeed, for: publicServer)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let accepted = makeTransaction(raw: Data([0x01]), rawID: Data(repeating: 0x21, count: 32))
        let awaiting = makeTransaction(raw: Data([0x02]), rawID: Data(repeating: 0x22, count: 32))
        let unplanned = makeTransaction(raw: Data([0x03]), rawID: Data(repeating: 0x23, count: 32))
        try reportPending([accepted, awaiting, unplanned])
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let lifecycle = await store.recordPlan(txId: accepted.rawID, endpoints: [gateway])
        await store.markAccepted(txId: accepted.rawID, host: "gateway.example.com:443", lifecycle: lifecycle)
        await store.markAwaitingSubmission(txIds: [awaiting.rawID], lifecycle: await store.currentLifecycle())

        let reports = await synchronizer.broadcaster.resubmitUnacceptedTransactions(through: publicServer)

        XCTAssertEqual(reports, [])
        XCTAssertTrue(endpointSubmitterMock.recordedSubmissions().isEmpty)
        let acceptedPlan = await store.plan(for: accepted.rawID)
        XCTAssertEqual(acceptedPlan, StoredSubmitPlan.ready([gateway], acceptedBy: "gateway.example.com:443"))
        let awaitingPlan = await store.plan(for: awaiting.rawID)
        XCTAssertEqual(awaitingPlan, StoredSubmitPlan.awaiting)
        let unplannedPlan = await store.plan(for: unplanned.rawID)
        XCTAssertNil(unplannedPlan)
    }

    /// A transaction the new server does not take does not keep the next one from being sent, and both keep
    /// the new server in their plans for background resubmission.
    func testResubmitUnacceptedSendsEveryStuckTransactionWhenOneIsNotAccepted() async throws {
        let gateway = LightWalletEndpoint(address: "gateway.example.com", port: 443, secure: true)
        let publicServer = LightWalletEndpoint(address: "public.example.com", port: 443, secure: true)
        let endpointSubmitterMock = EndpointSubmitterMock()
        endpointSubmitterMock.set(behavior: .reject(code: -26, message: "rejected"), for: publicServer)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let first = makeTransaction(raw: Data([0x04]), rawID: Data(repeating: 0x41, count: 32))
        let second = makeTransaction(raw: Data([0x05]), rawID: Data(repeating: 0x42, count: 32))
        try reportPending([first, second])
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        await store.recordPlan(txId: first.rawID, endpoints: [gateway])
        await store.recordPlan(txId: second.rawID, endpoints: [gateway])

        let reports = await synchronizer.broadcaster.resubmitUnacceptedTransactions(through: publicServer)

        XCTAssertEqual(reports.map(\.txId), [first.rawID, second.rawID])
        XCTAssertEqual(endpointSubmitterMock.recordedSubmissions(), [publicServer, publicServer])
        for transaction in [first, second] {
            let plan = await store.plan(for: transaction.rawID)
            XCTAssertEqual(plan, StoredSubmitPlan.ready([gateway, publicServer], acceptedBy: nil))
        }
    }

    /// With nothing stuck there is nothing to send: no network attempt, and an empty report.
    func testResubmitUnacceptedWithNothingStuckMakesNoNetworkAttempt() async throws {
        let publicServer = LightWalletEndpoint(address: "public.example.com", port: 443, secure: true)
        let endpointSubmitterMock = EndpointSubmitterMock()
        endpointSubmitterMock.set(behavior: .succeed, for: publicServer)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        try reportPending([])

        let reports = await synchronizer.broadcaster.resubmitUnacceptedTransactions(through: publicServer)

        XCTAssertEqual(reports, [])
        XCTAssertTrue(endpointSubmitterMock.recordedSubmissions().isEmpty)
    }

    /// A transaction recorded as rejected is never sent again, through the new server or otherwise, and its plan
    /// does not change.
    func testResubmitUnacceptedNeverResendsARejectedTransaction() async throws {
        let gateway = LightWalletEndpoint(address: "gateway.example.com", port: 443, secure: true)
        let publicServer = LightWalletEndpoint(address: "public.example.com", port: 443, secure: true)
        let endpointSubmitterMock = EndpointSubmitterMock()
        endpointSubmitterMock.set(behavior: .succeed, for: publicServer)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let rejected = makeTransaction(raw: Data([0x06]), rawID: Data(repeating: 0x51, count: 32))
        try reportPending([rejected])
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let lifecycle = await store.recordPlan(txId: rejected.rawID, endpoints: [gateway])
        await store.markRejected(txId: rejected.rawID, code: -26, reason: "bad-txns-vout-negative", lifecycle: lifecycle)

        let reports = await synchronizer.broadcaster.resubmitUnacceptedTransactions(through: publicServer)

        XCTAssertEqual(reports, [])
        XCTAssertTrue(endpointSubmitterMock.recordedSubmissions().isEmpty)
        let plan = await store.plan(for: rejected.rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.rejected(code: -26, reason: "bad-txns-vout-negative"))
    }

    /// The new server's refusal for good is recorded like a submission's: when it is the plan's only endpoint, its
    /// answer completes the verdict and the transaction is rejected, as reported.
    func testResubmitUnacceptedRecordsATerminalRefusalAsTheRejectionVerdict() async throws {
        let publicServer = LightWalletEndpoint(address: "public.example.com", port: 443, secure: true)
        let endpointSubmitterMock = EndpointSubmitterMock()
        endpointSubmitterMock.set(behavior: .reject(code: -26, message: "bad-txns-vout-negative"), for: publicServer)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let stuck = makeTransaction(raw: Data([0x07]), rawID: Data(repeating: 0x52, count: 32))
        try reportPending([stuck])
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        await store.recordPlan(txId: stuck.rawID, endpoints: [publicServer])

        let reports = await synchronizer.broadcaster.resubmitUnacceptedTransactions(through: publicServer)

        XCTAssertEqual(
            reports,
            [TransactionSubmissionReport(txId: stuck.rawID, outcome: .rejected(code: -26, message: "bad-txns-vout-negative"))]
        )
        let plan = await store.plan(for: stuck.rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.rejected(code: -26, reason: "bad-txns-vout-negative"))
    }

    /// The verdict needs every planned endpoint's answer: a refusal for good from the new server alone, while a
    /// recorded server (such as an unreachable Private endpoint) has not answered, leaves the transaction pending.
    func testResubmitUnacceptedTerminalRefusalWithAnUnansweredPlannedEndpointStaysPending() async throws {
        let gateway = LightWalletEndpoint(address: "gateway.example.com", port: 443, secure: true)
        let publicServer = LightWalletEndpoint(address: "public.example.com", port: 443, secure: true)
        let endpointSubmitterMock = EndpointSubmitterMock()
        endpointSubmitterMock.set(behavior: .reject(code: -26, message: "bad-txns-vout-negative"), for: publicServer)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let stuck = makeTransaction(raw: Data([0x08]), rawID: Data(repeating: 0x53, count: 32))
        try reportPending([stuck])
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        await store.recordPlan(txId: stuck.rawID, endpoints: [gateway])

        let reports = await synchronizer.broadcaster.resubmitUnacceptedTransactions(through: publicServer)

        // Pending, as a submission whose refusal for good the store did not record is reported.
        XCTAssertEqual(reports, [TransactionSubmissionReport(txId: stuck.rawID, outcome: .timedOut)])
        let plan = await store.plan(for: stuck.rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([gateway, publicServer], acceptedBy: nil))
    }

    /// A new server that already holds the transaction has accepted it: recorded as an acceptance.
    func testResubmitUnacceptedCountsAlreadyInMempoolAsAcceptance() async throws {
        let gateway = LightWalletEndpoint(address: "gateway.example.com", port: 443, secure: true)
        let publicServer = LightWalletEndpoint(address: "public.example.com", port: 443, secure: true)
        let endpointSubmitterMock = EndpointSubmitterMock()
        endpointSubmitterMock.set(behavior: .reject(code: -26, message: "18: txn-already-in-mempool"), for: publicServer)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let stuck = makeTransaction(raw: Data([0x09]), rawID: Data(repeating: 0x54, count: 32))
        try reportPending([stuck])
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        await store.recordPlan(txId: stuck.rawID, endpoints: [gateway])

        let reports = await synchronizer.broadcaster.resubmitUnacceptedTransactions(through: publicServer)

        XCTAssertEqual(reports, [TransactionSubmissionReport(txId: stuck.rawID, outcome: .accepted(by: publicServer))])
        let plan = await store.plan(for: stuck.rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([gateway, publicServer], acceptedBy: "public.example.com:443"))
    }

    // MARK: - Helpers

    /// What the repository reports as neither mined nor expired. Call it after `makeSynchronizer`, which
    /// registers the repository double this sets up.
    private func reportPending(_ overviews: [ZcashTransaction.Overview]) throws {
        let repository = try XCTUnwrap(mockContainer.resolve(TransactionRepository.self) as? TransactionRepositoryMock)
        repository.findForResubmissionUpToReturnValue = overviews
    }

    /// A synchronizer for the tests that submit to the local servers. Its rust backend is a double that lets every transaction through,
    /// because what these tests are about is the outcome of the submission; the check that comes before it has suites of its own
    /// (`TransactionSubmittabilityTests`, `EndpointSubmitterTests`).
    private func makeSubmittingSynchronizer() throws -> SDKSynchronizer {
        try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            rustBackend: ZcashRustBackendWeldingMock()
        )
    }

    private func makeSynchronizer(
        transactionEncoder: TransactionEncoder,
        rustBackend: ZcashRustBackendWelding? = nil,
        endpointSubmitter: EndpointSubmitter? = nil,
        spendParamsURL: URL? = nil,
        outputParamsURL: URL? = nil,
        saplingParamsSourceURL: SaplingParamsSourceURL = .tests
    ) throws -> SDKSynchronizer {
        let serviceMock = LightWalletServiceMock()
        let transactionRepository = TransactionRepositoryMock()

        if let rustBackend {
            mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackend }
        }
        if let endpointSubmitter {
            mockContainer.mock(type: EndpointSubmitter.self, isSingleton: true) { _ in endpointSubmitter }
        }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in serviceMock }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in transactionRepository }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in submissionLifecycleLogger() }

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try spendParamsURL ?? __spendParamsURL(),
            outputParamsURL: try outputParamsURL ?? __outputParamsURL(),
            saplingParamsSourceURL: saplingParamsSourceURL,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        let blockProcessor = CompactBlockProcessor(
            initializer: initializer,
            walletBirthdayProvider: { initializer.walletBirthday }
        )

        return SDKSynchronizer(
            status: .unprepared,
            initializer: initializer,
            transactionEncoder: transactionEncoder,
            transactionRepository: transactionRepository,
            blockProcessor: blockProcessor,
            syncSessionTicker: .live
        )
    }

    private func makeWalletTransactionEncoder(
        rustBackend: ZcashRustBackendWelding,
        spendParams: URL? = nil,
        outputParams: URL? = nil
    ) -> WalletTransactionEncoder {
        WalletTransactionEncoder(
            rustBackend: rustBackend,
            dataDb: (try? __dataDbURL()) ?? testTempDirectory.appendingPathComponent("data.db"),
            fsBlockDbRoot: testTempDirectory,
            service: LightWalletServiceMock(),
            repository: TransactionRepositoryMock(),
            outputParams: outputParams ?? ((try? __outputParamsURL()) ?? testTempDirectory),
            spendParams: spendParams ?? ((try? __spendParamsURL()) ?? testTempDirectory),
            networkType: .testnet,
            logger: submissionLifecycleLogger(),
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        )
    }

    /// A one-step proposal spending one note of `inputPool` to one payment in `paymentPool`.
    private static func proposal(
        inputPool: FfiValuePool,
        paymentPool: FfiValuePool,
        changePool: FfiValuePool? = nil,
        saplingDummies: UInt32 = 0
    ) -> FfiProposal {
        var receivedOutput = FfiReceivedOutput()
        receivedOutput.txid = Data(repeating: 0, count: TxId.byteLength)
        receivedOutput.valuePool = inputPool
        receivedOutput.value = 1_010_000
        var input = FfiProposedInput()
        input.value = .receivedOutput(receivedOutput)

        var payment = FfiPaymentOutputPool()
        payment.paymentIndex = 0
        payment.valuePool = paymentPool

        var balance = FfiTransactionBalance()
        balance.feeRequired = 10_000
        if let changePool {
            var change = FfiChangeValue()
            change.value = 1_000
            change.valuePool = changePool
            balance.proposedChange = [change]
        }
        var dummies = FfiDummyOutputs()
        dummies.sapling = saplingDummies
        balance.dummyOutputs = dummies

        var step = FfiProposalStep()
        step.inputs = [input]
        step.paymentOutputPools = [payment]
        step.balance = balance

        var proposal = FfiProposal()
        proposal.steps = [step]
        return proposal
    }

    private func makeTransaction(raw: Data?, rawID: Data) -> ZcashTransaction.Overview {
        CreatedTransactionTests.makeTransaction(raw: raw, rawID: rawID)
    }

    private func makeCreatedTransaction(seed: UInt8 = 0xAB) -> CreatedTransaction {
        CreatedTransaction(
            txId: Data(repeating: seed, count: 32),
            raw: Data([seed, 0x02, 0x03, 0x04]),
            expiryHeight: 123_456
        )
    }

    private func makeSendResponse(errorCode: Int32, errorMessage: String) -> SendResponse {
        var response = SendResponse()
        response.errorCode = errorCode
        response.errorMessage = errorMessage
        return response
    }

    /// Same construction as `Dependencies.swift:58-64` — the real `SubmitPlanStore`'s backing file
    /// that `mockContainer.resolve(SubmitPlanStoring.self)` resolves to in these tests.
    private func submitPlanDatabaseURL(for synchronizer: SDKSynchronizer) -> URL {
        synchronizer.initializer.generalStorageURL
            .appendingPathComponent("submit_plans_\(synchronizer.initializer.network.networkType.networkId).db")
    }
}

// MARK: - Test Doubles

private final class StubTransactionEncoder: TransactionEncoder {
    private let createdTransactions: [CreatedTransaction]
    private let overviews: [ZcashTransaction.Overview]
    private let fetchError: Error?
    private let missingHistoryTxIds: Set<Data>
    private(set) var receivedCreateArguments: (proposal: Proposal, spendingKey: UnifiedSpendingKey)?
    private(set) var receivedOvkPolicy: OvkPolicy?
    private(set) var receivedSizeBound: TransactionSizeBound?
    /// When set, `submit(transaction:)` records the transaction and then throws this error.
    var submitError: Error?
    private(set) var requiresSaplingParametersCallsCount = 0
    /// What `requiresSaplingParameters(for:)` answers; the SDK downloads the parameters only when it is true.
    var requiresSaplingParameters = true
    private(set) var receivedFetchTxIds: [Data]?
    private(set) var submittedTransactions: [EncodedTransaction] = []
    /// Runs at the start of `createProposedTransactions`, standing in for the (potentially slow)
    /// proving work it represents — e.g. to land a `wipe()` while a transaction is mid-creation.
    var onCreateProposedTransactions: (() async -> Void)?

    init(
        createdTransactions overviews: [ZcashTransaction.Overview],
        fetchError: Error? = nil,
        missingHistoryTxIds: Set<Data> = []
    ) {
        self.overviews = overviews
        self.createdTransactions = overviews.map { overview in
            guard let raw = overview.raw else {
                XCTFail("StubTransactionEncoder requires raw transaction bytes")
                return CreatedTransaction(txId: overview.rawID, raw: Data(), expiryHeight: overview.expiryHeight)
            }
            return CreatedTransaction(txId: overview.rawID, raw: raw, expiryHeight: overview.expiryHeight)
        }
        self.fetchError = fetchError
        self.missingHistoryTxIds = missingHistoryTxIds
    }

    func proposeTransfer(
        accountUUID: AccountUUID,
        recipient: String,
        amount: Zatoshi,
        memoBytes: MemoBytes?,
        sizeBound: TransactionSizeBound
    ) async throws -> Proposal {
        fatalError("Unused in test")
    }

    func proposeSendMax(
        accountUUID: AccountUUID,
        recipient: String,
        memoBytes: MemoBytes?,
        mode: MaxSpendMode,
        sizeBound: TransactionSizeBound
    ) async throws -> Proposal {
        fatalError("Unused in test")
    }

    func proposeOrchardToIronwoodMigration(accountUUID: AccountUUID) async throws -> Proposal {
        fatalError("Unused in test")
    }

    func proposeShielding(
        accountUUID: AccountUUID,
        shieldingThreshold: Zatoshi,
        memoBytes: MemoBytes?,
        transparentReceiver: String?
    ) async throws -> Proposal? {
        fatalError("Unused in test")
    }

    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey,
        ovkPolicy: OvkPolicy,
        sizeBound: TransactionSizeBound
    ) async throws -> [CreatedTransaction] {
        receivedCreateArguments = (proposal, spendingKey)
        receivedOvkPolicy = ovkPolicy
        receivedSizeBound = sizeBound
        if let onCreateProposedTransactions {
            await onCreateProposedTransactions()
        }
        return createdTransactions
    }

    func requiresSaplingParameters(for proposal: Proposal) throws -> Bool {
        requiresSaplingParametersCallsCount += 1
        return requiresSaplingParameters
    }

    func createdTransactions(forTxIds txIds: [Data]) async throws -> [CreatedTransaction] {
        txIds.compactMap { txId in
            createdTransactions.first { $0.txId == txId }
        }
    }

    func proposeFulfillingPaymentFromURI(
        _ uri: String,
        accountUUID: AccountUUID,
        sizeBound: TransactionSizeBound
    ) async throws -> Proposal {
        fatalError("Unused in test")
    }

    func submit(transaction: EncodedTransaction) async throws {
        submittedTransactions.append(transaction)
        if let submitError {
            throw submitError
        }
    }

    func isTransactionKnownToServer(txId: Data) async -> Bool {
        false
    }

    func fetchTransactionsForTxIds(_ txIds: [Data]) async throws -> [ZcashTransaction.Overview] {
        receivedFetchTxIds = txIds
        if let fetchError {
            throw fetchError
        }
        if txIds.contains(where: missingHistoryTxIds.contains) {
            throw ZcashError.transactionRepositoryEntityNotFound
        }
        return txIds.compactMap { txId in
            overviews.first { $0.rawID == txId }
        }
    }

    func closeDBConnection() { }
}

/// A `Broadcaster` that implements only the sender-policy requirements, so the protocol's default
/// `ovkPolicy:` overload is the one under test.
private final class SenderOnlyBroadcaster: Broadcaster {
    private(set) var createCallsCount = 0

    func createProposedTransactions(proposal: Proposal, spendingKey: UnifiedSpendingKey) async throws -> [CreatedTransaction] {
        createCallsCount += 1
        return []
    }

    func createTransactionFromPCZT(pcztWithProofs: Pczt, pcztWithSigs: Pczt) async throws -> [CreatedTransaction] {
        []
    }

    func submit(
        transaction: CreatedTransaction,
        to endpoints: [LightWalletEndpoint],
        timing: SubmissionTiming
    ) async -> TransactionSubmissionOutcome {
        .unreachable
    }

    func submit(
        transactions: [CreatedTransaction],
        to endpoints: [LightWalletEndpoint],
        timing: SubmissionTiming
    ) async -> [TransactionSubmissionReport] {
        []
    }
}
