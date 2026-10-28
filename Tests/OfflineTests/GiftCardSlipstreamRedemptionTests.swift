import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class GiftCardSlipstreamRedemptionTests: ZcashTestCase {
    // Returning an empty claim as a successful redemption would hide a missing submission.
    func testEmptyCompletionReportsIncompleteRedemption() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        _ = try await fixture.redeemer.check()
        fixture.backend.createProposedTransactionsProposalUskOvkPolicyReturnValue = []
        do {
            _ = try await fixture.redeemer.redeem(to: fixture.card.fundingAddress, memo: nil, recordIn: nil)
            XCTFail("Empty completion must not report a successful redemption")
        } catch let error as ZcashError {
            XCTAssertEqual(error.code.rawValue, "ZGIFT0012")
        }
        XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 0)
        try await fixture.redeemer.cleanup()
    }

    // Throwing a later stream error before recording would lose the earlier accepted receipt.
    func testAcceptedReceiptIsRecordedBeforeLaterStreamFailureIsRethrown() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let destination = try GiftCardDestinationFixture.make(storageDirectory: testTempDirectory, slipstream: true)
        _ = try await fixture.redeemer.check()
        let first = Data(repeating: 0xA1, count: 32)
        let second = Data(repeating: 0xB2, count: 32)
        fixture.backend.createProposedTransactionsProposalUskOvkPolicyReturnValue = [first, second]
        fixture.backend.getTransactionTxIdClosure = { id in
            TransactionData(txId: id, raw: Data([id[0]]), expiryHeight: 3_000_100)
        }
        fixture.service.submitSpendTransactionModeClosure = { raw, _ in
            if raw == Data([0xB2]) { throw LightWalletServiceError.timeOut }
            return SendResponse()
        }
        do {
            _ = try await fixture.redeemer.redeem(to: fixture.card.fundingAddress, memo: nil, recordIn: destination.synchronizer)
            XCTFail("Later stream transport failure must remain visible")
        } catch LightWalletServiceError.timeOut {
        }
        XCTAssertEqual(destination.backend.setTransactionTrustTxIdTrustedReceivedArguments?.txId, first)
        XCTAssertEqual(destination.backend.setTransactionTrustTxIdTrustedCallsCount, 1)
        XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 2)
        try await fixture.redeemer.cleanup()
    }

    func testClaimIntoSDKSynchronizerStoresAndTrustsReceipt() async throws {
        try await assertConcreteDestination(slipstream: false)
    }

    func testClaimIntoSlipstreamSynchronizerStoresAndTrustsReceipt() async throws {
        try await assertConcreteDestination(slipstream: true)
    }

    func testMultipleAcceptedClaimsContinueAfterDestinationRecordingFailure() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let destination = try GiftCardDestinationFixture.make(storageDirectory: testTempDirectory, slipstream: false)
        _ = try await fixture.redeemer.check()
        let first = Data(repeating: 0xA1, count: 32)
        let second = Data(repeating: 0xB2, count: 32)
        fixture.backend.createProposedTransactionsProposalUskOvkPolicyReturnValue = [first, second]
        fixture.backend.getTransactionTxIdClosure = { id in
            TransactionData(txId: id, raw: Data([id[0]]), expiryHeight: 3_000_100)
        }
        let attempts = GiftCardReceiptCapture()
        destination.backend.decryptAndStoreTransactionTxBytesMinedHeightClosure = { bytes, _ in
            await attempts.append(Data(bytes))
            if bytes == [0xA1] { throw LightWalletServiceError.timeOut }
            return second
        }
        let result = try await fixture.redeemer.redeem(
            to: fixture.card.fundingAddress, memo: nil, recordIn: destination.synchronizer
        )
        XCTAssertEqual(result.results, [.success(txId: first), .success(txId: second)])
        XCTAssertFalse(result.recordedInDestination)
        let receipts = await attempts.ids
        XCTAssertEqual(receipts, [Data([0xA1]), Data([0xB2])])
        XCTAssertEqual(destination.backend.setTransactionTrustTxIdTrustedReceivedArguments?.txId, second)
        XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 2)
        XCTAssertEqual(fixture.backend.createProposedTransactionsProposalUskOvkPolicyCallsCount, 1)
        try await fixture.redeemer.cleanup()
    }

    func testRejectedSubmissionIsReturnedWithoutDestinationRecording() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let destination = try GiftCardDestinationFixture.make(storageDirectory: testTempDirectory, slipstream: true)
        _ = try await fixture.redeemer.check()
        var rejected = SendResponse()
        rejected.errorCode = -1
        rejected.errorMessage = "rejected"
        fixture.service.submitSpendTransactionModeReturnValue = rejected
        fixture.service.fetchTransactionTxIdModeClosure = { _, _ in throw LightWalletServiceError.timeOut }
        let result = try await fixture.redeemer.redeem(
            to: fixture.card.fundingAddress, memo: nil, recordIn: destination.synchronizer
        )
        XCTAssertEqual(result.results, [.submitFailure(txId: Data(repeating: 0xA1, count: 32), code: -1, description: "rejected")])
        XCTAssertFalse(result.recordedInDestination)
        XCTAssertEqual(destination.backend.decryptAndStoreTransactionTxBytesMinedHeightCallsCount, 0)
        try await fixture.redeemer.cleanup()
    }

    // The server's height is the first request of a submission, so a server that cannot be asked for it is a claim that did not reach
    // the server. It is returned the way any other failure to reach it is, as a result, and does not throw away the redemption.
    func testUnreadableServerHeightIsReturnedAsAGrpcFailureWithoutDestinationRecording() async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let destination = try GiftCardDestinationFixture.make(storageDirectory: testTempDirectory, slipstream: true)
        _ = try await fixture.redeemer.check()
        fixture.service.latestBlockHeightModeClosure = { _ in
            throw ZcashError.serviceLatestBlockHeightFailed(LightWalletServiceError.timeOut)
        }
        let result = try await fixture.redeemer.redeem(
            to: fixture.card.fundingAddress, memo: nil, recordIn: destination.synchronizer
        )
        XCTAssertEqual(result.results, [.grpcFailure(txId: Data(repeating: 0xA1, count: 32), error: .timeOut)])
        XCTAssertFalse(result.recordedInDestination)
        XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 0)
        XCTAssertEqual(destination.backend.decryptAndStoreTransactionTxBytesMinedHeightCallsCount, 0)
        try await fixture.redeemer.cleanup()
    }

    private func assertConcreteDestination(slipstream: Bool) async throws {
        let fixture = try await GiftCardCancellationFixture.make(storageDirectory: testTempDirectory)
        let destination = try GiftCardDestinationFixture.make(storageDirectory: testTempDirectory, slipstream: slipstream)
        let order = GiftCardReceiptCapture()
        destination.backend.decryptAndStoreTransactionTxBytesMinedHeightClosure = { bytes, height in
            XCTAssertEqual(bytes, [1])
            XCTAssertNil(height)
            await order.append(Data([1]))
            return Data(repeating: 0xA1, count: 32)
        }
        destination.backend.setTransactionTrustTxIdTrustedClosure = { id, trusted in
            XCTAssertEqual(id, Data(repeating: 0xA1, count: 32))
            XCTAssertTrue(trusted)
            await order.append(Data([2]))
        }
        _ = try await fixture.redeemer.check()
        let result = try await fixture.redeemer.redeem(
            to: fixture.card.fundingAddress, memo: nil, recordIn: destination.synchronizer
        )
        XCTAssertEqual(result.results, [.success(txId: Data(repeating: 0xA1, count: 32))])
        XCTAssertTrue(result.recordedInDestination)
        XCTAssertEqual(result.fee, Zatoshi(10_000))
        XCTAssertEqual(result.amount, Zatoshi(40_000))
        XCTAssertEqual(fixture.backend.createProposedTransactionsProposalUskOvkPolicyReceivedArguments?.ovkPolicy, .discard)
        let calls = await order.ids
        XCTAssertEqual(calls, [Data([1]), Data([2])])
        try await fixture.redeemer.cleanup()
    }

    func testMissingRawReceiptStillRecordsFollowingAcceptedReceipt() async throws {
        let recorder = TrustedTransactionRecordingMock()
        let first = Data(repeating: 0xA1, count: 32)
        let second = Data(repeating: 0xB2, count: 32)
        let attempts = GiftCardReceiptCapture()
        recorder.recordTrustedTransactionTxIdClosure = { _, id in await attempts.append(Data(id.id)) }
        let recorded = await GiftCardRedeemer.record(
            [.success(txId: first), .success(txId: second)],
            in: recorder,
            rawTransaction: { $0 == first ? nil : Data([1]) },
            logger: NullLogger()
        )
        let receipts = await attempts.ids
        XCTAssertEqual(receipts, [second])
        XCTAssertFalse(recorded)
    }

    // Stopping at one failed receipt would silently skip accepted transactions that follow it.
    func testRecordingFailureStillAttemptsEveryAcceptedReceipt() async throws {
        let recorder = TrustedTransactionRecordingMock()
        let first = Data(repeating: 0xA1, count: 32)
        let second = Data(repeating: 0xB2, count: 32)
        let attempts = GiftCardReceiptCapture()
        recorder.recordTrustedTransactionTxIdClosure = { _, txId in
            await attempts.append(Data(txId.id))
            if Data(txId.id) == first { throw LightWalletServiceError.timeOut }
        }
        let recorded = await GiftCardRedeemer.record(
            [.success(txId: first), .success(txId: second)],
            in: recorder,
            rawTransaction: { _ in Data([1]) },
            logger: NullLogger()
        )
        let receipts = await attempts.ids
        XCTAssertEqual(receipts, [first, second])
        XCTAssertFalse(recorded)
    }
}

actor GiftCardReceiptCapture {
    private(set) var ids: [Data] = []
    func append(_ id: Data) { ids.append(id) }
}
