import Combine
import Foundation
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class AwaitableStopSynchronizerTests: ZcashTestCase {
    func testClassicStopAndWaitCompletesAfterProcessorStop() async throws {
        try await assertClassicStopCompletion(status: .syncing(0.5, false))
    }

    func testClassicIdleSyncedStopCompletesWithoutStoppedEvent() async throws {
        try await assertClassicStopCompletion(status: .synced)
    }

    func testClassicIdleErrorStopCompletesWithoutStoppedEvent() async throws {
        try await assertClassicStopCompletion(status: .error(ZcashError.synchronizerNotPrepared))
    }

    func testClassicUnpreparedAndRepeatedStopsComplete() async throws {
        let trace = StopTrace()
        let sync = try makeClassic(trace: trace)
        await sync.stopAndWait()
        let firstStops = trace.events.filter { $0 == "stop:done" }.count
        XCTAssertGreaterThan(firstStops, 0)
        await sync.stopAndWait()
        XCTAssertGreaterThan(trace.events.filter { $0 == "stop:done" }.count, firstStops)
        assertEveryClassicStopFinished(trace)
        XCTAssertEqual(sync.latestState.internalSyncStatus, .unprepared)
    }

    func testClassicAlreadyStoppedAndDisconnectedStillDrainProcessor() async throws {
        let trace = StopTrace()
        let sync = try makeClassic(trace: trace)
        for status: InternalSyncStatus in [.stopped, .disconnected] {
            await sync.updateStatus(status)
            await sync.sdkFlags.markChainTipAsUpdated()
            await sync.stopAndWait()
            let chainTipUpdated = await sync.sdkFlags.chainTipUpdated
            XCTAssertFalse(chainTipUpdated)
        }
        assertEveryClassicStopFinished(trace)
    }

    func testClassicLegacyStopReturnsWhileOneProcessorStopIsHeld() async throws {
        let trace = StopTrace()
        let gate = Gate()
        let entered = XCTestExpectation(description: "processor stop entered")
        let bodyFinished = XCTestExpectation(description: "processor stop returned")
        let sync = try makeClassic(trace: trace, gate: gate, entered: entered, bodyFinished: bodyFinished)
        let invocationReturned = XCTestExpectation(description: "legacy stop returned")
        Task {
            sync.stop()
            trace.append("legacy:return")
            invocationReturned.fulfill()
        }
        await fulfillment(of: [invocationReturned, entered], timeout: 5)
        XCTAssertFalse(trace.events.contains("stop:done"))
        gate.open()
        await fulfillment(of: [bodyFinished], timeout: 5)
        await sync.stopAndWait()
        assertEveryClassicStopFinished(trace)
    }

    func testSlipstreamStopAndWaitCompletesAfterEngineStop() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.synced)
        let entered = XCTestExpectation(description: "engine stop entered")
        await engine.onCall("stop") { entered.fulfill() }
        engine.stopGate.close()
        let trace = StopTrace()
        let returned = XCTestExpectation(description: "awaited stop returned")
        let operation = Task {
            await sync.stopAndWait()
            let calls = await engine.calls
            trace.append(calls.contains("stop:done") ? "completed" : "premature")
            if !trace.events.contains("release") { returned.fulfill() }
        }
        await fulfillment(of: [entered], timeout: 5)
        returned.isInverted = true
        // A bounded negative check: completion must stay blocked by the owned stop body.
        await fulfillment(of: [returned], timeout: 0.1)
        trace.append("release")
        engine.stopGate.open()
        await operation.value
        XCTAssertEqual(trace.events, ["release", "completed"])
        let calls = await engine.calls
        XCTAssertEqual(calls.filter { $0 == "stop" }.count, 1)
    }

    func testSlipstreamAwaitedStopWaitsForAnEarlierStartAndBeforeNextStart() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let firstStartEntered = XCTestExpectation(description: "earlier queued start entered")
        await engine.onCall("start") { firstStartEntered.fulfill() }
        engine.startGate.close()
        let firstStart = Task { try await sync.start() }
        await fulfillment(of: [firstStartEntered], timeout: 5)
        let trace = StopTrace()
        let returned = XCTestExpectation(description: "stop behind start returned")
        let operation = Task {
            await sync.stopAndWait()
            if !trace.events.contains("release") { returned.fulfill() }
        }
        returned.isInverted = true
        await fulfillment(of: [returned], timeout: 0.1)
        trace.append("release")
        engine.startGate.open()
        try await firstStart.value
        await operation.value
        try await sync.start()
        let calls = await engine.calls.filter { $0.hasPrefix("start") || $0.hasPrefix("stop") }
        XCTAssertEqual(calls, ["start", "start:done", "stop", "stop:done", "start", "start:done"])
        await sync.stopAndWait()
    }

    func testSlipstreamUnpreparedRepeatedAndNonQuiescentStopsComplete() async throws {
        let engine = GatedFakeSlipstreamEngine()
        engine.stopReport = .passStillRunning
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.stopAndWait()
        await sync.stopAndWait()
        let calls = await engine.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("stop") }, ["stop", "stop:done", "stop", "stop:done"])
        XCTAssertEqual(sync.latestState.internalSyncStatus, .unprepared)
        await sync.setInternalSyncStatusForTesting(.stopped)
        await sync.stopAndWait()
        XCTAssertEqual(sync.latestState.internalSyncStatus, .stopped)
    }

    func testSlipstreamLegacyStopReturnsWhileOneEngineStopIsHeld() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        let entered = XCTestExpectation(description: "engine stop entered")
        let bodyFinished = XCTestExpectation(description: "engine stop finished")
        await engine.onCall("stop") { entered.fulfill() }
        await engine.onCall("stop:done") { bodyFinished.fulfill() }
        engine.stopGate.close()
        sync.stop()
        await fulfillment(of: [entered], timeout: 5)
        let heldCalls = await engine.calls
        XCTAssertFalse(heldCalls.contains("stop:done"))
        engine.stopGate.open()
        await fulfillment(of: [bodyFinished], timeout: 5)
        let calls = await engine.calls
        XCTAssertEqual(calls.filter { $0 == "stop" }.count, 1)
    }

    private func assertClassicStopCompletion(status: InternalSyncStatus) async throws {
        let trace = StopTrace()
        let gate = Gate()
        let entered = XCTestExpectation(description: "processor stop entered")
        let bodyFinished = XCTestExpectation(description: "processor stop finished")
        let sync = try makeClassic(trace: trace, gate: gate, entered: entered, bodyFinished: bodyFinished)
        await sync.updateStatus(status)
        let statuses = RecordedSyncStatuses()
        let subscription = sync.stateStream.sink { statuses.append($0.internalSyncStatus) }
        defer { subscription.cancel() }
        let returned = XCTestExpectation(description: "awaited stop returned")
        let operation = Task {
            await sync.stopAndWait()
            trace.append("return")
            if !trace.events.contains("release") { returned.fulfill() }
        }
        await fulfillment(of: [entered], timeout: 5)
        returned.isInverted = true
        await fulfillment(of: [returned], timeout: 0.1)
        trace.append("release")
        gate.open()
        await operation.value
        await fulfillment(of: [bodyFinished], timeout: 5)
        let events = trace.events
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "release")), try XCTUnwrap(events.firstIndex(of: "stop:done")))
        XCTAssertEqual(events.last, "return")
        assertEveryClassicStopFinished(trace)
        XCTAssertFalse(statuses.contains(.stopped), "an idle processor need not publish a stopped event")
    }

    private func assertEveryClassicStopFinished(_ trace: StopTrace) {
        let events = trace.events
        let stops = events.filter { $0 == "stop" }.count
        XCTAssertGreaterThan(stops, 0)
        XCTAssertEqual(stops, events.filter { $0 == "stop:done" }.count)
    }

    private func makeClassic(
        trace: StopTrace,
        gate: Gate? = nil,
        entered: XCTestExpectation? = nil,
        bodyFinished: XCTestExpectation? = nil
    ) throws -> SDKSynchronizer {
        let downloader = BlockDownloaderMock()
        downloader.stopDownloadClosure = {
            let firstStop = !trace.events.contains("stop")
            trace.append("stop")
            if firstStop { entered?.fulfill() }
            await gate?.wait()
            trace.append("stop:done")
            if firstStop { bodyFinished?.fulfill() }
        }
        mockContainer.mock(type: BlockDownloader.self, isSingleton: true) { _ in downloader }
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in ZcashRustBackendWeldingMock() }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in LightWalletServiceMock() }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in TransactionRepositoryMock() }
        let initializer = Initializer(
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
        return SDKSynchronizer(initializer: initializer)
    }
}

private final class StopTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var events: [String] { lock.withLock { values } }

    func append(_ value: String) {
        lock.withLock { values.append(value) }
    }
}
