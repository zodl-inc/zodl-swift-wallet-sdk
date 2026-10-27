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

    // MARK: - Helpers

    /// A resubmitter over the two candidates, `firstId` before `secondId`. The encoder is the real single-server sink over the
    /// stubbed service and check. A transaction with a submit plan goes through `GRPCEndpointSubmitter` over the same check.
    private func makeResubmitter() throws -> TxResubmitter {
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
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        )
        let endpointSubmitter = GRPCEndpointSubmitter(
            torClient: TorClient(torDir: try __torDirURL()),
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false),
            rustBackend: rustBackend,
            logger: submissionLifecycleLogger()
        )

        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in self.transactionRepository }
        mockContainer.mock(type: TransactionEncoder.self, isSingleton: true) { _ in encoder }
        mockContainer.mock(type: SubmitPlanStoring.self, isSingleton: true) { _ in self.submitPlanStore }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in submissionLifecycleLogger() }
        mockContainer.mock(type: SubmitPlanExecutor.self, isSingleton: true) { _ in
            SubmitPlanExecutor(endpointSubmitter: endpointSubmitter, logger: submissionLifecycleLogger())
        }

        let resubmitter = TxResubmitter(container: mockContainer)
        // Push the throttle back so the pass resubmits.
        resubmitter.latestResolvedTime = 0
        return resubmitter
    }
}
