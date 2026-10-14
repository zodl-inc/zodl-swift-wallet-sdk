import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class CompactBlockProcessorRewindPollingTests: ZcashTestCase {
    func testPreparedIdleRewindDoesNotEnablePolling() async throws {
        try await assertRewind(polling: false)
    }

    func testStoppedRewindDoesNotEnablePollingAndLaterExplicitStartWorks() async throws {
        try await assertRewind(polling: true, stopped: true, explicitRestart: true)
    }

    func testStoppedBackendRewindFailureDoesNotEnablePolling() async throws {
        try await assertRewind(polling: true, stopped: true, failure: .backend)
    }

    func testStoppedStorageRewindFailureDoesNotEnablePolling() async throws {
        try await assertRewind(polling: true, stopped: true, failure: .storage)
    }

    func testPollingRewindRestoresPollingAfterSuccess() async throws {
        try await assertRewind(polling: true)
    }

    func testPollingRewindPreservesRetryAfterBackendFailure() async throws {
        try await assertRewind(polling: true, failure: .backend)
    }

    func testRequestStopDuringSuccessCompletionRevokesPollingRestoration() async throws {
        try await assertRewind(polling: true, stopInCompletion: true)
    }

    func testRequestStopDuringFailureCallbackRevokesRetryAndRestoration() async throws {
        try await assertRewind(polling: true, failure: .backend, stopInFailure: true)
    }

    func testPollingRewindDoesNotRestoreTimerAfterRetryLimit() async throws {
        try await assertRewind(polling: true, failure: .backend, retries: 1)
    }

    private func assertRewind(
        polling: Bool,
        stopped: Bool = false,
        failure: RewindFailure? = nil,
        stopInCompletion: Bool = false,
        stopInFailure: Bool = false,
        explicitRestart: Bool = false,
        retries: Int? = nil
    ) async throws {
        let fixture = try await ClassicProcessorCleanupFixture.make(storageDirectory: testTempDirectory)
        let processor = fixture.synchronizer.blockProcessor
        let rewindGate = GiftCardOperationGate()
        let restartGate = GiftCardOperationGate()
        addTeardownBlock {
            await rewindGate.open()
            await restartGate.open()
            await processor.stopAndWait()
            try await fixture.cleanup()
        }
        if let retries {
            let config = await processor.config
            await processor.update(config: CompactBlockProcessor.Configuration(
                alias: config.alias,
                cacheDbURL: config.cacheDbURL,
                fsBlockCacheRoot: config.fsBlockCacheRoot,
                dataDb: config.dataDb,
                torDir: config.torDir,
                spendParamsURL: config.spendParamsURL,
                outputParamsURL: config.outputParamsURL,
                saplingParamsSourceURL: config.saplingParamsSourceURL,
                retries: retries,
                walletBirthdayProvider: config.walletBirthdayProvider,
                saplingActivation: config.saplingActivation,
                network: config.network
            ))
        }
        let events = CleanupEvents()
        await processor.updateEventClosure(identifier: "rewind-polling") { event in
            switch event {
            case .startedSyncing:
                events.append("start")
                await processor.context.update(state: .txResubmission)
            case .failed(let error):
                XCTAssertTrue(error is RewindFailure)
                events.append("failed")
                if stopInFailure { await processor.stop() }
            default:
                break
            }
        }
        if polling {
            await processor.start()
            let run = await processor.syncTask
            let owner = try XCTUnwrap(run)
            try await owner.value
            let initialTimerValidity = await processor.rewindPollingTimerValidity()
            XCTAssertEqual(initialTimerValidity, true)
        }
        if stopped { await processor.stopAndWait() }
        let startsBeforeRewind = events.events.filter { $0 == "start" }.count
        let entered = XCTestExpectation(description: "rewind backend held")
        fixture.backend.rewindToHeightHeightClosure = { height in
            entered.fulfill()
            await rewindGate.wait()
            if failure == .backend { throw RewindFailure.backend }
            return .success(height)
        }
        fixture.storage.rewindToClosure = { _ in
            if failure == .storage { throw RewindFailure.storage }
        }
        let rewind = Task {
            try await processor.rewind(context: AfterSyncHooksManager.RewindContext(height: 3_000_000, completion: { result in
                switch result {
                case .success:
                    XCTAssertNil(failure)
                case .failure(let error):
                    XCTAssertNotNil(failure)
                    XCTAssertEqual(error as? RewindFailure, failure)
                }
                if stopInFailure {
                    let retryTimer = await processor.rewindPollingTimerValidity()
                    XCTAssertNil(retryTimer, "failure callback stop must revoke retry scheduling before completion")
                }
                events.append("completion")
                if stopInCompletion { await processor.stop() }
            }))
        }
        await fulfillment(of: [entered], timeout: 5)
        let reserved = await processor.rewindTask
        let owner = try XCTUnwrap(reserved)
        await rewindGate.open()
        await owner.value
        try await rewind.value
        XCTAssertEqual(events.events.filter { $0 == "completion" }.count, 1)
        XCTAssertEqual(events.events.filter { $0 == "failed" }.count, failure == .backend ? 1 : 0)
        XCTAssertEqual(events.events.filter { $0 == "start" }.count, startsBeforeRewind)
        let timerValidity = await processor.rewindPollingTimerValidity()
        let shouldPoll = polling && !stopped && !stopInCompletion && !stopInFailure && retries != 1
        if shouldPoll {
            XCTAssertEqual(timerValidity, true)
            try await assertNextStart(processor, fixture: fixture, gate: restartGate, fireTimer: true)
        } else {
            XCTAssertNil(timerValidity)
        }
        if explicitRestart {
            try await assertNextStart(processor, fixture: fixture, gate: restartGate, fireTimer: false)
        }
    }

    private func assertNextStart(
        _ processor: CompactBlockProcessor,
        fixture: ClassicProcessorCleanupFixture,
        gate: GiftCardOperationGate,
        fireTimer: Bool
    ) async throws {
        let entered = XCTestExpectation(description: "next sync action held")
        fixture.repository.findForResubmissionUpToClosure = { _ in
            entered.fulfill()
            await gate.wait()
            return []
        }
        if fireTimer {
            let fired = await processor.fireRewindPollingTimer()
            XCTAssertTrue(fired)
        } else {
            await processor.start()
        }
        await fulfillment(of: [entered], timeout: 5)
        let reserved = await processor.syncTask
        let owner = try XCTUnwrap(reserved)
        await gate.open()
        try await owner.value
        let state = await processor.context.state
        XCTAssertEqual(state, .finished)
    }
}

private enum RewindFailure: Error { case backend, storage }

// Keep Foundation timers on their owning actor while observing only sendable values.
extension CompactBlockProcessor {
    func rewindPollingTimerValidity() -> Bool? {
        backoffTimer?.isValid
    }

    func fireRewindPollingTimer() -> Bool {
        guard let backoffTimer, backoffTimer.isValid else { return false }
        backoffTimer.fire()
        return true
    }
}
