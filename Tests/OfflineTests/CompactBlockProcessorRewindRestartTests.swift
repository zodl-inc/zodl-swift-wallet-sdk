import Combine
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class CompactBlockProcessorRewindRestartTests: ZcashTestCase {
    func testIdleRewindTerminalConsumerCanRestartExactlyOnce() async throws {
        try await assertRestart(active: false)
    }

    func testActiveRewindTerminalConsumerCanRestartExactlyOnce() async throws {
        try await assertRestart(active: true)
    }

    func testIdleRewindQueuedRetryResetsExhaustedAttemptsAndCoalesces() async throws {
        try await assertRestart(active: false, exhaustRetries: true)
    }

    func testActiveRewindQueuedRetryResetsExhaustedAttemptsAndCoalesces() async throws {
        try await assertRestart(active: true, exhaustRetries: true)
    }

    func testRewindSupersedesEarlierAutomaticStartWithoutAnExplicitRestart() async throws {
        try await assertRestart(active: true, requestRestart: false)
    }

    func testQueuedStartWithoutRetryPreservesExhaustedAttempts() async throws {
        try await assertRestart(active: false, exhaustRetries: true, retryAfterFailure: false)
    }

    func testRequestStopRevokesIdleRewindRestart() async throws {
        try await assertRestart(active: false, superseding: .requestStop)
    }

    func testRequestStopRevokesActiveRewindRestart() async throws {
        try await assertRestart(active: true, superseding: .requestStop)
    }

    func testAwaitedStopRevokesIdleRewindRestart() async throws {
        try await assertRestart(active: false, superseding: .awaitedStop)
    }

    func testAwaitedStopRevokesActiveRewindRestart() async throws {
        try await assertRestart(active: true, superseding: .awaitedStop)
    }

    func testWipeRevokesIdleRewindRestart() async throws {
        try await assertRestart(active: false, superseding: .wipe)
    }

    func testWipeRevokesActiveRewindRestart() async throws {
        try await assertRestart(active: true, superseding: .wipe)
    }

    private func assertRestart(
        active: Bool,
        exhaustRetries: Bool = false,
        retryAfterFailure: Bool = true,
        requestRestart: Bool = true,
        superseding: SupersedingOperation? = nil
    ) async throws {
        let fixture = try await ClassicProcessorCleanupFixture.make(storageDirectory: testTempDirectory)
        let processor = fixture.synchronizer.blockProcessor
        let initialActionGate = GiftCardOperationGate()
        let completionGate = GiftCardOperationGate()
        let nextActionGate = GiftCardOperationGate()
        addTeardownBlock {
            await initialActionGate.open()
            await completionGate.open()
            await nextActionGate.open()
            await processor.stopAndWait()
            try await fixture.cleanup()
        }
        if exhaustRetries { await setRetryLimitToOne(processor) }
        let events = CleanupEvents()
        let initialAction = XCTestExpectation(description: "initial sync action entered")
        let nextAction = XCTestExpectation(description: "exactly one real subsequent sync action entered")
        fixture.repository.findForResubmissionUpToClosure = { _ in
            if active && events.appendOnce("initial-action") {
                initialAction.fulfill()
                await initialActionGate.wait()
            } else {
                events.append("next-action")
                nextAction.fulfill()
                await nextActionGate.wait()
            }
            return []
        }
        await processor.updateEventClosure(identifier: "restart-after-rewind") { event in
            if case .failed(let error) = event, case ZcashError.compactBlockProcessorMaxAttemptsReached = error {
                events.append("retry-exhausted")
            }
            if case .startedSyncing = event {
                events.append("start")
                await processor.context.update(state: .txResubmission)
            }
        }
        var activeOwner: Task<Void, Error>?
        if active {
            try await fixture.synchronizer.start()
            await fulfillment(of: [initialAction], timeout: 5)
            activeOwner = await processor.syncTask
            XCTAssertNotNil(activeOwner)
            // This old automatic restart must be superseded by rewind.
            await processor.start()
        }
        fixture.backend.rewindToHeightHeightClosure = { height in
            if exhaustRetries { throw RestartRewindFailure.backend }
            return .success(height)
        }
        fixture.storage.rewindToClosure = { _ in }
        let terminal = XCTestExpectation(description: "public-equivalent rewind terminal notification delivered")
        let subject = PassthroughSubject<Void, Error>()
        let subscription = subject.sink(receiveCompletion: { _ in
            events.append("terminal")
            terminal.fulfill()
        }, receiveValue: { })
        // The public synchronizer sends its publisher terminal event from this
        // same RewindContext completion boundary. A controlled subject allows
        // retaining that callback after delivery, while using real public start.
        let rewindAdmitted = XCTestExpectation(description: "active rewind requested cancellation")
        fixture.downloader.stopDownloadClosure = {
            if events.appendOnce("rewind-admitted") { rewindAdmitted.fulfill() }
        }
        let rewind = Task {
            try await processor.rewind(context: AfterSyncHooksManager.RewindContext(height: 3_000_000, completion: { result in
                switch result {
                case .success:
                    XCTAssertFalse(exhaustRetries)
                    subject.send(completion: .finished)
                case .failure(let error):
                    XCTAssertTrue(exhaustRetries)
                    subject.send(completion: .failure(error))
                }
                await completionGate.wait()
                events.append("completion-returned")
            }))
        }
        if active {
            await fulfillment(of: [rewindAdmitted], timeout: 5)
            await initialActionGate.open()
        }
        await fulfillment(of: [terminal], timeout: 5)
        let idleOwner = await processor.rewindTask
        if !active { XCTAssertNotNil(idleOwner) }
        if requestRestart {
            try await fixture.synchronizer.start(retry: exhaustRetries && retryAfterFailure)
            // A later default request must not erase the earlier retry intent.
            try await fixture.synchronizer.start()
        }
        XCTAssertEqual(events.events.filter { $0 == "start" }.count, active ? 1 : 0)
        XCTAssertFalse(events.events.contains("next-action"), "restart must wait for the retained callback owner")
        var stop: Task<Void, Never>?
        if let superseding {
            switch superseding {
            case .requestStop:
                await processor.stop()
            case .awaitedStop:
                let admitted = XCTestExpectation(description: "drain admitted after explicit restart")
                fixture.downloader.stopDownloadClosure = {
                    if events.appendOnce("drain-admitted") { admitted.fulfill() }
                }
                stop = Task { await processor.stopAndWait() }
                await fulfillment(of: [admitted], timeout: 5)
            case .wipe:
                try await processor.wipe(context: AfterSyncHooksManager.WipeContext(prewipe: { }, completion: { error in
                    XCTAssertNil(error)
                    events.append("wiped")
                }))
            }
        }
        await completionGate.open()
        await idleOwner?.value
        _ = await activeOwner?.result
        try await rewind.value
        if superseding != nil || !requestRestart || (exhaustRetries && !retryAfterFailure) {
            let remainingOwner = await processor.syncTask
            XCTAssertNil(remainingOwner, "superseded or exhausted starts must not reserve another run")
            // Join teardown before reading wipe completion or releasing fixtures.
            await stop?.value
            await processor.stopAndWait()
            XCTAssertFalse(events.events.contains("next-action"))
            XCTAssertEqual(events.events.filter { $0 == "start" }.count, active ? 1 : 0)
            if superseding == .wipe { XCTAssertTrue(events.events.contains("wiped")) }
            if exhaustRetries && !retryAfterFailure {
                XCTAssertEqual(events.events.filter { $0 == "retry-exhausted" }.count, 1)
            }
        } else {
            await fulfillment(of: [nextAction], timeout: 5)
            let owner = await processor.syncTask
            XCTAssertNotNil(owner)
            XCTAssertEqual(events.events.filter { $0 == "next-action" }.count, 1)
            XCTAssertEqual(events.events.filter { $0 == "start" }.count, active ? 2 : 1)
            XCTAssertLessThan(
                try XCTUnwrap(events.events.firstIndex(of: "completion-returned")),
                try XCTUnwrap(events.events.firstIndex(of: "next-action"))
            )
            await nextActionGate.open()
            _ = await owner?.result
            XCTAssertEqual(events.events.filter { $0 == "next-action" }.count, 1)
        }
        withExtendedLifetime(subscription) { }
    }

    private func setRetryLimitToOne(_ processor: CompactBlockProcessor) async {
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
            retries: 1,
            walletBirthdayProvider: config.walletBirthdayProvider,
            saplingActivation: config.saplingActivation,
            network: config.network
        ))
    }
}

private enum SupersedingOperation { case requestStop, awaitedStop, wipe }
private enum RestartRewindFailure: Error { case backend }
