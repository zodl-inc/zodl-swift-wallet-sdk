import Foundation
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

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

    func testSuccessAfterCleanupCompletesWhileRootActorIsHeld() async throws {
        try await assertCompletionAfterCleanup(slipstream: false, cancel: false)
    }

    func testCancellationAfterCleanupCompletesWhileRootActorIsHeld() async throws {
        try await assertCompletionAfterCleanup(slipstream: false, cancel: true)
    }

    func testSuccessAfterCleanupCompletesWhileSlipstreamActorIsHeld() async throws {
        try await assertCompletionAfterCleanup(slipstream: true, cancel: false)
    }

    func testCancellationAfterCleanupCompletesWhileSlipstreamActorIsHeld() async throws {
        try await assertCompletionAfterCleanup(slipstream: true, cancel: true)
    }

    private func assertCompletionAfterCleanup(slipstream: Bool, cancel: Bool) async throws {
        let fixture = TorAdmissionFixture()
        let nativeEntered = expectation(description: "native GET entered")
        let responseFreed = expectation(description: "native response disposed")
        let cloneFreed = expectation(description: "native clone disposed")
        let actorHeld = expectation(description: "actor held after GET entry")
        let completed = expectation(description: "caller completed after cleanup while actor held")
        let prematureCompletion = expectation(description: "active native work retains caller")
        prematureCompletion.isInverted = true
        let releaseNative = DispatchSemaphore(value: 0)
        let releaseActor = DispatchSemaphore(value: 0)
        let completion = TorAdmissionCompletionObservation()
        var native = fixture.native
        native.get = { _, _, _, _, _, _ in
            nativeEntered.fulfill()
            XCTAssertEqual(releaseNative.wait(timeout: .now() + 5), .success)
            return fixture.response.pointer
        }
        native.freeResponse = { _ in responseFreed.fulfill() }
        native.freeRuntime = { pointer in
            fixture.runtimes.free(pointer)
            if pointer != fixture.runtimes.parent { cloneFreed.fulfill() }
        }
        let client = TorClient(runtimePtr: fixture.runtimes.parent, torDir: testTempDirectory, httpGetNative: native)
        let operation: () async throws -> TorHTTPRequestExecutor.Response
        let holdActor: () async -> Void
        if slipstream {
            let synchronizer = SlipstreamSynchronizer(initializer: try makeInitializer(client: client))
            operation = { try await synchronizer.httpGetOverTor(for: self.request, retryLimit: 0, timeoutMilliseconds: 10_000) }
            holdActor = { await synchronizer.holdAdmission(entered: actorHeld, release: releaseActor) }
        } else {
            operation = { try await client.httpGet(for: self.request, retryLimit: 0, timeoutMilliseconds: 10_000) }
            holdActor = { await client.holdAdmission(entered: actorHeld, release: releaseActor) }
        }
        let task = Task {
            defer {
                completion.markCompleted()
                prematureCompletion.fulfill()
                completed.fulfill()
            }
            do { return Result<TorHTTPRequestExecutor.Response, Error>.success(try await operation()) }
            catch { return Result<TorHTTPRequestExecutor.Response, Error>.failure(error) }
        }
        await fulfillment(of: [nativeEntered], timeout: 3)
        let blocker = Task { await holdActor() }
        await fulfillment(of: [actorHeld], timeout: 3)
        if cancel { task.cancel() }
        await fulfillment(of: [prematureCompletion], timeout: 0.05)
        XCTAssertFalse(completion.completed, "Active native work must retain its caller")
        releaseNative.signal()
        await fulfillment(of: [responseFreed, cloneFreed], timeout: 3)
        await fulfillment(of: [completed], timeout: 1)
        releaseActor.signal()
        await blocker.value
        switch await task.value {
        case .success(let response):
            XCTAssertFalse(cancel, "Cancelled active GET succeeded")
            XCTAssertEqual(response.data, Data([3, 1, 4]))
            XCTAssertEqual(response.response.statusCode, 201)
        case .failure(let error):
            XCTAssertTrue(cancel && error is CancellationError, "Unexpected failure: \(error)")
        }
        try await client.close()
    }

    func testTaskLocalLifetimeObservesInheritedTaskExitAfterCallerReturns() async {
        let childEntered = expectation(description: "inherited task entered")
        let lifetimeExited = expectation(description: "inherited task released lifetime")
        let release = TorAdmissionStartGate()
        let observation = TorAdmissionCompletionObservation()
        let caller = Task {
            TorAdmissionTaskState.$lifetime.withValue(TorAdmissionLifetime {
                observation.markCompleted()
                lifetimeExited.fulfill()
            }) {
                Task {
                    XCTAssertNotNil(TorAdmissionTaskState.lifetime)
                    childEntered.fulfill()
                    await release.wait()
                    XCTAssertNotNil(TorAdmissionTaskState.lifetime)
                }
            }
        }
        let child = await caller.value
        await fulfillment(of: [childEntered], timeout: 3)
        XCTAssertFalse(observation.completed, "Caller exit must not hide an inherited task still running")
        await release.release()
        await child.value
        await fulfillment(of: [lifetimeExited], timeout: 3)
        XCTAssertTrue(observation.completed)
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
        let admissionExited = expectation(description: "inherited admission and timer state released")
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
            return await TorAdmissionTaskState.$lifetime.withValue(TorAdmissionLifetime { admissionExited.fulfill() }) {
                started.fulfill()
                defer { completed.fulfill() }
                do { return Result<TorHTTPRequestExecutor.Response, Error>.success(try await operation()) }
                catch { return Result<TorHTTPRequestExecutor.Response, Error>.failure(error) }
            }
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
        // The task-local value is inherited by admission/timer tasks. Its release
        // observes their exit before parent close could hide an illicit late clone.
        await fulfillment(of: [admissionExited], timeout: 3)
        XCTAssertTrue(fixture.runtimes.isAlive(fixture.runtimes.parent))
        XCTAssertEqual(fixture.gets, 0)
        XCTAssertEqual(fixture.clones, 0)
        try await client.close()
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
        XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
    }
}

private extension SDKFlags {
    func holdAdmission(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
    }
}

private extension SlipstreamSynchronizer {
    func holdAdmission(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
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
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        return DispatchTime.now().uptimeNanoseconds
    }
}

private final class TorAdmissionCompletionObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false
    var completed: Bool { lock.withLock { didComplete } }
    func markCompleted() { lock.withLock { didComplete = true } }
}

private enum TorAdmissionTaskState {
    @TaskLocal static var lifetime: TorAdmissionLifetime?
}

private final class TorAdmissionLifetime: @unchecked Sendable {
    private let onExit: @Sendable () -> Void
    init(onExit: @escaping @Sendable () -> Void) { self.onExit = onExit }
    deinit { onExit() }
}
