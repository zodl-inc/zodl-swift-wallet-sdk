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
@testable import ZODLSwiftWalletSDK

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
        repository: TransactionRepositoryMock
    ) -> BlockEnhancerImpl {
        BlockEnhancerImpl(
            blockDownloaderService: downloader,
            rustBackend: rustBackend,
            transactionRepository: repository,
            metrics: SDKMetricsImpl(),
            service: LightWalletServiceMock(),
            logger: OSLogger(logLevel: .debug),
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
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
}
