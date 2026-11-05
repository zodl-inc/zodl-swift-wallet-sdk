import Combine
import os
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class SlipstreamPrivateRetryRoutingTests: ZcashTestCase {
    private let publicEndpoint = LightWalletEndpoint(address: "public.example.com", port: 443, secure: true)
    private let gateway = LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443, secure: true)
    private let txId = Data(repeating: 7, count: 32)
    private var cancellables = Set<AnyCancellable>()

    func testPrivateRetryIgnoresRecordedPublicEndpoints() async throws {
        let fixture = try makeFixture()
        await fixture.store.recordPlan(txId: txId, endpoints: [publicEndpoint])
        try await fixture.sync.switchTo(endpoint: gateway)
        await retry(fixture)
        XCTAssertEqual(fixture.sends.withLock { $0 }, [gateway.host])
        let plan = await fixture.store.plan(for: txId)
        XCTAssertEqual(plan, .ready([publicEndpoint], acceptedBy: "\(gateway.host):443"))
    }

    func testPrivateLegacyRetryUsesGateway() async throws {
        let fixture = try makeFixture()
        try await fixture.sync.switchTo(endpoint: gateway)
        await retry(fixture)
        XCTAssertEqual(fixture.sends.withLock { $0 }, [gateway.host])
        let plan = await fixture.store.plan(for: txId)
        XCTAssertNil(plan, "Legacy retries must not invent submission-consent metadata")
    }

    func testLegacyRetryUsesReboundManualService() async throws {
        let fixture = try makeFixture()
        let manual = LightWalletEndpoint(address: "manual.example.com", port: 443, secure: true)
        try await fixture.sync.switchTo(endpoint: manual)
        await retry(fixture)
        XCTAssertEqual(fixture.sends.withLock { $0 }, [manual.host])
    }

    func testPublicRetryPreservesRecordedPlan() async throws {
        let fixture = try makeFixture()
        let manual = LightWalletEndpoint(address: "manual.example.com", port: 443, secure: true)
        await fixture.store.recordPlan(txId: txId, endpoints: [manual])
        await retry(fixture)
        XCTAssertEqual(fixture.sends.withLock { $0 }, [manual.host])
    }

    func testPrivateRoutingPreservesSubmissionConsent() async throws {
        let fixture = try makeFixture()
        let lifecycle = await fixture.store.currentLifecycle()
        await fixture.store.markAwaitingSubmission(txIds: [txId], lifecycle: lifecycle)
        try await fixture.sync.switchTo(endpoint: gateway)
        await retry(fixture)
        XCTAssertTrue(fixture.sends.withLock { $0.isEmpty })
        let plan = await fixture.store.plan(for: txId)
        XCTAssertEqual(plan, .awaiting)
    }

    func testPrivateRoutingSkipsUnavailablePlanStore() async throws {
        let store = SubmitPlanStoringMock()
        store.storeUnavailable = true
        let fixture = try makeFixture(store: store)
        try await fixture.sync.switchTo(endpoint: gateway)
        await retry(fixture)
        XCTAssertTrue(fixture.sends.withLock { $0.isEmpty })
    }

    func testFailedSwitchKeepsPreviousRoute() async throws {
        let fixture = try makeFixture()
        await fixture.engine.setReopenError(LightWalletServiceError.timeOut)
        do {
            try await fixture.sync.switchTo(endpoint: gateway)
            XCTFail("Expected reopen failure")
        } catch {}
        await retry(fixture)
        XCTAssertEqual(fixture.sends.withLock { $0 }, [publicEndpoint.host])
    }

    func testSwitchWaitsForEarlierPublicRetry() async throws {
        let entered = expectation(description: "public submit is suspended before sending")
        let gate = Gate()
        defer { gate.open() }
        let fixture = try makeFixture(sendGate: gate, onSend: { entered.fulfill() })
        await fixture.store.recordPlan(txId: txId, endpoints: [publicEndpoint])
        await fireRetry(fixture)
        await fulfillment(of: [entered], timeout: 5)
        let completed = OSAllocatedUnfairLock(initialState: false)
        let switching = Task {
            try await fixture.sync.switchTo(endpoint: gateway)
            completed.withLock { $0 = true }
        }
        await waitUntil { fixture.sync.lifecycleQueueDepthForTesting() >= 2 || completed.withLock { $0 } }
        XCTAssertFalse(completed.withLock { $0 }, "Private switch must wait while a public retry can still send")
        gate.open()
        _ = await fixture.sync.awaitResubmissionCheckForTesting()
        try await switching.value
        XCTAssertEqual(fixture.sends.withLock { $0 }, [publicEndpoint.host])
    }

    func testStopWaitsForEarlierRetryAndCompletesAfterRelease() async throws {
        let entered = expectation(description: "retry holds lifecycle turn before stop")
        let gate = Gate()
        defer { gate.open() }
        let fixture = try makeFixture(sendGate: gate, onSend: { entered.fulfill() })
        await fireRetry(fixture)
        await fulfillment(of: [entered], timeout: 5)
        let completed = OSAllocatedUnfairLock(initialState: false)
        let stopping = Task {
            await fixture.sync.stopAndWait()
            completed.withLock { $0 = true }
        }
        await waitUntil { fixture.sync.lifecycleQueueDepthForTesting() >= 2 || completed.withLock { $0 } }
        XCTAssertFalse(completed.withLock { $0 }, "Stop must drain an earlier retry before taking its lifecycle turn")
        gate.open()
        await stopping.value
        _ = await fixture.sync.awaitResubmissionCheckForTesting()
        XCTAssertTrue(completed.withLock { $0 })
        XCTAssertEqual(fixture.sends.withLock { $0 }, [publicEndpoint.host])
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.last, "stop:done")
    }

    func testQueuedRetryUsesPublishedEndpoint() async throws {
        let fixture = try makeFixture()
        await fixture.store.recordPlan(txId: txId, endpoints: [publicEndpoint])
        let switching = await heldSwitch(fixture)
        await fireRetry(fixture)
        await waitUntil { fixture.sync.lifecycleQueueDepthForTesting() >= 2 || !fixture.sends.withLock { $0.isEmpty } }
        XCTAssertTrue(fixture.sends.withLock { $0.isEmpty }, "Retry must wait for route publication")
        fixture.engine.reopenGate.open()
        try await switching.value
        _ = await fixture.sync.awaitResubmissionCheckForTesting()
        XCTAssertEqual(fixture.sends.withLock { $0 }, [gateway.host])
    }

    func testQueuedRetryRetiredByStopDoesNotReadCandidates() async throws {
        let fixture = try makeFixture()
        let switching = await heldSwitch(fixture)
        fixture.sync.stop()
        await fireRetry(fixture)
        await waitUntil { fixture.sync.lifecycleQueueDepthForTesting() >= 3 || fixture.reads.withLock { $0 > 0 } }
        fixture.engine.reopenGate.open()
        try await switching.value
        _ = await fixture.sync.awaitResubmissionCheckForTesting()
        await fixture.sync.stopAndWait()
        XCTAssertEqual(fixture.reads.withLock { $0 }, 0)
        XCTAssertTrue(fixture.sends.withLock { $0.isEmpty })
    }

    func testQueuedRetryBehindWipeDoesNotRecreateStoreOrReadCandidates() async throws {
        let fixture = try makeFixture()
        await fixture.store.recordPlan(txId: txId, endpoints: [publicEndpoint])
        let switching = await heldSwitch(fixture)
        let wiped = expectation(description: "wipe finishes without joining its queued retry")
        let completed = OSAllocatedUnfairLock(initialState: false)
        fixture.sync.wipe()
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion { XCTFail("Wipe failed: \(error)") }
                completed.withLock { $0 = true }
                wiped.fulfill()
            }, receiveValue: { _ in })
            .store(in: &cancellables)
        await waitUntil { fixture.sync.lifecycleQueueDepthForTesting() >= 2 }
        await fireRetry(fixture)
        await waitUntil { fixture.sync.lifecycleQueueDepthForTesting() >= 3 || fixture.reads.withLock { $0 > 0 } }
        fixture.engine.reopenGate.open()
        try await switching.value
        await fulfillment(of: [wiped], timeout: 5)
        // A self-join regression must fail at the timeout rather than hang the test process.
        guard completed.withLock({ $0 }) else { return }
        _ = await fixture.sync.awaitResubmissionCheckForTesting()
        XCTAssertEqual(fixture.reads.withLock { $0 }, 0)
        XCTAssertTrue(fixture.sends.withLock { $0.isEmpty })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeURL.path))
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls.last, "close")
    }

    func testWipeWaitsForEarlierRetryAcceptance() async throws {
        let entered = expectation(description: "Private retry before wipe")
        let gate = Gate()
        defer { gate.open() }
        let fixture = try makeFixture(sendGate: gate, onSend: { entered.fulfill() })
        await fixture.store.recordPlan(txId: txId, endpoints: [publicEndpoint])
        try await fixture.sync.switchTo(endpoint: gateway)
        await fireRetry(fixture)
        await fulfillment(of: [entered], timeout: 5)
        let completed = OSAllocatedUnfairLock(initialState: false)
        let wiped = expectation(description: "wipe after retry")
        fixture.sync.wipe()
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion { XCTFail("Wipe failed: \(error)") }
                completed.withLock { $0 = true }
                wiped.fulfill()
            }, receiveValue: { _ in })
            .store(in: &cancellables)
        await waitUntil { fixture.sync.lifecycleQueueDepthForTesting() >= 2 }
        XCTAssertFalse(completed.withLock { $0 })
        gate.open()
        await fulfillment(of: [wiped], timeout: 5)
        _ = await fixture.sync.awaitResubmissionCheckForTesting()
        XCTAssertEqual(fixture.sends.withLock { $0 }, [gateway.host])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeURL.path))
    }

    private func heldSwitch(_ fixture: Fixture) async -> Task<Void, Error> {
        let entered = expectation(description: "switch holds lifecycle turn during reopen")
        fixture.engine.reopenGate.close()
        await fixture.engine.onCall("reopen") { entered.fulfill() }
        let switching = Task { try await fixture.sync.switchTo(endpoint: gateway) }
        await fulfillment(of: [entered], timeout: 5)
        return switching
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { await Task.yield() }
        XCTAssertTrue(predicate(), "Expected lifecycle barrier was not reached")
    }

    private func fireRetry(_ fixture: Fixture) async {
        await fixture.sync.setResubmissionTimeForTesting(0)
        await fixture.sync.maybeRunTxResubmission(state: 3, chainTip: 100_000, isCancelled: false)
    }

    private func retry(_ fixture: Fixture) async {
        await fireRetry(fixture)
        _ = await fixture.sync.awaitResubmissionCheckForTesting()
    }

    private struct Fixture {
        let sync: SlipstreamSynchronizer
        let engine: GatedFakeSlipstreamEngine
        let store: SubmitPlanStoring
        let storeURL: URL
        let sends: OSAllocatedUnfairLock<[String]>
        let reads: OSAllocatedUnfairLock<Int>
    }

    private func makeFixture(
        store: SubmitPlanStoring? = nil,
        sendGate: Gate? = nil,
        onSend: @escaping @Sendable () -> Void = {}
    ) throws -> Fixture {
        let sends = OSAllocatedUnfairLock(initialState: [String]())
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let backend = ZcashRustBackendWeldingMock()
        backend.listAccountsReturnValue = []
        backend.migrationBlockRateSamplesWindowReturnValue = []
        backend.checkTransactionSubmittableSubmissionServerHeightClosure = { _, _ in nil }
        let candidate = CreatedTransactionTests.makeTransaction(raw: Data([5, 0, 0, 128, 1]), rawID: txId)
        let repository = TransactionRepositoryMock()
        repository.closeDBConnectionClosure = {}
        repository.findForResubmissionUpToClosure = { _ in
            reads.withLock { $0 += 1 }
            return [candidate]
        }
        repository.findRawIDClosure = { _ in candidate }
        let storeURL = testGeneralStorageDirectory.appendingPathComponent("private-retry.db")
        let store = store ?? SubmitPlanStore(databaseURL: storeURL, logger: NullLogger())
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in backend }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in repository }
        mockContainer.mock(type: SubmitPlanStoring.self, isSingleton: true) { _ in store }
        let service: (LightWalletEndpoint) -> LightWalletService = { endpoint in
            let service = LightWalletServiceMock()
            service.closeConnectionsClosure = {}
            service.latestBlockHeightModeReturnValue = 100_000
            service.submitSpendTransactionModeClosure = { _, _ in
                onSend()
                await sendGate?.wait()
                sends.withLock { $0.append(endpoint.host) }
                return SendResponse()
            }
            return service
        }
        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory.appendingPathComponent("blocks"),
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: publicEndpoint,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            loggingPolicy: .noLogging,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
        let binding = try XCTUnwrap(initializer.lightWalletService as? RebindingLightWalletService)
        binding.replace(with: service(publicEndpoint))
        // Retain the production encoder before switching, so a stale service capture is observable.
        _ = initializer.container.resolve(TransactionEncoder.self)
        let submitter = GRPCEndpointSubmitter(
            torClient: initializer.container.resolve(TorClient.self),
            sdkFlags: initializer.container.resolve(SDKFlags.self),
            rustBackend: backend,
            logger: NullLogger(),
            networkType: .testnet,
            serviceFactory: { endpoint, _ in service(endpoint) }
        )
        mockContainer.mock(type: SubmitPlanExecutor.self, isSingleton: true) { _ in
            SubmitPlanExecutor(endpointSubmitter: submitter, logger: NullLogger())
        }
        let engine = GatedFakeSlipstreamEngine()
        let sync = SlipstreamSynchronizer(
            initializer: initializer,
            alternateEndpoints: [],
            engine: engine,
            makeEndpointService: { endpoint, _, _, _ in service(endpoint) }
        )
        return Fixture(sync: sync, engine: engine, store: store, storeURL: storeURL, sends: sends, reads: reads)
    }
}
