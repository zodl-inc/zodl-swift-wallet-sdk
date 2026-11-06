//
//  TxResubmitterSubmittabilityTests.swift
//  OfflineTests
//
//  A resubmission is a submission like any other: both paths of `TxResubmitter` end in a sink that checks
//  the transaction against the next block before it reaches the network. These tests run the real sinks,
//  `WalletTransactionEncoder.submit` for a transaction without a submit plan and `GRPCEndpointSubmitter`
//  (through `SubmitPlanExecutor`) for one with a plan, against a stubbed check. A transaction the SDK
//  refuses to submit, or whose destination height cannot be read, is skipped like any other resubmission
//  failure, and the pass goes on to the transactions after it.
//

import os
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class TxResubmitterSubmittabilityTests: ZcashTestCase {
    private let firstId = Data(repeating: 0x01, count: 32)
    private let secondId = Data(repeating: 0x02, count: 32)
    private let firstRaw = Data([0x05, 0x00, 0x00, 0x80, 0x01])
    private let secondRaw = Data([0x05, 0x00, 0x00, 0x80, 0x02])

    private var transactionRepository: TransactionRepositoryMock!
    private var submitPlanStore: SubmitPlanStoringMock!
    private var rustBackend: ZcashRustBackendWeldingMock!
    private var service: LightWalletServiceMock!

    override func setUp() async throws {
        try await super.setUp()
        rustBackend = ZcashRustBackendWeldingMock()
        service = LightWalletServiceMock()
        service.latestBlockHeightModeReturnValue = 3_543_404
        service.submitSpendTransactionModeReturnValue = SendResponse()
        submitPlanStore = SubmitPlanStoringMock()
    }

    // MARK: - A transaction without a submit plan, through the single-server sink

    func testResubmitterSkipsARefusedTransactionAndContinues() async throws {
        rustBackend.checkTransactionSubmittableSubmissionServerHeightClosure = { [firstRaw] raw, _ in
            raw == firstRaw ? TransactionSubmissionRefusal.wrongConsensusBranch : nil
        }
        let resubmitter = try makeResubmitter()

        await resubmitter.checkAndResubmit(latestBlockHeight: 100_000)

        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 1, "the refused transaction is not submitted, the other one is")
        XCTAssertEqual(service.submitSpendTransactionModeReceivedArguments?.spendTransaction, secondRaw)
        XCTAssertEqual(rustBackend.checkTransactionSubmittableSubmissionServerHeightCallsCount, 2, "both were judged")
        XCTAssertGreaterThan(resubmitter.latestResolvedTime, 0, "the pass ran to its end")
    }

    func testResubmitterSkipsATransactionWhoseHeightIsUnreadableAndContinues() async throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        service.latestBlockHeightModeClosure = { _ in
            let read = reads.withLock { count -> Int in
                count += 1
                return count
            }
            if read == 1 {
                throw ZcashError.serviceLatestBlockHeightFailed(LightWalletServiceError.timeOut)
            }
            return 3_543_404
        }
        let resubmitter = try makeResubmitter()

        await resubmitter.checkAndResubmit(latestBlockHeight: 100_000)

        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 1, "nothing is submitted whose destination height is unknown")
        XCTAssertEqual(service.submitSpendTransactionModeReceivedArguments?.spendTransaction, secondRaw)
        XCTAssertEqual(rustBackend.checkTransactionSubmittableSubmissionServerHeightCallsCount, 1, "nothing is judged against a guess")
        XCTAssertGreaterThan(resubmitter.latestResolvedTime, 0)
    }

    // MARK: - A transaction with a submit plan, through the per-endpoint sink

    func testResubmitterSkipsARefusedPlannedTransactionAndContinues() async throws {
        let server = try HeightReportingLightwalletd()
        server.latestBlockHeight = 3_543_404
        addTeardownBlock { try? server.stop() }
        await submitPlanStore.recordPlan(txId: firstId, endpoints: [server.endpoint])
        await submitPlanStore.recordPlan(txId: secondId, endpoints: [server.endpoint])
        rustBackend.checkTransactionSubmittableSubmissionServerHeightClosure = { [firstRaw] raw, _ in
            raw == firstRaw ? TransactionSubmissionRefusal.expired : nil
        }
        let resubmitter = try makeResubmitter()

        await resubmitter.checkAndResubmit(latestBlockHeight: 100_000)

        XCTAssertEqual(server.recordedTransactions(), [secondRaw], "the refused transaction never reaches the server")
        let firstPlan = await submitPlanStore.plan(for: firstId)
        XCTAssertEqual(firstPlan, StoredSubmitPlan.ready([server.endpoint], acceptedBy: nil), "its plan stays for a later pass")
        let secondPlan = await submitPlanStore.plan(for: secondId)
        XCTAssertEqual(secondPlan, StoredSubmitPlan.ready([server.endpoint], acceptedBy: "\(server.endpoint.host):\(server.endpoint.port)"))
        XCTAssertGreaterThan(resubmitter.latestResolvedTime, 0)
    }

    func testResubmitterSkipsAPlannedTransactionWhoseEndpointHeightIsUnreadableAndContinues() async throws {
        // The first transaction's server does not answer a height request, the second one's does.
        let unreadable = try RecordingCompactTxStreamerService(sendResponse: SendResponse())
        addTeardownBlock { try? unreadable.stop() }
        let readable = try HeightReportingLightwalletd()
        readable.latestBlockHeight = 3_543_404
        addTeardownBlock { try? readable.stop() }
        await submitPlanStore.recordPlan(txId: firstId, endpoints: [unreadable.endpoint])
        await submitPlanStore.recordPlan(txId: secondId, endpoints: [readable.endpoint])
        let resubmitter = try makeResubmitter()

        await resubmitter.checkAndResubmit(latestBlockHeight: 100_000)

        XCTAssertTrue(unreadable.recordedTransactions().isEmpty)
        XCTAssertEqual(readable.recordedTransactions(), [secondRaw])
        XCTAssertEqual(rustBackend.checkTransactionSubmittableSubmissionServerHeightCallsCount, 1)
        XCTAssertGreaterThan(resubmitter.latestResolvedTime, 0)
    }

    func testBackgroundResubmissionCannotBypassTransitionFence() async throws {
        let flags = SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        let resubmitter = try makeResubmitter(flags: flags)
        flags.routeAdmission.require(false)
        await resubmitter.checkAndResubmit(latestBlockHeight: 100_000)
        XCTAssertEqual(service.latestBlockHeightModeCallsCount, 0)
        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 0)
    }

    func testPrivateLegacyRetryOverridesTheEncodersRetainedServiceAndChecksSubmittability() async throws {
        let selected = try HeightReportingLightwalletd()
        selected.latestBlockHeight = 3_543_404
        defer { try? selected.stop() }
        rustBackend.checkTransactionSubmittableSubmissionServerHeightClosure = { [firstRaw] raw, _ in
            raw == firstRaw ? TransactionSubmissionRefusal.wrongConsensusBranch : nil
        }
        let resubmitter = try makeResubmitter()

        // The caller has already recognized its Private gateway. A local server stands in for
        // that selected destination here, while the encoder deliberately retains another service.
        await resubmitter.checkAndResubmit(latestBlockHeight: 100_000, privateEndpoint: selected.endpoint)

        XCTAssertEqual(selected.recordedTransactions(), [secondRaw])
        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 0)
        XCTAssertEqual(rustBackend.checkTransactionSubmittableSubmissionServerHeightCallsCount, 2)
    }

    func testPrivatePlannedRetryDoesNotFallbackWhenSelectedEndpointIsUnavailable() async throws {
        let selected = try RecordingCompactTxStreamerService(sendResponse: SendResponse())
        defer { try? selected.stop() }
        let recorded = try HeightReportingLightwalletd()
        recorded.latestBlockHeight = 3_543_404
        defer { try? recorded.stop() }
        await submitPlanStore.recordPlan(txId: firstId, endpoints: [recorded.endpoint])
        await submitPlanStore.recordPlan(txId: secondId, endpoints: [recorded.endpoint])
        rustBackend.checkTransactionSubmittableSubmissionServerHeightClosure = { _, _ in nil }
        let resubmitter = try makeResubmitter()

        await resubmitter.checkAndResubmit(latestBlockHeight: 100_000, privateEndpoint: selected.endpoint)

        XCTAssertTrue(selected.recordedTransactions().isEmpty)
        XCTAssertTrue(recorded.recordedTransactions().isEmpty)
        XCTAssertEqual(rustBackend.checkTransactionSubmittableSubmissionServerHeightCallsCount, 0)
    }

    func testCancelledRetryDoesNotReadCandidatesOrStampCadence() async throws {
        let resubmitter = try makeResubmitter()
        let gate = Gate()
        let task = Task {
            await gate.wait()
            await resubmitter.checkAndResubmit(latestBlockHeight: 100_000)
        }
        task.cancel()
        gate.open()
        await task.value
        XCTAssertEqual(transactionRepository.findForResubmissionUpToCallsCount, 0)
        XCTAssertEqual(resubmitter.latestResolvedTime, 0)
    }

    func testCancelledRetryPreservesCadenceAndKnownAcceptance() async throws {
        let endpoint = LightWalletEndpoint(address: "accepted.example.com", port: 443, secure: true)
        await submitPlanStore.recordPlan(txId: firstId, endpoints: [endpoint])
        await submitPlanStore.recordPlan(txId: secondId, endpoints: [endpoint])
        let entered = expectation(description: "accepted response pending")
        let gate = Gate()
        let submitter = AcceptanceSubmitter(entered: entered, gate: gate)
        let resubmitter = try makeResubmitter(endpointSubmitter: submitter)
        let task = Task { await resubmitter.checkAndResubmit(latestBlockHeight: 100_000) }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel()
        gate.open()
        await task.value
        let first = await submitPlanStore.plan(for: firstId)
        let second = await submitPlanStore.plan(for: secondId)
        XCTAssertEqual(first, .ready([endpoint], acceptedBy: "accepted.example.com:443"))
        XCTAssertEqual(second, .ready([endpoint], acceptedBy: nil))
        XCTAssertEqual(resubmitter.latestResolvedTime, 0)
        XCTAssertEqual(submitter.sent.withLock { $0 }, [firstId])
    }

    private final class AcceptanceSubmitter: EndpointSubmitter {
        let entered: XCTestExpectation
        let gate: Gate
        let sent = OSAllocatedUnfairLock(initialState: [Data]())
        init(entered: XCTestExpectation, gate: Gate) {
            self.entered = entered
            self.gate = gate
        }
        func submit(transaction: CreatedTransaction, to endpoint: LightWalletEndpoint) async throws {
            sent.withLock { $0.append(transaction.txId) }
            entered.fulfill()
            await gate.wait()
        }
    }

    // MARK: - Helpers

    /// A resubmitter over the two candidates, `firstId` before `secondId`. The encoder is the real single-server sink over the
    /// stubbed service and check. A transaction with a submit plan goes through `GRPCEndpointSubmitter` over the same check.
    private func makeResubmitter(flags: SDKFlags = SDKFlags(torEnabled: false, exchangeRateEnabled: false), endpointSubmitter override: EndpointSubmitter? = nil) throws -> TxResubmitter {
        let candidates = [
            CreatedTransactionTests.makeTransaction(raw: firstRaw, rawID: firstId),
            CreatedTransactionTests.makeTransaction(raw: secondRaw, rawID: secondId)
        ]
        transactionRepository = TransactionRepositoryMock()
        transactionRepository.findForResubmissionUpToClosure = { _ in candidates }
        transactionRepository.findRawIDClosure = { rawID in candidates.first { $0.rawID == rawID } ?? candidates[0] }

        let encoder = WalletTransactionEncoder(
            rustBackend: rustBackend,
            dataDb: try __dataDbURL(),
            fsBlockDbRoot: testTempDirectory,
            service: service,
            repository: transactionRepository,
            outputParams: try __outputParamsURL(),
            spendParams: try __spendParamsURL(),
            networkType: .testnet,
            logger: submissionLifecycleLogger(),
            sdkFlags: flags
        )
        let endpointSubmitter = GRPCEndpointSubmitter(
            torClient: TorClient(torDir: try __torDirURL()),
            sdkFlags: flags,
            rustBackend: rustBackend,
            logger: submissionLifecycleLogger(),
            networkType: .testnet
        )

        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in self.transactionRepository }
        mockContainer.mock(type: TransactionEncoder.self, isSingleton: true) { _ in encoder }
        mockContainer.mock(type: SubmitPlanStoring.self, isSingleton: true) { _ in self.submitPlanStore }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in submissionLifecycleLogger() }
        mockContainer.mock(type: SubmitPlanExecutor.self, isSingleton: true) { _ in
            SubmitPlanExecutor(endpointSubmitter: override ?? endpointSubmitter, logger: submissionLifecycleLogger())
        }

        let resubmitter = TxResubmitter(container: mockContainer)
        // Push the throttle back so the pass resubmits.
        resubmitter.latestResolvedTime = 0
        return resubmitter
    }
}
