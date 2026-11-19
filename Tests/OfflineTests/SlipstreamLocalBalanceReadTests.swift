//
//  SlipstreamLocalBalanceReadTests.swift
//  ZODLSwiftWalletSDK
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// The local-balance read is a blocking walk of the wallet database that holds a cooperative-pool
/// thread for as long as it runs, which is seconds on a wallet with a long history. When the app
/// returns to the foreground, several callers ask for balances at once; if each starts its own walk,
/// every cooperative thread ends up blocked and all other Swift work in the process stalls. These
/// tests pin the two properties that prevent that: concurrent callers share one read, and a caller
/// that only wants the visible balances does not read the local ones at all. They also pin the limit
/// on sharing: a read that began before a wallet change is not handed to callers that arrive after it.
final class SlipstreamLocalBalanceReadTests: ZcashTestCase {
    // MARK: - Fixture

    private let account = AccountUUID(id: [UInt8](repeating: 7, count: 16))

    private func balance(_ zatoshi: Int64) -> AccountBalance {
        AccountBalance(
            saplingBalance: PoolBalance(
                spendableValue: Zatoshi(zatoshi),
                changePendingConfirmation: .zero,
                valuePendingSpendability: .zero
            ),
            orchardBalance: .zero,
            unshielded: .zero
        )
    }

    private func walletSummary() -> WalletSummary {
        WalletSummary(
            accountBalances: [account: balance(100_000)],
            chainTipHeight: 3_000_000,
            fullyScannedHeight: 3_000_000,
            recoveryProgress: nil,
            scanProgress: nil,
            nextSaplingSubtreeIndex: 0,
            nextOrchardSubtreeIndex: 0,
            nextIronwoodSubtreeIndex: 0
        )
    }

    /// A synchronizer whose backend can read local balances, in a prepared state so
    /// `getLocalAccountBalances()` does not return early.
    private func makeSynchronizer(
        backend: GatedLocalBalanceBackend,
        engine: GatedFakeSlipstreamEngine = GatedFakeSlipstreamEngine()
    ) async throws -> SlipstreamSynchronizer {
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: backend)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        return sync
    }

    // MARK: - Concurrent callers share one read

    func testConcurrentLocalBalanceReadsShareOneWalk() async throws {
        let backend = GatedLocalBalanceBackend()
        backend.result = .success([account: balance(42_000)])
        let sync = try await makeSynchronizer(backend: backend)

        let callers = 6
        let reads = (0..<callers).map { _ in
            Task { try await sync.getLocalAccountBalances() }
        }

        let started = await waitUntil { backend.readCount == 1 }
        XCTAssertTrue(started, "the first caller should start a read")
        // A negative claim — that the other callers do not start reads of their own — needs a real
        // interval during which they could have; every caller has been scheduled well within it.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(backend.readCount, 1, "callers arriving while a read runs must wait for it")

        backend.release()
        for read in reads {
            let value = try await read.value
            XCTAssertEqual(value?[account]?.saplingBalance.spendableValue, Zatoshi(42_000))
        }
        XCTAssertEqual(backend.readCount, 1)
    }

    func testConcurrentLocalBalanceReadsShareOneError() async throws {
        let backend = GatedLocalBalanceBackend()
        backend.result = .failure(ZcashError.rustGetWalletSummary("fixture"))
        let sync = try await makeSynchronizer(backend: backend)

        let reads = (0..<3).map { _ in
            Task { try await sync.getLocalAccountBalances() }
        }
        let started = await waitUntil { backend.readCount == 1 }
        XCTAssertTrue(started)
        backend.release()

        for read in reads {
            do {
                _ = try await read.value
                XCTFail("every waiter should receive the shared read's error")
            } catch {
                XCTAssertEqual((error as? ZcashError)?.code, ZcashError.rustGetWalletSummary("").code)
            }
        }
        XCTAssertEqual(backend.readCount, 1)
    }

    /// The shared read is dropped once it finishes, so a later caller sees fresh balances rather
    /// than a result cached from an earlier read.
    func testReadAfterCompletionStartsANewWalk() async throws {
        let backend = GatedLocalBalanceBackend()
        backend.result = .success([account: balance(1_000)])
        backend.release()
        let sync = try await makeSynchronizer(backend: backend)

        let first = try await sync.getLocalAccountBalances()
        backend.result = .success([account: balance(2_000)])
        let second = try await sync.getLocalAccountBalances()

        XCTAssertEqual(backend.readCount, 2)
        XCTAssertEqual(first?[account]?.saplingBalance.spendableValue, Zatoshi(1_000))
        XCTAssertEqual(second?[account]?.saplingBalance.spendableValue, Zatoshi(2_000))
    }

    // MARK: - A wallet change ends the sharing

    /// A read that began before a wallet change reports the wallet as it was. A caller that arrives
    /// after the change must start its own read rather than join that one, while the caller already
    /// waiting on the old read still gets its result. `deleteAccount` stands in for the other wallet
    /// changes — `importAccount`, `rewind` and `wipe` — which drop the shared read the same way.
    func testReadStartedBeforeAWalletChangeIsNotSharedAfterIt() async throws {
        let backend = GatedLocalBalanceBackend()
        backend.deleteAccountClosure = { _ in }
        backend.result = .success([account: balance(1_000)])
        let sync = try await makeSynchronizer(backend: backend)

        let before = Task { try await sync.getLocalAccountBalances() }
        let firstStarted = await waitUntil { backend.readCount == 1 }
        XCTAssertTrue(firstStarted, "the first caller should start a read")

        try await sync.deleteAccount(account)
        backend.result = .success([:])

        let after = Task { try await sync.getLocalAccountBalances() }
        let secondStarted = await waitUntil { backend.readCount == 2 }
        XCTAssertTrue(secondStarted, "a caller arriving after the change must start its own read, not join the old one")

        backend.release()
        let beforeValue = try await before.value
        let afterValue = try await after.value
        XCTAssertEqual(beforeValue?[account]?.saplingBalance.spendableValue, Zatoshi(1_000))
        XCTAssertNil(afterValue?[account], "the deleted account must not appear in a read that began after the delete")
        XCTAssertEqual(backend.readCount, 2)
    }

    // MARK: - Visible balances do not pay for the local read

    func testAccountsBalancesDoesNotReadLocalBalances() async throws {
        let backend = GatedLocalBalanceBackend()
        backend.result = .success([account: balance(1)])
        backend.release()
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextWalletSummary(walletSummary())
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 1000, tipFresh: 1))
        let sync = try await makeSynchronizer(backend: backend, engine: engine)

        let balances = try await sync.getAccountsBalances()

        XCTAssertEqual(balances[account]?.saplingBalance.spendableValue, Zatoshi(100_000))
        XCTAssertEqual(backend.readCount, 0, "getAccountsBalances returns only visible balances")
    }
}

/// A rust-backend double that can read local balances, and holds every read until `release()` so a
/// test can observe how many reads are running at once.
private final class GatedLocalBalanceBackend: ZcashRustBackendWeldingMock, LocalBalanceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var storedResult: Result<[AccountUUID: AccountBalance], Error> = .success([:])

    var readCount: Int {
        lock.withLock { reads }
    }

    var result: Result<[AccountUUID: AccountBalance], Error> {
        get { lock.withLock { storedResult } }
        set { lock.withLock { storedResult = newValue } }
    }

    /// Lets every held read finish, and every later one run without waiting.
    func release() {
        let released = lock.withLock {
            isOpen = true
            let held = waiters
            waiters = []
            return held
        }
        released.forEach { $0.resume() }
    }

    /// Each read returns the `result` set when it started, as a SQLite read sees the database as of
    /// its own start, so a test can tell a read that began before a change from one that began after.
    func getLocalAccountBalances() async throws -> [AccountUUID: AccountBalance] {
        let snapshot = lock.withLock {
            reads += 1
            return storedResult
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if isOpen {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
        return try snapshot.get()
    }

    func getWalletSummaryWithLocalBalances() async throws -> (
        summary: WalletSummary?,
        localBalances: [AccountUUID: AccountBalance]
    ) {
        (nil, try await getLocalAccountBalances())
    }
}
