import Foundation
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class TorHTTPAdmissionTests: ZcashTestCase {
    func testDeadlineCompletesWhileRootActorIsHeld() async throws {
        try await assertBlockedAdmission(entry: .root, cancel: false)
    }

    func testCancellationCompletesWhileRootActorIsHeld() async throws {
        try await assertBlockedAdmission(entry: .root, cancel: true)
    }

    func testAlreadyCancelledCallerCompletesWhileRootActorIsHeld() async throws {
        try await assertBlockedAdmission(entry: .root, cancel: true, alreadyCancelled: true)
    }

    func testDeadlineCompletesWhileClassicFlagsActorIsHeld() async throws {
        try await assertBlockedAdmission(entry: .classic, cancel: false)
    }

    func testCancellationCompletesWhileClassicFlagsActorIsHeld() async throws {
        try await assertBlockedAdmission(entry: .classic, cancel: true)
    }

    func testDeadlineCompletesWhileSlipstreamActorIsHeld() async throws {
        try await assertBlockedAdmission(entry: .slipstream, cancel: false)
    }

    func testCancellationCompletesWhileSlipstreamActorIsHeld() async throws {
        try await assertBlockedAdmission(entry: .slipstream, cancel: true)
    }

    func testCancellationDuringIsolationWaitsForCloneDisposal() async throws {
        try await assertIsolationTermination(cancel: true)
    }

    func testExpiryDuringIsolationSkipsGETAndWaitsForDisposal() async throws {
        try await assertIsolationTermination(cancel: false)
    }

    private func assertIsolationTermination(cancel: Bool) async throws {
        let fixture = TorAdmissionFixture()
        let isolating = expectation(description: "isolation started")
        let disposing = expectation(description: "clone disposal started")
        let releaseIsolation = DispatchSemaphore(value: 0)
        let releaseDisposal = DispatchSemaphore(value: 0)
        let completed = expectation(description: "must retain caller until disposal")
        completed.isInverted = true
        var native = fixture.native
        native.isolateRuntime = { pointer in
            isolating.fulfill()
            _ = releaseIsolation.wait(timeout: .now() + 5)
            return fixture.runtimes.clone(pointer)
        }
        native.freeRuntime = { pointer in
            if pointer != fixture.runtimes.parent {
                disposing.fulfill()
                _ = releaseDisposal.wait(timeout: .now() + 5)
            }
            fixture.runtimes.free(pointer)
        }
        let client = TorClient(runtimePtr: fixture.runtimes.parent, torDir: testTempDirectory, httpGetNative: native)
        let task = Task {
            defer { completed.fulfill() }
            return try await client.httpGet(for: request, retryLimit: 0, timeoutMilliseconds: cancel ? 10_000 : 50)
        }
        await fulfillment(of: [isolating], timeout: 3)
        if cancel {
            task.cancel()
            task.cancel()
        }
        await fulfillment(of: [completed], timeout: 0.1)
        releaseIsolation.signal()
        await fulfillment(of: [disposing], timeout: 3)
        XCTAssertEqual(fixture.gets, 0)
        releaseDisposal.signal()
        do {
            _ = try await task.value
            XCTFail("Terminated owner succeeded")
        } catch {
            if cancel { XCTAssertTrue(error is CancellationError) } else { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        }
        try await client.close()
    }

    func testActiveCancellationRetainsSharedClientSlotThroughDisposal() async throws {
        let fixture = TorAdmissionFixture()
        let otherFixture = TorAdmissionFixture()
        let clock = TorTestClock()
        let executor = TorHTTPRequestExecutor(sleepUntil: { try await clock.sleepUntil($0) })
        let first = TorWorkerGate()
        let second = TorWorkerGate()
        let third = TorWorkerGate()
        let disposing = expectation(description: "active clone disposing")
        let releaseDisposal = DispatchSemaphore(value: 0)
        let completed = expectation(description: "cancelled caller must wait for disposal")
        completed.isInverted = true
        var native = fixture.native
        native.get = { _, _, _, _, _, timeout in
            _ = try? first.run(timeout)
            return fixture.response.pointer
        }
        native.freeRuntime = { pointer in
            if pointer != fixture.runtimes.parent {
                disposing.fulfill()
                _ = releaseDisposal.wait(timeout: .now() + 5)
            }
            fixture.runtimes.free(pointer)
        }
        var otherNative = otherFixture.native
        otherNative.get = { _, _, _, _, _, timeout in
            _ = try? second.run(timeout)
            return otherFixture.response.pointer
        }
        let client = TorClient(runtimePtr: fixture.runtimes.parent, torDir: testTempDirectory, httpGetNative: native, httpExecutor: executor)
        let other = TorClient(runtimePtr: otherFixture.runtimes.parent, torDir: testTempDirectory, httpGetNative: otherNative, httpExecutor: executor)
        let task = Task {
            defer { completed.fulfill() }
            return try await client.httpGet(for: request, retryLimit: 0, timeoutMilliseconds: 10_000)
        }
        let otherTask = Task { try await other.httpGet(for: request, retryLimit: 0, timeoutMilliseconds: 10_000) }
        await fulfillment(of: [first.entered, second.entered], timeout: 3)
        task.cancel()
        task.cancel()
        first.release()
        await fulfillment(of: [disposing], timeout: 3)
        let thirdTask = Task { try await executor.execute(deadlineUptime: UInt64.max, operation: { try third.run($0) }) }
        await clock.waitForSleepers(1)
        XCTAssertEqual(third.entries, 0, "Disposal must retain the shared slot")
        await fulfillment(of: [completed], timeout: 0.05)
        releaseDisposal.signal()
        do {
            _ = try await task.value
            XCTFail("Cancelled active request succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [third.entered], timeout: 3)
        second.release()
        third.release()
        _ = try await otherTask.value
        _ = try await thirdTask.value
        try await client.close()
        try await other.close()
    }

    func testCancellationAfterWorkerCheckStillSkipsNativeGET() async throws {
        let fixture = TorAdmissionFixture()
        let read = TorAdmissionWorkerRead()
        let executor = TorHTTPRequestExecutor(now: { read.read() })
        let client = TorClient(runtimePtr: fixture.runtimes.parent, torDir: testTempDirectory, httpGetNative: fixture.native, httpExecutor: executor)
        let task = Task { try await client.httpGet(for: request, retryLimit: 0, timeoutMilliseconds: 10_000) }
        await fulfillment(of: [read.entered], timeout: 3)
        // The worker already read its task cancellation flag, but has not called GET.
        task.cancel()
        read.release.signal()
        do {
            _ = try await task.value
            XCTFail("Cancelled request succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.gets, 0)
        try await client.close()
    }

    private enum Entry { case root, classic, slipstream }

    private func assertBlockedAdmission(entry: Entry, cancel: Bool, alreadyCancelled: Bool = false) async throws {
        let fixture = TorAdmissionFixture()
        let client = TorClient(runtimePtr: fixture.runtimes.parent, torDir: testTempDirectory, httpGetNative: fixture.native)
        let entered = expectation(description: "actor held")
        let release = DispatchSemaphore(value: 0)
        let completed = expectation(description: "caller completed while actor held")
        let started = expectation(description: "request started")
        let start = TorAdmissionStartGate()
        let operation: () async throws -> TorHTTPRequestExecutor.Response
        let blocker: Task<Void, Never>
        switch entry {
        case .root:
            blocker = Task { await client.holdAdmission(entered: entered, release: release) }
            operation = { try await client.httpGet(for: self.request, retryLimit: 0, timeoutMilliseconds: cancel ? 10_000 : 50) }
        case .classic:
            let synchronizer = SDKSynchronizer(initializer: try makeInitializer(client: client))
            blocker = Task { await synchronizer.sdkFlags.holdAdmission(entered: entered, release: release) }
            operation = { try await synchronizer.httpGetOverTor(for: self.request, retryLimit: 0, timeoutMilliseconds: cancel ? 10_000 : 50) }
        case .slipstream:
            let synchronizer = SlipstreamSynchronizer(initializer: try makeInitializer(client: client))
            blocker = Task { await synchronizer.holdAdmission(entered: entered, release: release) }
            operation = { try await synchronizer.httpGetOverTor(for: self.request, retryLimit: 0, timeoutMilliseconds: cancel ? 10_000 : 50) }
        }
        await fulfillment(of: [entered], timeout: 3)
        let task = Task {
            await start.wait()
            started.fulfill()
            defer { completed.fulfill() }
            do { return Result<TorHTTPRequestExecutor.Response, Error>.success(try await operation()) } catch { return Result<TorHTTPRequestExecutor.Response, Error>.failure(error) }
        }
        if alreadyCancelled { task.cancel() }
        await start.release()
        await fulfillment(of: [started], timeout: 3)
        if cancel { task.cancel() }
        // This guard must finish before opening the actor, including on baseline failure.
        await fulfillment(of: [completed], timeout: 1)
        release.signal()
        await blocker.value
        let result = await task.value
        switch result {
        case .success: XCTFail("Terminated admission succeeded")
        case .failure(let error):
            if cancel { XCTAssertTrue(error is CancellationError) } else { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        }
        // Flush the late actor hop before inspecting native side effects.
        try await client.close()
        XCTAssertEqual(fixture.gets, 0)
        XCTAssertEqual(fixture.clones, 0)
    }

    private var request: URLRequest { URLRequest(url: URL(string: "https://example.com")!) }

    private func makeInitializer(client: TorClient) throws -> Initializer {
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in ZcashRustBackendWeldingMock() }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in LightWalletServiceMock() }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in TransactionRepositoryMock() }
        return Initializer(
            container: mockContainer, cacheDbURL: nil, fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory, dataDbURL: try __dataDbURL(), torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default, network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(), outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests, isTorEnabled: true, isExchangeRateEnabled: false
        )
    }
}

private extension TorClient {
    func holdAdmission(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        _ = release.wait(timeout: .now() + 5)
    }
}

private extension SDKFlags {
    func holdAdmission(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        _ = release.wait(timeout: .now() + 5)
    }
}

private extension SlipstreamSynchronizer {
    func holdAdmission(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        _ = release.wait(timeout: .now() + 5)
    }
}

private final class TorAdmissionFixture: @unchecked Sendable {
    let runtimes = TorTestRuntimes()
    let response = TorResponseFixture()
    private let lock = NSLock()
    private var getCount = 0
    private var cloneCount = 0
    var gets: Int { lock.withLock { getCount } }
    var clones: Int { lock.withLock { cloneCount } }
    var native: TorHTTPGetNative {
        TorHTTPGetNative(
            get: { [self] _, _, _, _, _, _ in
                lock.withLock { getCount += 1 }
                return response.pointer
            },
            freeResponse: { _ in },
            isolateRuntime: { [self] pointer in
                lock.withLock { cloneCount += 1 }
                return runtimes.clone(pointer)
            },
            freeRuntime: { [self] in runtimes.free($0) }
        )
    }
    deinit { response.free() }
}

private actor TorAdmissionStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}

private final class TorAdmissionWorkerRead: @unchecked Sendable {
    let entered = XCTestExpectation(description: "worker read held before GET")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var reads = 0

    func read() -> UInt64 {
        let worker = lock.withLock {
            reads += 1
            return reads == 2
        }
        if worker {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        return DispatchTime.now().uptimeNanoseconds
    }
}
