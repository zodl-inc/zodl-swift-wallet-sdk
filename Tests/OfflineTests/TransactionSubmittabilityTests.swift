//
//  TransactionSubmittabilityTests.swift
//  OfflineTests
//
//  Every raw submission is checked against the next block before it reaches the network: the one
//  after the higher of the wallet's chain tip and the latest block height the destination server
//  reports, read from the very service (and in the very mode) that is about to submit. A transaction
//  that cannot be valid there is not submitted, and a height that cannot be read fails closed.
//
//  `TransactionSubmittabilityTests` covers the single-server sink, `WalletTransactionEncoder.submit`,
//  and the streams `SDKSynchronizer` and `SlipstreamSynchronizer` build on it, against a stubbed
//  check. `TransactionSubmittabilityFFITests` runs the check itself through the real libzcashlc, the
//  one place the welded call and its `0` / `1` / `2` / `-1` answers meet the Rust layer.
//  `EndpointSubmitterTests` covers the per-endpoint sink and `TxResubmitterSubmittabilityTests` the
//  resubmission that reaches both.
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class TransactionSubmittabilityTests: ZcashTestCase {
    private let txId = Data(repeating: 0xAB, count: 32)
    private let raw = Data([0x05, 0x00, 0x00, 0x80, 0x01, 0x02])

    private var service: LightWalletServiceMock!
    private var backend: ZcashRustBackendWeldingMock!

    override func setUp() async throws {
        try await super.setUp()
        service = LightWalletServiceMock()
        service.latestBlockHeightModeReturnValue = 3_543_404
        service.submitSpendTransactionModeReturnValue = SendResponse()
        backend = ZcashRustBackendWeldingMock()
    }

    // MARK: - The single-server sink

    func testEncoderRefusesBeforeSubmitting() async throws {
        for refusal in [TransactionSubmissionRefusal.expired, .wrongConsensusBranch] {
            backend.checkTransactionSubmittableSubmissionServerHeightReturnValue = refusal
            let encoder = try makeEncoder()

            do {
                try await encoder.submit(transaction: EncodedTransaction(transactionId: txId, raw: raw))
                XCTFail("A transaction refused as \(refusal) must not be submitted")
            } catch TransactionEncoderError.notSubmittable(let thrown) {
                XCTAssertEqual(thrown, refusal)
            }
        }

        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 0, "a refused transaction never reaches the network")
    }

    func testEncoderFailsClosedWhenTheHeightIsUnreadable() async throws {
        service.latestBlockHeightModeClosure = { _ in
            throw ZcashError.serviceLatestBlockHeightFailed(LightWalletServiceError.timeOut)
        }
        let encoder = try makeEncoder()

        do {
            try await encoder.submit(transaction: EncodedTransaction(transactionId: txId, raw: raw))
            XCTFail("A transaction whose destination height cannot be read must not be submitted")
        } catch ZcashError.serviceSubmitFailed(let error) {
            // The height is the first request of the submission: a read that fails is a submission that could not reach the
            // server, and fails the way the submit after it would have, with the failure of the read inside.
            XCTAssertEqual(error, .timeOut)
        }

        XCTAssertEqual(backend.checkTransactionSubmittableSubmissionServerHeightCallsCount, 0, "nothing is judged against a guess")
        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 0)
    }

    func testEncoderReportsAnyOtherHeightReadErrorLikeAFailedSubmit() async throws {
        // Over Tor the read throws the error of the Tor connection, unwrapped, where the service's own submit wraps all of them.
        let torError = ZcashError.rustTorLwdLatestBlockHeight("no circuit")
        service.latestBlockHeightModeClosure = { _ in throw torError }
        let encoder = try makeEncoder()

        do {
            try await encoder.submit(transaction: EncodedTransaction(transactionId: txId, raw: raw))
            XCTFail("A transaction whose destination height cannot be read must not be submitted")
        } catch ZcashError.serviceSubmitFailed(let error) {
            guard case .genericError(let underlying) = error else {
                XCTFail("Expected a generic service error but got \(error)")
                return
            }
            XCTAssertEqual(underlying as? ZcashError, torError)
        }

        XCTAssertEqual(backend.checkTransactionSubmittableSubmissionServerHeightCallsCount, 0)
        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 0)
    }

    func testEncoderFailsClosedWhenTheCheckCannotJudge() async throws {
        backend.checkTransactionSubmittableSubmissionServerHeightThrowableError = ZcashError.rustCheckTransactionSubmittable("unparseable")
        let encoder = try makeEncoder()

        do {
            try await encoder.submit(transaction: EncodedTransaction(transactionId: txId, raw: raw))
            XCTFail("A transaction that cannot be judged must not be submitted")
        } catch ZcashError.rustCheckTransactionSubmittable(let message) {
            XCTAssertEqual(message, "unparseable")
        }

        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 0)
    }

    func testEncoderSubmitsAValidTransactionOnce() async throws {
        let encoder = try makeEncoder()

        try await encoder.submit(transaction: EncodedTransaction(transactionId: txId, raw: raw))

        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 1)
        XCTAssertEqual(service.submitSpendTransactionModeReceivedArguments?.spendTransaction, raw)
        XCTAssertEqual(service.latestBlockHeightModeCallsCount, 1, "one height read per submission")
        XCTAssertEqual(backend.checkTransactionSubmittableSubmissionServerHeightCallsCount, 1)
    }

    func testEncoderJudgesTheTransactionAtTheServersHeight() async throws {
        service.latestBlockHeightModeReturnValue = 3_543_000
        let encoder = try makeEncoder()

        try await encoder.submit(transaction: EncodedTransaction(transactionId: txId, raw: raw))

        let received = try XCTUnwrap(backend.checkTransactionSubmittableSubmissionServerHeightReceivedArguments)
        XCTAssertEqual(received.rawTransaction, raw)
        XCTAssertEqual(received.submissionServerHeight, 3_543_000)
    }

    func testEncoderReadsTheHeightInTheModeItSubmitsIn() async throws {
        for torEnabled in [false, true] {
            let service = LightWalletServiceMock()
            service.latestBlockHeightModeReturnValue = 3_543_404
            service.submitSpendTransactionModeReturnValue = SendResponse()
            let encoder = try makeEncoder(service: service, torEnabled: torEnabled)

            try await encoder.submit(transaction: EncodedTransaction(transactionId: txId, raw: raw))

            // With Tor the transaction has a circuit group of its own, and both requests use it.
            let expected = torEnabled ? ServiceMode.txIdGroup(prefix: "submit", txId: txId) : ServiceMode.direct
            XCTAssertEqual(service.latestBlockHeightModeReceivedMode, expected, "torEnabled: \(torEnabled)")
            XCTAssertEqual(service.submitSpendTransactionModeReceivedArguments?.mode, expected, "torEnabled: \(torEnabled)")
        }
    }

    func testEncoderStillReportsAServerRejection() async throws {
        service.submitSpendTransactionModeReturnValue = LightWalletServiceMockResponse.submitAnswer(errorCode: -25, errorMessage: "rejected")
        let encoder = try makeEncoder()

        do {
            try await encoder.submit(transaction: EncodedTransaction(transactionId: txId, raw: raw))
            XCTFail("Expected the server's rejection")
        } catch let TransactionEncoderError.submitError(code, message) {
            XCTAssertEqual(code, -25)
            XCTAssertEqual(message, "rejected")
        }
    }

    // MARK: - The streams built on the sink

    func testSubmitTransactionsMapsARefusalToSubmitFailure() async throws {
        let first = makeCreatedTransaction(seed: 0x01)
        let second = makeCreatedTransaction(seed: 0x02)
        backend.checkTransactionSubmittableSubmissionServerHeightClosure = { raw, _ in
            raw == first.raw ? TransactionSubmissionRefusal.wrongConsensusBranch : nil
        }
        stubUnexpectedServerProbe(on: service)
        let synchronizer = try makeSDKSynchronizer()

        let results = try await collect(synchronizer.submitTransactions([first, second]))

        XCTAssertEqual(
            results,
            [
                .submitFailure(txId: first.txId, code: -9101, description: TransactionSubmissionRefusal.wrongConsensusBranch.description),
                .notAttempted(txId: second.txId)
            ]
        )
        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 0)
        XCTAssertEqual(service.fetchTransactionTxIdModeCallsCount, 0, "nothing was sent, so there is nothing to ask the server about")
    }

    func testSubmitTransactionsReportsAnExpiredTransactionUnderItsOwnCode() async throws {
        let transaction = makeCreatedTransaction(seed: 0x01)
        backend.checkTransactionSubmittableSubmissionServerHeightReturnValue = .expired
        let synchronizer = try makeSDKSynchronizer()

        let results = try await collect(synchronizer.submitTransactions([transaction]))

        XCTAssertEqual(
            results,
            [.submitFailure(txId: transaction.txId, code: -9102, description: TransactionSubmissionRefusal.expired.description)]
        )
    }

    func testSubmitTransactionsSubmitsValidTransactionsAsBefore() async throws {
        let first = makeCreatedTransaction(seed: 0x01)
        let second = makeCreatedTransaction(seed: 0x02)
        let synchronizer = try makeSDKSynchronizer()

        let results = try await collect(synchronizer.submitTransactions([first, second]))

        XCTAssertEqual(results, [.success(txId: first.txId), .success(txId: second.txId)])
        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 2)
        XCTAssertEqual(service.latestBlockHeightModeCallsCount, 2, "each transaction is judged at the height read for it")
    }

    /// The height is the first request of a submission, so a server that cannot be asked for it is a server that cannot be
    /// reached: the stream reports it as it always reported that, as a `.grpcFailure` for the transaction, with the ones after it
    /// not attempted. A throw would end the stream without a result for transactions the wallet has already stored, and a caller
    /// that shows a throw as "the send failed" invites the user to pay again while the original goes out in a later pass.
    func testSubmitTransactionsReportsAnUnreadableHeightAsAGrpcFailure() async throws {
        let first = makeCreatedTransaction(seed: 0x01)
        let second = makeCreatedTransaction(seed: 0x02)
        service.latestBlockHeightModeClosure = { _ in
            throw ZcashError.serviceLatestBlockHeightFailed(LightWalletServiceError.timeOut)
        }
        stubUnexpectedServerProbe(on: service)
        let synchronizer = try makeSDKSynchronizer()

        let results = try await collect(synchronizer.submitTransactions([first, second]))

        XCTAssertEqual(results, [.grpcFailure(txId: first.txId, error: .timeOut), .notAttempted(txId: second.txId)])
        assertNothingWasJudgedSubmittedOrAskedAbout(service: service, readsOfTheHeight: 1)
    }

    func testSubmitTransactionsReportsAnyOtherHeightReadErrorAsAGrpcFailureToo() async throws {
        let first = makeCreatedTransaction(seed: 0x01)
        let second = makeCreatedTransaction(seed: 0x02)
        let torError = ZcashError.rustTorLwdLatestBlockHeight("no circuit")
        service.latestBlockHeightModeClosure = { _ in throw torError }
        stubUnexpectedServerProbe(on: service)
        let synchronizer = try makeSDKSynchronizer()

        let results = try await collect(synchronizer.submitTransactions([first, second]))

        try assertTorReadFailureThenNotAttempted(results, first: first, second: second, torError: torError)
        assertNothingWasJudgedSubmittedOrAskedAbout(service: service, readsOfTheHeight: 1)
    }

    /// A transaction the check cannot judge (it does not parse, the wallet database is missing) is another thing than a server
    /// that cannot be reached: no retry fixes it, and it keeps ending the stream with its own error.
    func testSubmitTransactionsPropagatesATransactionTheCheckCannotJudge() async throws {
        backend.checkTransactionSubmittableSubmissionServerHeightThrowableError = ZcashError.rustCheckTransactionSubmittable("unparseable")
        stubUnexpectedServerProbe(on: service)
        let synchronizer = try makeSDKSynchronizer()

        do {
            _ = try await collect(synchronizer.submitTransactions([makeCreatedTransaction(seed: 0x01)]))
            XCTFail("A transaction that cannot be judged must not be mistaken for a submittable one")
        } catch ZcashError.rustCheckTransactionSubmittable(let message) {
            XCTAssertEqual(message, "unparseable")
        }

        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 0)
        XCTAssertEqual(service.fetchTransactionTxIdModeCallsCount, 0)
    }

    func testSlipstreamSubmitTransactionsMapsARefusalToSubmitFailure() async throws {
        let first = makeCreatedTransaction(seed: 0x01)
        let second = makeCreatedTransaction(seed: 0x02)
        backend.checkTransactionSubmittableSubmissionServerHeightClosure = { raw, _ in
            raw == first.raw ? TransactionSubmissionRefusal.expired : nil
        }
        let synchronizer = try makeSlipstreamSynchronizer(creating: [first, second])

        let results = try await createProposedTransactions(with: synchronizer)

        XCTAssertEqual(
            results,
            [
                .submitFailure(txId: first.txId, code: -9102, description: TransactionSubmissionRefusal.expired.description),
                .notAttempted(txId: second.txId)
            ]
        )
        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 0)
        XCTAssertEqual(service.fetchTransactionTxIdModeCallsCount, 0)
    }

    func testSlipstreamSubmitTransactionsReportsAnUnreadableHeightAsAGrpcFailure() async throws {
        let first = makeCreatedTransaction(seed: 0x01)
        let second = makeCreatedTransaction(seed: 0x02)
        service.latestBlockHeightModeClosure = { _ in
            throw ZcashError.serviceLatestBlockHeightFailed(LightWalletServiceError.timeOut)
        }
        let synchronizer = try makeSlipstreamSynchronizer(creating: [first, second])

        let results = try await createProposedTransactions(with: synchronizer)

        XCTAssertEqual(results, [.grpcFailure(txId: first.txId, error: .timeOut), .notAttempted(txId: second.txId)])
        assertNothingWasJudgedSubmittedOrAskedAbout(service: service, readsOfTheHeight: 1)
    }

    func testSlipstreamSubmitTransactionsReportsAnyOtherHeightReadErrorAsAGrpcFailureToo() async throws {
        let first = makeCreatedTransaction(seed: 0x01)
        let second = makeCreatedTransaction(seed: 0x02)
        let torError = ZcashError.rustTorLwdLatestBlockHeight("no circuit")
        service.latestBlockHeightModeClosure = { _ in throw torError }
        let synchronizer = try makeSlipstreamSynchronizer(creating: [first, second])

        let results = try await createProposedTransactions(with: synchronizer)

        try assertTorReadFailureThenNotAttempted(results, first: first, second: second, torError: torError)
        assertNothingWasJudgedSubmittedOrAskedAbout(service: service, readsOfTheHeight: 1)
    }

    func testSlipstreamSubmitTransactionsPropagatesATransactionTheCheckCannotJudge() async throws {
        backend.checkTransactionSubmittableSubmissionServerHeightThrowableError = ZcashError.rustCheckTransactionSubmittable("unparseable")
        let synchronizer = try makeSlipstreamSynchronizer(creating: [makeCreatedTransaction(seed: 0x01)])

        do {
            _ = try await createProposedTransactions(with: synchronizer)
            XCTFail("A transaction that cannot be judged must not be mistaken for a submittable one")
        } catch ZcashError.rustCheckTransactionSubmittable(let message) {
            XCTAssertEqual(message, "unparseable")
        }

        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 0)
        XCTAssertEqual(service.fetchTransactionTxIdModeCallsCount, 0)
    }

    // MARK: - Helpers

    private func makeEncoder(service: LightWalletServiceMock? = nil, torEnabled: Bool = false) throws -> WalletTransactionEncoder {
        WalletTransactionEncoder(
            rustBackend: backend,
            dataDb: try __dataDbURL(),
            fsBlockDbRoot: testTempDirectory,
            service: service ?? self.service,
            repository: TransactionRepositoryMock(),
            outputParams: try __outputParamsURL(),
            spendParams: try __spendParamsURL(),
            networkType: .testnet,
            logger: submissionLifecycleLogger(),
            sdkFlags: SDKFlags(torEnabled: torEnabled, exchangeRateEnabled: false)
        )
    }

    private func makeSDKSynchronizer() throws -> SDKSynchronizer {
        SDKSynchronizer(initializer: try makeInitializer(repository: TransactionRepositoryMock()))
    }

    /// An initializer over the test's stubbed service and check, from which both synchronizers build the real
    /// `WalletTransactionEncoder`.
    private func makeInitializer(repository: TransactionRepositoryMock) throws -> Initializer {
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in self.backend }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in self.service }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in repository }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in submissionLifecycleLogger() }

        return Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
    }

    /// A `SlipstreamSynchronizer` whose `createProposedTransactions` creates `transactions` and submits them through the real
    /// `WalletTransactionEncoder` over the test's stubbed service and check. The server is asked nothing it could answer, so that
    /// a probe the SDK should not make is counted by the test instead of crashing it on the mock's unstubbed answer.
    private func makeSlipstreamSynchronizer(creating transactions: [CreatedTransaction]) throws -> SlipstreamSynchronizer {
        backend.createProposedTransactionsProposalUskOvkPolicyReturnValue = transactions.map(\.txId)
        backend.getTransactionTxIdClosure = { txId in
            TransactionData(txId: txId, raw: transactions.first { $0.txId == txId }?.raw ?? Data(), expiryHeight: 3_600_000)
        }
        stubUnexpectedServerProbe(on: service)
        let repository = TransactionRepositoryMock()
        // The enrichment of the created transactions from the history view finds nothing, and carries on.
        repository.findRawIDThrowableError = ZcashError.transactionRepositoryEntityNotFound

        return SlipstreamSynchronizer(
            initializer: try makeInitializer(repository: repository),
            alternateEndpoints: [],
            engine: GatedFakeSlipstreamEngine()
        )
    }

    private func createProposedTransactions(with synchronizer: SlipstreamSynchronizer) async throws -> [TransactionSubmitResult] {
        let stream = try await synchronizer.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        return try await collect(stream)
    }

    /// The Tor connection's error is not a `LightWalletServiceError` and does not compare, so the result is taken apart.
    private func assertTorReadFailureThenNotAttempted(
        _ results: [TransactionSubmitResult],
        first: CreatedTransaction,
        second: CreatedTransaction,
        torError: ZcashError
    ) throws {
        XCTAssertEqual(results.count, 2)
        guard case let .grpcFailure(txId, error) = try XCTUnwrap(results.first), case let .genericError(underlying) = error else {
            XCTFail("Expected a grpcFailure with a generic service error but got \(results)")
            return
        }
        XCTAssertEqual(txId, first.txId)
        XCTAssertEqual(underlying as? ZcashError, torError)
        XCTAssertEqual(results.last, .notAttempted(txId: second.txId))
    }

    /// A read of the height that failed leaves nothing to judge a transaction by, to submit it to, or to ask the server about.
    private func assertNothingWasJudgedSubmittedOrAskedAbout(
        service: LightWalletServiceMock,
        readsOfTheHeight: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(service.latestBlockHeightModeCallsCount, readsOfTheHeight, file: file, line: line)
        XCTAssertEqual(
            backend.checkTransactionSubmittableSubmissionServerHeightCallsCount,
            0,
            "nothing is judged against a guess",
            file: file,
            line: line
        )
        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 0, file: file, line: line)
        XCTAssertEqual(
            service.fetchTransactionTxIdModeCallsCount,
            0,
            "nothing was sent, so there is nothing to ask the server about",
            file: file,
            line: line
        )
    }

    private func makeCreatedTransaction(seed: UInt8) -> CreatedTransaction {
        CreatedTransaction(
            txId: Data(repeating: seed, count: 32),
            raw: Data([0x05, 0x00, 0x00, 0x80, seed]),
            expiryHeight: 3_600_000
        )
    }

    /// A server that is asked whether it knows a transaction answers that it does not, so that a probe the SDK should not have
    /// made is counted by the test instead of crashing it on the mock's unstubbed answer.
    private func stubUnexpectedServerProbe(on service: LightWalletServiceMock) {
        service.fetchTransactionTxIdModeClosure = { _, _ in (tx: nil, status: TransactionStatus.txidNotRecognized) }
    }

    private func collect(_ stream: AsyncThrowingStream<TransactionSubmitResult, Error>) async throws -> [TransactionSubmitResult] {
        var results: [TransactionSubmitResult] = []
        for try await result in stream {
            results.append(result)
        }
        return results
    }
}

/// The check through the real libzcashlc. The transactions are the wire encodings of empty ones, built by
/// `rust/src/lib.rs`'s tests with librustzcash: v6 for NU6.3 and NU7, v5 for NU6.3, and v4. Mainnet activates
/// NU7 at 3,543,405, so the next block is under NU6.3 up to a server at 3,543,403 and under NU7 from a server at
/// 3,543,404 on.
final class TransactionSubmittabilityFFITests: ZcashTestCase {
    /// v6, built for NU6.3, expiring at 3,594,240.
    private let v6Nu63 = TransactionSubmittabilityFFITests.data(hex: "0600008098b684d85b16a5370000000000d83600000000000000")
    /// v6, built for NU7, expiring at 3,600,000.
    private let v6Nu7 = TransactionSubmittabilityFFITests.data(hex: "0600008098b684d8d90a19770000000080ee3600000000000000")
    /// v5, built for NU6.3, expiring at 3,594,240.
    private let v5Nu63 = TransactionSubmittabilityFFITests.data(hex: "050000800a27a7265b16a5370000000000d836000000000000")
    /// v4, which commits to no consensus branch, expiring at 3,600,000.
    private let v4 = TransactionSubmittabilityFFITests.data(hex: "0400008085202f8900000000000080ee36000000000000000000000000")

    private var backend: ZcashRustBackend!

    override func setUp() async throws {
        try await super.setUp()
        backend = ZcashRustBackend.makeForTests(
            dbData: testTempDirectory.appendingPathComponent("data.db"),
            fsBlockDbRoot: testTempDirectory,
            networkType: .mainnet
        )
        let dbInit = try await backend.initDataDb(seed: nil)
        guard case .success = dbInit else {
            XCTFail("Failed to initDataDb. Expected `.success`, got \(String(describing: dbInit))")
            return
        }
        try await backend.updateChainTip(height: 3_543_000)
    }

    func testTheBackendJudgesATransactionAgainstTheNextBlock() async throws {
        let ok = try await backend.checkTransactionSubmittable(v6Nu63, submissionServerHeight: 3_543_403)
        XCTAssertNil(ok)

        let wrongBranch = try await backend.checkTransactionSubmittable(v6Nu63, submissionServerHeight: 3_543_404)
        XCTAssertEqual(wrongBranch, .wrongConsensusBranch)

        let nu7Early = try await backend.checkTransactionSubmittable(v6Nu7, submissionServerHeight: 3_543_403)
        XCTAssertEqual(nu7Early, .wrongConsensusBranch, "a transaction built for NU7 is as wrong before the activation")

        let nu7 = try await backend.checkTransactionSubmittable(v6Nu7, submissionServerHeight: 3_599_999)
        XCTAssertNil(nu7)

        let expired = try await backend.checkTransactionSubmittable(v6Nu7, submissionServerHeight: 3_600_000)
        XCTAssertEqual(expired, .expired)
    }

    func testTheBackendComparesTheBranchOnlyForV5AndLater() async throws {
        let v5 = try await backend.checkTransactionSubmittable(v5Nu63, submissionServerHeight: 3_543_404)
        XCTAssertEqual(v5, .wrongConsensusBranch)

        let v4Later = try await backend.checkTransactionSubmittable(v4, submissionServerHeight: 3_543_404)
        XCTAssertNil(v4Later, "v4 commits to no branch, and has not expired")

        let v4Expired = try await backend.checkTransactionSubmittable(v4, submissionServerHeight: 3_600_000)
        XCTAssertEqual(v4Expired, .expired)
    }

    func testTheBackendUsesTheWalletTipWhenItIsHigher() async throws {
        let before = try await backend.checkTransactionSubmittable(v6Nu63, submissionServerHeight: 3_543_000)
        XCTAssertNil(before)

        try await backend.updateChainTip(height: 3_543_404)

        let after = try await backend.checkTransactionSubmittable(v6Nu63, submissionServerHeight: 3_543_000)
        XCTAssertEqual(after, .wrongConsensusBranch)
    }

    func testTheBackendAcceptsAValidTransactionBeforeActivation() async throws {
        // The next block still accepts the transaction's NU6.3 consensus branch.
        let refusal = try await backend.checkTransactionSubmittable(v6Nu63, submissionServerHeight: 3_543_356)
        XCTAssertNil(refusal)
    }

    func testTheBackendFailsClosedOnAnUnknownServerHeight() async throws {
        for height in [-1, Int(Int32.min)] {
            do {
                _ = try await backend.checkTransactionSubmittable(v6Nu63, submissionServerHeight: height)
                XCTFail("A server height of \(height) cannot be judged by")
            } catch ZcashError.rustCheckTransactionSubmittable(let message) {
                XCTAssertTrue(message.contains("unknown"), message)
            }
        }
    }

    func testTheBackendFailsClosedOnBytesThatAreNoTransaction() async throws {
        for bytes in [Data(), Data([0x00, 0x00, 0x00]), v6Nu63.dropLast()] {
            do {
                _ = try await backend.checkTransactionSubmittable(bytes, submissionServerHeight: 3_543_403)
                XCTFail("\(bytes.count) bytes are no transaction")
            } catch let error as ZcashError {
                XCTAssertEqual(error.code.rawValue, "ZRUST0163")
            }
        }
    }

    func testTheBackendFailsClosedWithoutAWalletDatabaseAndCreatesNone() async throws {
        let missing = testTempDirectory.appendingPathComponent("missing.db")
        let backend = ZcashRustBackend.makeForTests(dbData: missing, fsBlockDbRoot: testTempDirectory, networkType: .mainnet)

        do {
            _ = try await backend.checkTransactionSubmittable(v6Nu63, submissionServerHeight: 3_543_403)
            XCTFail("Without a wallet database there is no tip to judge by")
        } catch ZcashError.rustCheckTransactionSubmittable {
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "the check must not create a wallet database")
    }

    private static func data(hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
            index = next
        }
        return data
    }
}
