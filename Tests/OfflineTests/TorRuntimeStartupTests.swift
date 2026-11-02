import Foundation
import libzcashlc
import os
import XCTest
@testable import ZODLSwiftWalletSDK

final class TorRuntimeStartupTests: XCTestCase {
    func testTorRuntimeStartupDoesNotHoldActor() async throws {
        let entered = expectation(description: "bootstrap entered")
        let responsive = expectation(description: "actor responds during bootstrap")
        let release = DispatchSemaphore(value: 0)
        let runtimes = TorTestRuntimes()
        let native = TorHTTPGetNative(
            freeRuntime: { runtimes.free($0) },
            startup: TorRuntimeStartupNative.fixture { _, _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return runtimes.parent
            }
        )
        let client = TorClient(torDir: FileManager.default.temporaryDirectory, httpGetNative: native)
        let prepare = Task { try await client.prepare() }
        await fulfillment(of: [entered], timeout: 2)
        let probe = Task {
            await client.updateCachedFiatCurrencyResult(nil)
            responsive.fulfill()
        }
        await fulfillment(of: [responsive], timeout: 0.2)
        release.signal()
        try await prepare.value
        await probe.value
        try await client.close()
    }
    func testCloseCancelsBootstrapAndLateSuccessIsFreedOnce() async throws {
        let fixture = StartupFixture()
        let client = fixture.client()
        let prepare = Task { try await client.prepare() }
        await fulfillment(of: [fixture.entered], timeout: 2)
        try await client.close()
        await fulfillment(of: [fixture.cancelled], timeout: 2)
        fixture.release.signal()
        do {
            try await prepare.value
            XCTFail("Closed bootstrap must not publish a runtime")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [fixture.runtimeFreed], timeout: 2)
        XCTAssertEqual(fixture.counts, [1, 1, 1, 1])
        do {
            _ = try await client.httpGet(for: URLRequest(url: URL(string: "https://example.com")!), retryLimit: 0, timeoutMilliseconds: 100)
            XCTFail("Late success must remain unavailable")
        } catch { XCTAssertEqual(error as? ZcashError, ZcashError.torClientUnavailable) }
    }

    func testNativeCancellationCleanupDoesNotHoldActor() async throws {
        let fixture = StartupFixture()
        let cancelEntered = expectation(description: "native cancellation entered")
        let taken = expectation(description: "worker took result while cancel cleanup is gated")
        let closed = expectation(description: "close returns while native cancel disposes READY")
        let responsive = expectation(description: "actor responds during cancellation cleanup")
        let releaseCancel = DispatchSemaphore(value: 0)
        let events = OSAllocatedUnfairLock(initialState: [String]())
        var native = fixture.native
        let begin = native.begin
        let take = native.take
        let free = native.free
        native.begin = { bytes, remaining in
            let first = events.withLock { events in
                events.append("begin")
                return events.filter { $0 == "begin" }.count == 1
            }
            return first ? begin(bytes, remaining) : nil
        }
        native.cancel = { _ in
            events.withLock { $0.append("cancel-enter") }
            cancelEntered.fulfill()
            _ = releaseCancel.wait(timeout: .now() + 5)
            events.withLock { $0.append("cancel-exit") }
        }
        native.take = { pointer in
            let result = take(pointer)
            taken.fulfill()
            return result
        }
        native.free = { pointer in
            events.withLock { events in
                XCTAssertEqual(events.last, "cancel-exit", "Native free must wait for every cancel call")
                events.append("free")
            }
            free(pointer)
        }
        let client = fixture.client(startupNative: native)
        let prepare = Task { try await client.prepare() }
        await fulfillment(of: [fixture.entered], timeout: 2)
        let close = Task {
            try await client.close()
            closed.fulfill()
        }
        await fulfillment(of: [cancelEntered], timeout: 2)
        let probe = Task {
            try await client.close()
            await client.updateCachedFiatCurrencyResult(nil)
            responsive.fulfill()
        }
        await fulfillment(of: [closed, responsive], timeout: 0.2)
        fixture.release.signal()
        await fulfillment(of: [taken], timeout: 2)
        let nextPrepare = Task { try await client.prepare() }
        releaseCancel.signal()
        try await close.value
        try await probe.value
        do {
            try await prepare.value
            XCTFail("Closed bootstrap cannot be installed")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            try await nextPrepare.value
            XCTFail("Second synthetic begin deliberately fails")
        } catch { XCTAssertEqual((error as? ZcashError)?.code, ZcashError.rustTorClientInit("").code) }
        await fulfillment(of: [fixture.runtimeFreed], timeout: 2)
        XCTAssertEqual(events.withLock { $0 }, ["begin", "cancel-enter", "cancel-exit", "free", "begin"])
        XCTAssertEqual(fixture.counts, [1, 1, 1, 1])
    }

    func testDuplicatePrepareJoins() async throws {
        let fixture = StartupFixture()
        let registered = expectation(description: "both prepare interests registered")
        let client = fixture.client(startupInterestChanged: { count in
            if count == 2 { registered.fulfill() }
        })
        let first = Task { try await client.prepare() }
        await fulfillment(of: [fixture.entered], timeout: 2)
        let second = Task { try await client.prepare() }
        await fulfillment(of: [registered], timeout: 2)
        fixture.release.signal()
        try await first.value
        try await second.value
        XCTAssertEqual(fixture.counts, [1, 1, 1, 0])
        try await client.close()
        XCTAssertEqual(fixture.counts, [1, 1, 1, 1])
    }

    func testCallerCancellationReachesNativeBeforeWorkerReturns() async throws {
        let fixture = StartupFixture()
        let client = fixture.client()
        let prepare = Task { try await client.prepare() }
        await fulfillment(of: [fixture.entered], timeout: 2)
        prepare.cancel()
        await fulfillment(of: [fixture.cancelled], timeout: 2)
        fixture.release.signal()
        do {
            try await prepare.value
            XCTFail("Cancelled preparation must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [fixture.runtimeFreed], timeout: 2)
        XCTAssertEqual(fixture.counts, [1, 1, 1, 1])
    }

    func testShorterJoiningDeadlineDoesNotCancelExplicitOwner() async throws {
        let fixture = StartupFixture()
        fixture.cancelled.isInverted = true
        let client = fixture.client()
        let owner = Task { try await client.prepare() }
        await fulfillment(of: [fixture.entered], timeout: 2)
        let expired = expectation(description: "joining caller expires independently")
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000
        let joiner = Task {
            do {
                try await client.prepare(deadline: deadline)
                XCTFail("Joining request must respect its own shorter deadline")
            } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
            expired.fulfill()
        }
        await fulfillment(of: [expired, fixture.cancelled], timeout: 0.2)
        fixture.release.signal()
        await joiner.value
        try await owner.value
        XCTAssertEqual(fixture.counts, [1, 1, 1, 0])
        try await client.close()
    }

    func testCancelledInitiatingCallerKeepsJoiningExplicitPreparationAlive() async throws {
        let fixture = StartupFixture()
        fixture.cancelled.isInverted = true
        let startup = TorRuntimeStartup(
            directory: FileManager.default.temporaryDirectory,
            deadline: DispatchTime.now().uptimeNanoseconds + 60_000_000_000,
            native: fixture.native,
            freeRuntime: { fixture.runtimes.free($0) }
        )
        let initiatingID = try XCTUnwrap(startup.registerWaiter())
        let explicitID = try XCTUnwrap(startup.registerWaiter())
        let worker = Task { try await startup.run() }
        await fulfillment(of: [fixture.entered], timeout: 2)
        let waiter = TorRuntimeStartupWaiter { startup.releaseWaiter(initiatingID, cancelling: true) }
        let implicit = Task { try await waiter.wait(for: worker, deadline: startup.deadline) }
        implicit.cancel()
        do {
            try await implicit.value
            XCTFail("Cancelled initiating request must complete while bootstrap remains needed")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [fixture.cancelled], timeout: 0.05)
        fixture.release.signal()
        try await worker.value
        let runtime = try startup.claimRuntime()
        startup.releaseWaiter(explicitID, cancelling: false)
        XCTAssertEqual(fixture.counts, [1, 1, 1, 0])
        fixture.runtimes.free(runtime)
    }

    func testDeadlineIncludesWorkerQueue() async throws {
        let queue = DispatchQueue(label: "startup-test-queue")
        let entered = expectation(description: "worker queue occupied")
        let release = DispatchSemaphore(value: 0)
        queue.async {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        await fulfillment(of: [entered], timeout: 2)
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000))
        let fixture = StartupFixture()
        let startup = TorRuntimeStartup(
            directory: FileManager.default.temporaryDirectory,
            deadline: 6_000_000,
            native: fixture.native,
            freeRuntime: { _ in XCTFail("Expired queue must not create a runtime") },
            workerQueue: queue,
            now: { clock.withLock { $0 } }
        )
        let task = Task { try await startup.run() }
        clock.withLock { $0 = 6_000_000 }
        release.signal()
        do {
            _ = try await task.value
            XCTFail("Queue time consumes the original deadline")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(fixture.counts, [0, 0, 0, 0])
    }

    func testIsolatedClientSurvivesBaseClose() async throws {
        let fixture = StartupFixture()
        let client = fixture.client()
        let prepare = Task { try await client.prepare() }
        await fulfillment(of: [fixture.entered], timeout: 2)
        fixture.release.signal()
        try await prepare.value
        let isolated = try await client.isolatedClient()
        try await client.close()
        let response = try await isolated.httpGet(
            for: URLRequest(url: URL(string: "https://example.com")!), retryLimit: 0, timeoutMilliseconds: 500
        )
        XCTAssertEqual(response.data, Data([3, 1, 4]))
        try await isolated.close()
    }

    func testExpiredNativeSuccessCannotBeClaimed() async throws {
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000))
        let freed = expectation(description: "expired runtime disposed")
        let runtimes = TorTestRuntimes()
        let native = TorRuntimeStartupNative.fixture { _, _ in
            clock.withLock { $0 = 7_000_000 }
            return runtimes.parent
        }
        let startup = TorRuntimeStartup(
            directory: FileManager.default.temporaryDirectory,
            deadline: 6_000_000,
            native: native,
            freeRuntime: {
                runtimes.free($0)
                freed.fulfill()
            },
            now: { clock.withLock { $0 } }
        )
        do {
            try await startup.run()
            let runtime = try startup.claimRuntime()
            runtimes.free(runtime)
            freed.fulfill()
            XCTFail("Success after the shared deadline must not be published")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        startup.cancel()
        await fulfillment(of: [freed], timeout: 2)
    }

    func testSourceBuiltNativeZeroBudgetABI() async throws {
        let statuses: [UInt32] = await withCheckedContinuation { continuation in
            TorRuntimeStartup.workerQueue.async {
                let native = TorRuntimeStartupNative()
                let bytes = Array(FileManager.default.temporaryDirectory.path.utf8)
                guard let job = native.begin(bytes, 0) else {
                    XCTFail("Source-built startup ABI must admit a valid zero-budget job")
                    continuation.resume(returning: [])
                    return
                }
                let status = native.wait(job)
                native.cancel(job)
                let result = native.take(job)
                XCTAssertNil(result.runtime)
                native.free(job)
                continuation.resume(returning: [status, result.status])
            }
        }
        XCTAssertEqual(statuses, [3, 3])
    }

    func testSourceBuiltNativePendingCancellationABI() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tor-startup-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Native startup cleanup did not release its test directory: \(error)")
            }
        }

        let statuses: [UInt32] = await withCheckedContinuation { continuation in
            TorRuntimeStartup.workerQueue.async {
                let native = TorRuntimeStartupNative()
                let bytes = Array(directory.path.utf8)
                guard let job = native.begin(bytes, 5_000) else {
                    XCTFail("Source-built startup ABI must admit a valid pending job")
                    continuation.resume(returning: [])
                    return
                }
                native.cancel(job)
                let status = native.wait(job)
                let result = native.take(job)
                let returnedRuntime = result.runtime
                if let returnedRuntime {
                    zcashlc_free_tor_runtime(returnedRuntime)
                }
                native.free(job)
                XCTAssertNil(returnedRuntime)
                continuation.resume(returning: [status, result.status])
            }
        }
        XCTAssertEqual(statuses, [4, 4])
    }
}

private final class StartupFixture: @unchecked Sendable {
    let entered = XCTestExpectation(description: "native startup waiting")
    let cancelled = XCTestExpectation(description: "native cancellation delivered")
    let runtimeFreed = XCTestExpectation(description: "runtime freed")
    let release = DispatchSemaphore(value: 0)
    let runtimes = TorTestRuntimes()
    private let state = OSAllocatedUnfairLock(initialState: [0, 0, 0, 0])
    private let response = TorResponseFixture()

    var counts: [Int] { state.withLock { $0 } }

    var native: TorRuntimeStartupNative {
        TorRuntimeStartupNative(
            begin: { [self] _, remaining in
                XCTAssertGreaterThan(remaining, 0)
                state.withLock { $0[0] += 1 }
                return OpaquePointer(bitPattern: 0x1234)
            },
            cancel: { [self] _ in cancelled.fulfill() },
            wait: { [self] _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return 1
            },
            take: { [self] _ in
                state.withLock { $0[1] += 1 }
                return FfiTorStartupResultV1(status: 1, runtime: runtimes.parent)
            },
            free: { [self] _ in state.withLock { $0[2] += 1 } }
        )
    }

    func client(
        startupNative: TorRuntimeStartupNative? = nil,
        startupInterestChanged: @escaping @Sendable (Int) -> Void = { _ in }
    ) -> TorClient {
        let native = TorHTTPGetNative(
            get: { [self] pointer, _, _, _, _, _ in
                XCTAssertTrue(runtimes.isAlive(pointer))
                return response.pointer
            },
            freeResponse: { _ in },
            isolateRuntime: { [self] in runtimes.clone($0) },
            freeRuntime: { [self] pointer in
                runtimes.free(pointer)
                if pointer == runtimes.parent {
                    state.withLock { $0[3] += 1 }
                    runtimeFreed.fulfill()
                }
            },
            startup: startupNative ?? self.native
        )
        return TorClient(torDir: FileManager.default.temporaryDirectory, httpGetNative: native, startupInterestChanged: startupInterestChanged)
    }

    deinit {
        response.free()
        if runtimes.isAlive(runtimes.parent) { runtimes.free(runtimes.parent) }
    }
}
