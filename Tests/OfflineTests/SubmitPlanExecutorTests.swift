//
//  SubmitPlanExecutorTests.swift
//  ZODLSwiftWalletSDK
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class SubmitPlanExecutorTests: ZcashTestCase {
    private var mock: EndpointSubmitterMock!
    private var executor: SubmitPlanExecutor!

    override func setUp() async throws {
        try await super.setUp()
        mock = EndpointSubmitterMock()
        executor = SubmitPlanExecutor(endpointSubmitter: mock, logger: submissionLifecycleLogger())
    }

    private func endpoint(_ index: Int) -> LightWalletEndpoint {
        LightWalletEndpoint(address: "server\(index).example.com", port: 9067, secure: true)
    }

    private func makeTransaction() -> CreatedTransaction {
        CreatedTransaction(
            txId: Data(repeating: 0xAB, count: 32),
            raw: Data([0x01, 0x02]),
            expiryHeight: nil
        )
    }

    func testStopsAtFirstSuccess() async throws {
        mock.set(behavior: .succeed, for: endpoint(1))

        let accepting = try await executor.submit(transaction: makeTransaction(), endpoints: [endpoint(1), endpoint(2)])

        XCTAssertEqual(mock.recordedSubmissions().map(\.host), ["server1.example.com"])
        XCTAssertEqual(accepting, endpoint(1))
    }

    func testTriesNextEndpointAfterFailure() async throws {
        mock.set(behavior: .failTransport, for: endpoint(1))
        mock.set(behavior: .succeed, for: endpoint(2))

        let accepting = try await executor.submit(transaction: makeTransaction(), endpoints: [endpoint(1), endpoint(2)])

        XCTAssertEqual(mock.recordedSubmissions().map(\.host), ["server1.example.com", "server2.example.com"])
        XCTAssertEqual(accepting, endpoint(2))
    }

    func testReturnsNoAcceptingEndpointWhenThereIsNothingToSubmitTo() async throws {
        let accepting = try await executor.submit(transaction: makeTransaction(), endpoints: [])

        XCTAssertNil(accepting)
        XCTAssertTrue(mock.recordedSubmissions().isEmpty)
    }

    /// A refusal saying the server already holds the transaction is that endpoint's acceptance, even
    /// after another endpoint refused it terminally.
    func testAnEndpointThatAlreadyHoldsTheTransactionAcceptsIt() async throws {
        mock.set(behavior: .reject(code: -26, message: "16: bad-txns-sapling-bundle-invalid"), for: endpoint(1))
        mock.set(behavior: .reject(code: -26, message: "18: txn-already-in-mempool"), for: endpoint(2))

        let attempt = try await executor.submitRecordingAnswers(transaction: makeTransaction(), endpoints: [endpoint(1), endpoint(2)])

        XCTAssertEqual(attempt.accepted, endpoint(2))
        XCTAssertEqual(attempt.answers[endpointKey(endpoint(2))], .accepted)
        XCTAssertNil(attempt.lastError)
    }

    func testThrowsLastErrorWhenAllEndpointsFail() async {
        mock.set(behavior: .failTransport, for: endpoint(1))
        mock.set(behavior: .reject(code: -25, message: "no"), for: endpoint(2))

        do {
            try await executor.submit(transaction: makeTransaction(), endpoints: [endpoint(1), endpoint(2)])
            XCTFail("Expected an error")
        } catch let TransactionEncoderError.submitError(code, _) {
            XCTAssertEqual(code, -25)
        } catch {
            XCTFail("Expected the LAST error (submitError), got \(error)")
        }
    }

    func testCancellationStopsTryingRemainingEndpoints() async {
        mock.set(behavior: .hang, for: endpoint(1))
        mock.set(behavior: .succeed, for: endpoint(2))
        let executor = self.executor!
        let transaction = makeTransaction()
        let endpoints = [endpoint(1), endpoint(2)]

        let task = Task { () -> Error? in
            do {
                try await executor.submit(transaction: transaction, endpoints: endpoints)
                return nil
            } catch {
                return error
            }
        }

        // Let the first (hanging) submission start, then cancel.
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let thrown = await task.value

        XCTAssertTrue(thrown is CancellationError, "Expected CancellationError, got \(String(describing: thrown))")
        // The second endpoint must never be attempted after cancellation.
        XCTAssertEqual(mock.recordedSubmissions().map(\.host), ["server1.example.com"])
    }
}
