//
//  BlockEnhancerImplTests.swift
//
//  Verifies that `BlockEnhancerImpl.enhance` invokes its `didEnhance` callback when a sent
//  transaction transitions from unmined to mined. That callback is the sole upstream producer of
//  `SynchronizerEvent.minedTransaction` (via `EnhanceAction`), and it had not been invoked since
//  the adoption of transaction data requests — silently killing the event in production and
//  leaving wallet UIs to discover a mined transaction only by chance.
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// A tiny thread-safe counter — the generated mock closures are not isolated, so a captured
/// mutable `var` would be unsafe under concurrent access.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

final class BlockEnhancerImplTests: XCTestCase {
    private let rawID = Data(fromHexEncodedString: "90058596ae18adedfd74681aee3812c2a7d3d361934347fb05550c77b677a615")!

    private func makeOverview(minedHeight: BlockHeight?, value: Zatoshi) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
            accountUUID: TestsData.mockedAccountUUID,
            blockTime: 1.0,
            expiryHeight: 663206,
            fee: Zatoshi(10),
            index: 1,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: minedHeight,
            raw: Data(),
            rawID: rawID,
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: value,
            isExpiredUmined: false,
            totalSpent: nil,
            totalReceived: nil,
            spentNoteCount: 1,
            poolCrossingValue: nil,
            isTrusted: false,
            zip318Kind: .notClassified
        )
    }

    private func makeEnhancer(
        rustBackend: ZcashRustBackendWeldingMock,
        downloader: BlockDownloaderServiceMock,
        repository: TransactionRepositoryMock,
        service: LightWalletServiceMock = LightWalletServiceMock(),
        torEnabled: Bool = false
    ) -> BlockEnhancerImpl {
        BlockEnhancerImpl(
            blockDownloaderService: downloader,
            rustBackend: rustBackend,
            transactionRepository: repository,
            metrics: SDKMetricsImpl(),
            service: service,
            logger: OSLogger(logLevel: .debug),
            sdkFlags: SDKFlags(torEnabled: torEnabled, exchangeRateEnabled: false),
            dataDb: URL(fileURLWithPath: "/tmp/data.db"),
            networkType: .testnet
        )
    }

    /// A GetStatus request answered `.mined` must report the (by definition newly mined) sent
    /// transaction through `didEnhance` with `newlyMined: true`.
    func testGetStatusMinedAnswerReportsNewlyMinedSentTransaction() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let downloader = BlockDownloaderServiceMock()
        let repository = TransactionRepositoryMock()

        rustBackend.transactionDataRequestsReturnValue = [.getStatus(rawID.bytes)]
        rustBackend.setTransactionStatusTxIdStatusClosure = { _, _ in }
        downloader.fetchTransactionTxIdModeClosure = { [rawID] _, _ in
            (tx: ZcashTransaction.Fetched(rawID: rawID, minedHeight: 663188, raw: Data([0x01])), status: .mined(663188))
        }
        repository.findRawIDReturnValue = makeOverview(minedHeight: 663188, value: Zatoshi(-100_000))
        repository.findInLimitKindReturnValue = []

        var reported: [EnhancementProgress] = []
        _ = try await makeEnhancer(rustBackend: rustBackend, downloader: downloader, repository: repository)
            .enhance(at: 663100...663200) { progress in
                reported.append(progress)
            }

        XCTAssertEqual(reported.count, 1, "exactly one newly-mined report is expected")
        XCTAssertEqual(reported.first?.newlyMined, true)
        XCTAssertEqual(reported.first?.lastFoundTransaction?.rawID, rawID)
        XCTAssertTrue(rustBackend.setTransactionStatusTxIdStatusCalled)
    }

    /// A GetStatus request answered "not recognized" must not produce any report.
    func testGetStatusNotRecognizedReportsNothing() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let downloader = BlockDownloaderServiceMock()
        let repository = TransactionRepositoryMock()

        rustBackend.transactionDataRequestsReturnValue = [.getStatus(rawID.bytes)]
        rustBackend.setTransactionStatusTxIdStatusClosure = { _, status in
            guard case .txidNotRecognized = status else {
                XCTFail("status is expected to be .txidNotRecognized but was \(status)")
                return
            }
        }
        downloader.fetchTransactionTxIdModeClosure = { _, _ in
            (tx: nil, status: .txidNotRecognized)
        }
        repository.findInLimitKindReturnValue = []

        var reported: [EnhancementProgress] = []
        _ = try await makeEnhancer(rustBackend: rustBackend, downloader: downloader, repository: repository)
            .enhance(at: 663100...663200) { progress in
                reported.append(progress)
            }

        XCTAssertTrue(reported.isEmpty, "no report is expected for an unrecognized txid")
        XCTAssertTrue(rustBackend.setTransactionStatusTxIdStatusCalled)
    }

    /// Enhancing a transaction the wallet already knows as mined must not produce a duplicate
    /// newly-mined report — the callback means a transition, not a state.
    func testEnhancementOfAlreadyMinedTransactionReportsNothing() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let downloader = BlockDownloaderServiceMock()
        let repository = TransactionRepositoryMock()

        rustBackend.transactionDataRequestsReturnValue = [.enhancement(rawID.bytes)]
        rustBackend.decryptAndStoreTransactionTxBytesMinedHeightClosure = { _, _ in Data() }
        downloader.fetchTransactionTxIdModeClosure = { [rawID] _, _ in
            (tx: ZcashTransaction.Fetched(rawID: rawID, minedHeight: 663188, raw: Data([0x01])), status: .mined(663188))
        }
        // Already mined BEFORE the enhancement stores anything.
        repository.findRawIDReturnValue = makeOverview(minedHeight: 663188, value: Zatoshi(-100_000))
        repository.findInLimitKindReturnValue = []

        var reported: [EnhancementProgress] = []
        _ = try await makeEnhancer(rustBackend: rustBackend, downloader: downloader, repository: repository)
            .enhance(at: 663100...663200) { progress in
                reported.append(progress)
            }

        XCTAssertTrue(reported.isEmpty, "an already-mined transaction must not be reported as newly mined")
    }

    /// Enhancing a transaction that transitions nil→mined must produce exactly one report for a
    /// sent transaction.
    func testEnhancementNilToMinedTransitionReportsSentTransaction() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let downloader = BlockDownloaderServiceMock()
        let repository = TransactionRepositoryMock()

        rustBackend.transactionDataRequestsReturnValue = [.enhancement(rawID.bytes)]
        rustBackend.decryptAndStoreTransactionTxBytesMinedHeightClosure = { _, _ in Data() }
        downloader.fetchTransactionTxIdModeClosure = { [rawID] _, _ in
            (tx: ZcashTransaction.Fetched(rawID: rawID, minedHeight: 663188, raw: Data([0x01])), status: .mined(663188))
        }
        // First lookup (pre-store): unmined. Second lookup (post-store): mined.
        let unmined = makeOverview(minedHeight: nil, value: Zatoshi(-100_000))
        let mined = makeOverview(minedHeight: 663188, value: Zatoshi(-100_000))
        let findCalls = CallCounter()
        repository.findRawIDClosure = { _ in
            findCalls.next() == 1 ? unmined : mined
        }
        repository.findInLimitKindReturnValue = []

        var reported: [EnhancementProgress] = []
        _ = try await makeEnhancer(rustBackend: rustBackend, downloader: downloader, repository: repository)
            .enhance(at: 663100...663200) { progress in
                reported.append(progress)
            }

        XCTAssertEqual(reported.count, 1, "exactly one newly-mined report is expected")
        XCTAssertEqual(reported.first?.newlyMined, true)
        XCTAssertEqual(reported.first?.lastFoundTransaction?.rawID, rawID)
    }

    /// A throwing `setTransactionStatus` (now surfaced instead of silently swallowed at the FFI
    /// boundary) must not crash or abort the run, and must not produce a newly-mined report. The
    /// retry loop covers the post-fetch write, so a write that keeps failing is attempted
    /// `maxRetries` times within the cycle and then logged as exhausted; because the failed write
    /// leaves the data request pending in the backend, the next enhance cycle retries it again.
    func testThrowingSetTransactionStatusIsRetriedWithoutCrashing() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let downloader = BlockDownloaderServiceMock()
        let repository = TransactionRepositoryMock()

        rustBackend.transactionDataRequestsReturnValue = [.getStatus(rawID.bytes)]
        rustBackend.setTransactionStatusTxIdStatusClosure = { _, _ in
            throw ZcashError.rustSetTransactionStatus("mocked failure")
        }
        downloader.fetchTransactionTxIdModeClosure = { [rawID] _, _ in
            (tx: ZcashTransaction.Fetched(rawID: rawID, minedHeight: 663188, raw: Data([0x01])), status: .mined(663188))
        }
        repository.findInLimitKindReturnValue = []

        var reported: [EnhancementProgress] = []
        _ = try await makeEnhancer(rustBackend: rustBackend, downloader: downloader, repository: repository)
            .enhance(at: 663100...663200) { progress in
                reported.append(progress)
            }

        XCTAssertTrue(reported.isEmpty, "a failed status write must not produce a newly-mined report")
        XCTAssertEqual(
            rustBackend.setTransactionStatusTxIdStatusCallsCount,
            5,
            "a failing status write is retried up to maxRetries within the cycle before being logged as exhausted"
        )
    }

    // MARK: - Transparent-address history

    private let transparentAddress = "t1dRJRY7GmyeykJnMH38mdQoaZtFhn1QmGz"

    private func makeAddressRequestBody(
        blockRangeEnd: UInt32? = 663201,
        requestAt: Date? = nil,
        outputStatusFilter: OutputStatusFilter = .all
    ) -> TransactionsInvolvingAddress {
        TransactionsInvolvingAddress(
            address: transparentAddress,
            blockRangeStart: 663100,
            blockRangeEnd: blockRangeEnd,
            requestAt: requestAt,
            txStatusFilter: .mined,
            outputStatusFilter: outputStatusFilter
        )
    }

    private func makeAddressRequest() -> TransactionDataRequest {
        .transactionsInvolvingAddress(makeAddressRequestBody())
    }

    func testLastHeightConvertsTheExclusiveEndToTheServersInclusiveEnd() {
        XCTAssertEqual(BlockEnhancerImpl.lastHeight(of: makeAddressRequestBody(blockRangeEnd: 663201)), 663200)
        XCTAssertNil(BlockEnhancerImpl.lastHeight(of: makeAddressRequestBody(blockRangeEnd: nil)))
    }

    /// Request shapes the enhancer cannot serve yet are reported as unhandled without touching
    /// either transport, so the backend can re-issue them later.
    func testUnsupportedAddressRequestShapesFetchNothing() async throws {
        let unsupported: [TransactionsInvolvingAddress] = [
            makeAddressRequestBody(blockRangeEnd: nil),
            makeAddressRequestBody(requestAt: Date()),
            makeAddressRequestBody(outputStatusFilter: .unspent)
        ]

        for request in unsupported {
            let service = LightWalletServiceMock()
            let enhancer = makeEnhancer(
                rustBackend: ZcashRustBackendWeldingMock(),
                downloader: BlockDownloaderServiceMock(),
                repository: TransactionRepositoryMock(),
                service: service,
                torEnabled: true
            )

            let handled = try await enhancer.fetchTransactionsInvolvingAddress(request)

            XCTAssertFalse(handled)
            XCTAssertFalse(service.getTaddressTransactionsModeCalled)
            XCTAssertFalse(service.updateTransparentAddressTransactionsAddressStartEndDbDataNetworkTypeModeCalled)
        }
    }

    /// With Tor enabled the address history must be fetched and stored through the FFI's Tor path,
    /// on a circuit dedicated to that address, and the direct gRPC stream must never be opened.
    func testAddressHistoryGoesOverTorWhenEnabled() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let downloader = BlockDownloaderServiceMock()
        let repository = TransactionRepositoryMock()
        let service = LightWalletServiceMock()

        rustBackend.transactionDataRequestsReturnValue = [makeAddressRequest()]
        repository.findInLimitKindReturnValue = []
        service.updateTransparentAddressTransactionsAddressStartEndDbDataNetworkTypeModeClosure = { _, _, _, _, _, _ in .notFound }

        _ = try await makeEnhancer(rustBackend: rustBackend, downloader: downloader, repository: repository, service: service, torEnabled: true)
            .enhance(at: 663100...663200) { _ in }

        XCTAssertFalse(service.getTaddressTransactionsModeCalled, "the direct gRPC stream must not be used with Tor enabled")
        XCTAssertEqual(service.updateTransparentAddressTransactionsAddressStartEndDbDataNetworkTypeModeCallsCount, 1)

        let arguments = try XCTUnwrap(service.updateTransparentAddressTransactionsAddressStartEndDbDataNetworkTypeModeReceivedArguments)
        XCTAssertEqual(arguments.address, transparentAddress)
        XCTAssertEqual(arguments.start, 663100)
        XCTAssertEqual(arguments.end, 663200, "the request's exclusive end must become the server's inclusive end")
        XCTAssertEqual(arguments.networkType, .testnet)
        XCTAssertEqual(arguments.mode, .torInGroup("taddr-\(transparentAddress)"))
    }

    /// With Tor disabled the direct gRPC stream is still the path, and the Tor-only FFI entry point
    /// is left alone.
    func testAddressHistoryStaysDirectWhenTorDisabled() async throws {
        let rustBackend = ZcashRustBackendWeldingMock()
        let downloader = BlockDownloaderServiceMock()
        let repository = TransactionRepositoryMock()
        let service = LightWalletServiceMock()

        rustBackend.transactionDataRequestsReturnValue = [makeAddressRequest()]
        rustBackend.decryptAndStoreTransactionTxBytesMinedHeightClosure = { _, _ in Data() }
        repository.findInLimitKindReturnValue = []
        service.getTaddressTransactionsModeClosure = { _, _ in
            AsyncThrowingStream { continuation in
                var rawTransaction = RawTransaction()
                rawTransaction.data = Data([0x01])
                rawTransaction.height = 663150
                continuation.yield(rawTransaction)
                continuation.finish()
            }
        }

        _ = try await makeEnhancer(rustBackend: rustBackend, downloader: downloader, repository: repository, service: service, torEnabled: false)
            .enhance(at: 663100...663200) { _ in }

        XCTAssertEqual(service.getTaddressTransactionsModeCallsCount, 1)
        XCTAssertFalse(service.updateTransparentAddressTransactionsAddressStartEndDbDataNetworkTypeModeCalled)
        XCTAssertEqual(rustBackend.decryptAndStoreTransactionTxBytesMinedHeightCallsCount, 1)
    }
}
