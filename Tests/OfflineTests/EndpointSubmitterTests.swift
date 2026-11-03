//
//  EndpointSubmitterTests.swift
//  ZODLSwiftWalletSDK
//

import os
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class EndpointSubmitterTests: ZcashTestCase {
    /// The check every submission passes. It lets everything through unless a test says otherwise.
    private var rustBackend: ZcashRustBackendWeldingMock!

    override func setUp() async throws {
        try await super.setUp()
        rustBackend = ZcashRustBackendWeldingMock()
    }

    private func makeSubmitter() throws -> GRPCEndpointSubmitter {
        GRPCEndpointSubmitter(
            torClient: TorClient(torDir: try __torDirURL()),
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false),
            rustBackend: rustBackend,
            logger: submissionLifecycleLogger(),
            networkType: .testnet
        )
    }

    private func makeTransaction() -> CreatedTransaction {
        CreatedTransaction(
            txId: Data(repeating: 0xAB, count: 32),
            raw: Data([0x01, 0x02, 0x03, 0x04]),
            expiryHeight: 123_456
        )
    }

    private func makeSendResponse(errorCode: Int32, errorMessage: String) -> SendResponse {
        var response = SendResponse()
        response.errorCode = errorCode
        response.errorMessage = errorMessage
        return response
    }

    /// A lightwalletd stand-in whose latest block is at `height` and whose answer to a submission is `response`.
    private func makeServer(
        height: UInt64 = 3_543_000,
        response: SendResponse = SendResponse(),
        fetchedTransaction: RawTransaction? = nil
    ) throws -> HeightReportingLightwalletd {
        let server = try HeightReportingLightwalletd(sendResponse: response, fetchedTransaction: fetchedTransaction)
        server.latestBlockHeight = height
        addTeardownBlock { try? server.stop() }
        return server
    }

    func testEndpointSelectsFinalSubmitAndIgnoresRecoveryTraffic() async throws {
        for scenario in ["height", "submit", "rejected", "known", "local"] {
            let route = OHTTPHealthRoute(network: .testnet, gatewayHost: "\(UUID().uuidString).test", relayURL: "https://relay.test/", viaTor: false)
            let session = try OHTTPHealthSession(route: route, generation: UUID())
            defer { session.close() }
            let service = LightWalletServiceMock()
            service.closeConnectionsClosure = {}
            service.latestBlockHeightModeClosure = { _ in
                OHTTPHealthCenter.shared.begin(route: route, scope: .lightwalletd).record(outcome: scenario == "height" ? .transportUnavailable : .usable, stage: .complete)
                if scenario == "height" { throw ZcashError.serviceLatestBlockHeightFailed(LightWalletServiceError.timeOut) }
                return 3_543_404
            }
            service.submitSpendTransactionModeClosure = { _, _ in
                OHTTPHealthCenter.shared.begin(route: route, scope: .lightwalletd).record(outcome: scenario == "submit" ? .transportUnavailable : .backendUnavailable, stage: .complete)
                if scenario == "submit" { throw ZcashError.serviceSubmitFailed(LightWalletServiceError.timeOut) }
                return self.makeSendResponse(errorCode: -25, errorMessage: "rejected")
            }
            service.fetchTransactionTxIdModeClosure = { _, _ in
                OHTTPHealthCenter.shared.begin(route: route, scope: .lightwalletd).record(outcome: .transportUnavailable, stage: .connection)
                if scenario == "known" { return (tx: nil, status: .mined(3_543_404)) }
                throw LightWalletServiceError.timeOut
            }
            rustBackend.checkTransactionSubmittableSubmissionServerHeightReturnValue = scenario == "local" ? .expired : nil
            let tor = TorClient(torDir: try __torDirURL())
            let endpoint = LightWalletEndpoint(address: "ohttp-gateway-testnet.example", port: 443)
            let submitter = GRPCEndpointSubmitter(
                torClient: tor, sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false),
                rustBackend: rustBackend, logger: submissionLifecycleLogger(), networkType: .testnet,
                serviceFactory: { receivedEndpoint, receivedTor in
                    XCTAssertEqual(receivedEndpoint, endpoint)
                    XCTAssertTrue(receivedTor === tor)
                    return service
                }
            )
            let operation = OHTTPHealthOperation()
            let attempt = OHTTPHealthAttempt(operation: operation)
            await OHTTPHealthContext.withOperation(operation) {
                await OHTTPHealthContext.withAttempt(attempt) {
                    OHTTPHealthCenter.shared.begin(route: route, scope: .swaps).record(outcome: .transportUnavailable, stage: .connection)
                    do {
                        try await submitter.submit(transaction: self.makeTransaction(), to: endpoint)
                        XCTAssertEqual(scenario, "known")
                    } catch ZcashError.serviceSubmitFailed(let error) {
                        XCTAssertTrue(scenario == "height" || scenario == "submit")
                        XCTAssertEqual(error, .timeOut)
                    } catch TransactionEncoderError.submitError(let code, let message) {
                        XCTAssertEqual(scenario, "rejected")
                        XCTAssertEqual(code, -25)
                        XCTAssertEqual(message, "rejected")
                    } catch TransactionEncoderError.notSubmittable(let refusal) {
                        XCTAssertEqual(scenario, "local")
                        XCTAssertEqual(refusal, .expired)
                    } catch { XCTFail("Unexpected error: \(error)") }
                }
            }
            let updates = session.updates()
            await OHTTPHealthContext.complete(operation, failed: scenario != "known", failedAttempt: attempt)
            for await update in updates {
                if case .operationCompleted(_, _, let observations) = update {
                    let expected: [OHTTPHealthOutcome] = scenario == "height" || scenario == "submit" ? [.transportUnavailable] : []
                    XCTAssertEqual(observations.map(\.outcome), expected, scenario)
                    XCTAssertFalse(observations.contains { $0.scope == .swaps })
                    break
                }
            }
            XCTAssertEqual(service.latestBlockHeightModeCallsCount, 1)
            XCTAssertEqual(service.submitSpendTransactionModeCallsCount, scenario == "height" || scenario == "local" ? 0 : 1)
            XCTAssertEqual(service.fetchTransactionTxIdModeCallsCount, scenario == "known" || scenario == "rejected" ? 1 : 0)
            XCTAssertEqual(service.closeConnectionsCallsCount, 1)
        }
    }

    func testSubmitDeliversRawBytesToEndpoint() async throws {
        let service = try makeServer()
        let submitter = try makeSubmitter()
        let transaction = makeTransaction()

        try await submitter.submit(transaction: transaction, to: service.endpoint)

        XCTAssertEqual(service.recordedTransactions(), [transaction.raw])
    }

    func testSubmitThrowsSubmitErrorOnServerRejection() async throws {
        let service = try makeServer(response: makeSendResponse(errorCode: -25, errorMessage: "rejected"))
        let submitter = try makeSubmitter()

        do {
            try await submitter.submit(transaction: makeTransaction(), to: service.endpoint)
            XCTFail("Expected submitError")
        } catch let TransactionEncoderError.submitError(code, message) {
            XCTAssertEqual(code, -25)
            XCTAssertEqual(message, "rejected")
        }
    }

    func testSubmitTreatsRejectionAsSuccessWhenSameServerKnowsTransaction() async throws {
        let transaction = makeTransaction()
        var fetchedTransaction = RawTransaction()
        fetchedTransaction.data = transaction.raw
        let service = try makeServer(
            response: makeSendResponse(errorCode: -25, errorMessage: "already known"),
            fetchedTransaction: fetchedTransaction
        )
        let submitter = try makeSubmitter()

        try await submitter.submit(transaction: transaction, to: service.endpoint)

        XCTAssertEqual(service.recordedTransactions(), [transaction.raw])
    }

    func testSubmitThrowsTransportErrorForUnreachableEndpoint() async throws {
        let submitter = try makeSubmitter()
        // Nothing listens on this port; expect a transport-level failure.
        let endpoint = LightWalletEndpoint(
            address: "127.0.0.1",
            port: 1,
            secure: false,
            singleCallTimeoutInMillis: 2_000,
            streamingCallTimeoutInMillis: 2_000
        )

        do {
            try await submitter.submit(transaction: makeTransaction(), to: endpoint)
            XCTFail("Expected a transport error")
        } catch let TransactionEncoderError.submitError(code, message) {
            XCTFail("Expected a transport error, not a server rejection: \(code) \(message)")
        } catch {
            // Any non-submitError error is the expected transport failure.
        }
    }

    // MARK: - The check before the submission

    func testSubmitChecksTheTransactionAgainstTheEndpointsHeightBeforeSubmitting() async throws {
        let service = try makeServer(height: 3_543_404)
        let submitter = try makeSubmitter()
        let transaction = makeTransaction()
        rustBackend.checkTransactionSubmittableSubmissionServerHeightClosure = { _, _ in
            // The check has to come first: nothing has reached the server yet.
            XCTAssertTrue(service.recordedTransactions().isEmpty)
            return nil
        }

        try await submitter.submit(transaction: transaction, to: service.endpoint)

        let received = try XCTUnwrap(rustBackend.checkTransactionSubmittableSubmissionServerHeightReceivedArguments)
        XCTAssertEqual(received.rawTransaction, transaction.raw)
        XCTAssertEqual(received.submissionServerHeight, 3_543_404)
        XCTAssertEqual(service.recordedTransactions(), [transaction.raw])
    }

    func testSubmitRefusesATransactionThatCannotBeValidInTheNextBlock() async throws {
        for refusal in [TransactionSubmissionRefusal.wrongConsensusBranch, .expired] {
            let service = try makeServer()
            let submitter = try makeSubmitter()
            rustBackend.checkTransactionSubmittableSubmissionServerHeightReturnValue = refusal

            do {
                try await submitter.submit(transaction: makeTransaction(), to: service.endpoint)
                XCTFail("A transaction refused as \(refusal) must not be submitted")
            } catch TransactionEncoderError.notSubmittable(let thrown) {
                XCTAssertEqual(thrown, refusal)
            }

            XCTAssertTrue(service.recordedTransactions().isEmpty, "a refused transaction never reaches the server")
        }
    }

    func testSubmitFailsClosedWhenTheEndpointsHeightIsUnreadable() async throws {
        // A server that does not answer a height request.
        let service = try RecordingCompactTxStreamerService(sendResponse: SendResponse())
        addTeardownBlock { try? service.stop() }
        let submitter = try makeSubmitter()

        do {
            try await submitter.submit(transaction: makeTransaction(), to: service.endpoint)
            XCTFail("A transaction whose destination height cannot be read must not be submitted")
        } catch ZcashError.serviceSubmitFailed {
            // The height is the first request of the attempt: a read that fails is an attempt that could not reach the endpoint.
        }

        XCTAssertEqual(rustBackend.checkTransactionSubmittableSubmissionServerHeightCallsCount, 0, "nothing is judged against a guess")
        XCTAssertTrue(service.recordedTransactions().isEmpty)
    }

    func testSubmitFailsClosedWhenTheEndpointReportsAHeightTheSDKCannotUse() async throws {
        let service = try makeServer(height: UInt64(Int32.max) + 1)
        let submitter = try makeSubmitter()

        do {
            try await submitter.submit(transaction: makeTransaction(), to: service.endpoint)
            XCTFail("A height above Int32.max is not one to judge by")
        } catch ZcashError.serviceSubmitFailed {
        }

        XCTAssertEqual(rustBackend.checkTransactionSubmittableSubmissionServerHeightCallsCount, 0)
        XCTAssertTrue(service.recordedTransactions().isEmpty)
    }

    func testSubmitFailsClosedWhenTheCheckCannotJudge() async throws {
        let service = try makeServer()
        let submitter = try makeSubmitter()
        rustBackend.checkTransactionSubmittableSubmissionServerHeightThrowableError = ZcashError.rustCheckTransactionSubmittable("unparseable")

        do {
            try await submitter.submit(transaction: makeTransaction(), to: service.endpoint)
            XCTFail("A transaction that cannot be judged must not be submitted")
        } catch ZcashError.rustCheckTransactionSubmittable {
        }

        XCTAssertTrue(service.recordedTransactions().isEmpty)
    }

    func testEachEndpointIsCheckedAgainstItsOwnHeight() async throws {
        let behind = try makeServer(height: 3_543_000)
        let ahead = try makeServer(height: 3_543_404)
        let submitter = try makeSubmitter()
        let transaction = makeTransaction()
        let checkedHeights = OSAllocatedUnfairLock(initialState: [BlockHeight]())
        rustBackend.checkTransactionSubmittableSubmissionServerHeightClosure = { _, height in
            checkedHeights.withLock { $0.append(height) }
            return nil
        }

        try await submitter.submit(transaction: transaction, to: behind.endpoint)
        try await submitter.submit(transaction: transaction, to: ahead.endpoint)

        XCTAssertEqual(
            checkedHeights.withLock { $0 },
            [3_543_000, 3_543_404],
            "the check receives the height of the endpoint it is about to submit to, not a shared one"
        )
    }

    func testTheSameTransactionIsSubmittableToOneEndpointAndRefusedByAnother() async throws {
        let behind = try makeServer(height: 3_543_000)
        let ahead = try makeServer(height: 3_543_404)
        let submitter = try makeSubmitter()
        let transaction = makeTransaction()
        // Built for the branch before the activation: right while the next block is below it.
        rustBackend.checkTransactionSubmittableSubmissionServerHeightClosure = { _, height in
            height >= 3_543_404 ? TransactionSubmissionRefusal.wrongConsensusBranch : nil
        }
        let multiEndpointSubmitter = MultiEndpointSubmitter(endpointSubmitter: submitter, logger: submissionLifecycleLogger())

        let outcome = await multiEndpointSubmitter.submit(
            transaction: transaction,
            to: [ahead.endpoint, behind.endpoint],
            timing: SubmissionTiming(responseTimeout: 5, postAcceptanceGraceDelay: 0.2)
        )

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.accepted(by: behind.endpoint))
        XCTAssertEqual(behind.recordedTransactions(), [transaction.raw])
        XCTAssertTrue(ahead.recordedTransactions().isEmpty)
    }

    func testAllEndpointsRefusingIsARejection() async throws {
        let first = try makeServer()
        let second = try makeServer()
        let submitter = try makeSubmitter()
        rustBackend.checkTransactionSubmittableSubmissionServerHeightReturnValue = .expired
        let multiEndpointSubmitter = MultiEndpointSubmitter(endpointSubmitter: submitter, logger: submissionLifecycleLogger())

        let outcome = await multiEndpointSubmitter.submit(
            transaction: makeTransaction(),
            to: [first.endpoint, second.endpoint],
            timing: SubmissionTiming(responseTimeout: 5, postAcceptanceGraceDelay: 0.2)
        )

        XCTAssertEqual(
            outcome,
            TransactionSubmissionOutcome.rejected(code: -9102, message: TransactionSubmissionRefusal.expired.description)
        )
        XCTAssertTrue(first.recordedTransactions().isEmpty)
        XCTAssertTrue(second.recordedTransactions().isEmpty)
    }

    func testAnUnreadableEndpointHeightCountsAsUnreachableForThatEndpoint() async throws {
        let unreadable = try RecordingCompactTxStreamerService(sendResponse: SendResponse())
        addTeardownBlock { try? unreadable.stop() }
        let readable = try makeServer()
        let submitter = try makeSubmitter()
        let transaction = makeTransaction()
        let multiEndpointSubmitter = MultiEndpointSubmitter(endpointSubmitter: submitter, logger: submissionLifecycleLogger())

        let outcome = await multiEndpointSubmitter.submit(
            transaction: transaction,
            to: [unreadable.endpoint, readable.endpoint],
            timing: SubmissionTiming(responseTimeout: 5, postAcceptanceGraceDelay: 0.2)
        )

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.accepted(by: readable.endpoint))
        XCTAssertEqual(readable.recordedTransactions(), [transaction.raw])
        XCTAssertTrue(unreadable.recordedTransactions().isEmpty)
    }

    func testEveryEndpointHeightBeingUnreadableIsUnreachable() async throws {
        let first = try RecordingCompactTxStreamerService(sendResponse: SendResponse())
        addTeardownBlock { try? first.stop() }
        let second = try RecordingCompactTxStreamerService(sendResponse: SendResponse())
        addTeardownBlock { try? second.stop() }
        let submitter = try makeSubmitter()
        let multiEndpointSubmitter = MultiEndpointSubmitter(endpointSubmitter: submitter, logger: submissionLifecycleLogger())

        let outcome = await multiEndpointSubmitter.submit(
            transaction: makeTransaction(),
            to: [first.endpoint, second.endpoint],
            timing: SubmissionTiming(responseTimeout: 5, postAcceptanceGraceDelay: 0.2)
        )

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.unreachable)
        XCTAssertTrue(first.recordedTransactions().isEmpty)
        XCTAssertTrue(second.recordedTransactions().isEmpty)
    }
}
