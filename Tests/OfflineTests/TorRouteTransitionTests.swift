import Combine
import Foundation
import libzcashlc
import os
import XCTest
@testable import ZODLSwiftWalletSDK
@testable import TestUtils

final class TorRouteTransitionTests: ZcashTestCase {
    func testRunningEnableStopsDirectBeforeTorStart() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let entered = expectation(description: "HTTP bootstrap entered")
        let release = DispatchSemaphore(value: 0)
        let native = TorHTTPGetNative(
            freeRuntime: { _ in },
            startup: TorRuntimeStartupNative.fixture { _, _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return nil
            }
        )
        let client = TorClient(torDir: testTempDirectory, httpGetNative: native)
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start()
        let enable = Task { try await sync.tor(enabled: true) }
        await fulfillment(of: [entered], timeout: 2)
        let calls = await engine.calls
        XCTAssertTrue(calls.contains("stop:done"), "The direct pass must be quiescent before bootstrap")
        release.signal()
        _ = await enable.result
        await sync.stopAndWait()
    }

    func testWrongNetworkRestartPreservesAcquiredTorTransitionAndRunningIntent() async throws {
        let runtimes = TorTestRuntimes()
        let runtimeFrees = OSAllocatedUnfairLock(initialState: 0)
        let client = TorClient(
            runtimePtr: runtimes.parent,
            torDir: testTempDirectory,
            httpGetNative: TorHTTPGetNative(freeRuntime: { pointer in
                runtimeFrees.withLock { $0 += 1 }
                runtimes.free(pointer)
            })
        )
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start()
        let stopping = expectation(description: "Acquired Tor transition is held before stopping completes")
        await engine.closeGate(.stop)
        await engine.onCall("stop") { stopping.fulfill() }
        let transition = sync.requestTorTransition(enabled: true)
        let enable = Task { try await transition.apply() }
        await fulfillment(of: [stopping], timeout: 2)
        XCTAssertTrue(transition.hasAcquired)
        let heldState = sync.torTransitionState
        XCTAssertEqual(heldState?.phase, .stopping)
        let callsBeforeRejection = await engine.calls
        let rejected = expectation(description: "Invalid restart rejects while the valid transition remains held")
        let wrongNetwork = LightWalletEndpoint(address: OHTTPTestSupport.mainnetHost, port: 443, secure: true)
        let restart = Task {
            do {
                try await sync.restartSync(at: wrongNetwork)
                XCTFail("Expected wrong-network rejection")
            } catch let error as ZcashError {
                XCTAssertEqual(error.code, .compactBlockProcessorChainName)
            } catch {
                XCTFail("Expected wrong-network error")
            }
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 0.5)
        XCTAssertEqual(sync.torTransitionState, heldState)
        XCTAssertFalse(transition.isCancelled)
        let callsAfterRejection = await engine.calls
        XCTAssertEqual(callsAfterRejection, callsBeforeRejection)
        XCTAssertEqual(runtimeFrees.withLock { $0 }, 0)
        await engine.openGate(.stop)
        await restart.value
        do {
            try await enable.value
        } catch {
            XCTFail("Invalid restart interrupted the valid Tor transition")
        }
        XCTAssertEqual(sync.torTransitionState?.requestID, transition.id)
        XCTAssertEqual(sync.torTransitionState?.phase, .ready)
        XCTAssertEqual(sync.torTransitionState?.requestedEnabled, true)
        XCTAssertTrue(sync.latestState.internalSyncStatus.isSyncing, "Invalid restart must preserve running intent")
        let callsAfterTransition = await engine.calls
        XCTAssertEqual(callsAfterTransition.filter { GatedFakeSlipstreamEngine.isStop($0) }.count, 1)
        XCTAssertEqual(callsAfterTransition.filter { $0.hasPrefix("reopen(") }.count, 0)
        XCTAssertEqual(runtimeFrees.withLock { $0 }, 0)
        await sync.stopAndWait()
        try await client.close()
    }

    func testFailedEnableRetainsRequiredRouting() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            startup: TorRuntimeStartupNative.fixture { _, _ in nil }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        do {
            try await sync.tor(enabled: true)
            XCTFail("Bootstrap must fail")
        } catch { XCTAssertEqual(error as? TorTransitionState.Failure, .startupFailed) }
        let tor = await mockContainer.resolve(SDKFlags.self).torEnabled
        XCTAssertTrue(tor, "Failed enable must not select direct networking")
    }
    func testOffCancelsBeforePriorBootstrapEnds() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let entered = expectation(description: "bootstrap entered")
        let cancelled = expectation(description: "native cancellation received")
        let release = DispatchSemaphore(value: 0)
        var startup = TorRuntimeStartupNative.fixture { _, _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return nil
        }
        startup.cancel = { _ in cancelled.fulfill() }
        let joined = expectation(description: "independent preparation interest registered")
        let client = TorClient(
            torDir: testTempDirectory,
            httpGetNative: TorHTTPGetNative(startup: startup),
            startupInterestChanged: { if $0 == 2 { joined.fulfill() } }
        )
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        let enable = Task { try await sync.tor(enabled: true) }
        await fulfillment(of: [entered], timeout: 2)
        let independent = Task { try await client.prepare() }
        await fulfillment(of: [joined], timeout: 2)
        let disable = Task { try await sync.tor(enabled: false) }
        await fulfillment(of: [cancelled], timeout: 0.2)
        release.signal()
        _ = await enable.result
        _ = await disable.result
        _ = await independent.result
    }

    func testOffSettlesWhileUnrelatedClientOwnsStartupWorker() async throws {
        let entered = expectation(description: "unrelated HTTP bootstrap entered")
        let release = DispatchSemaphore(value: 0)
        let blocker = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            freeRuntime: { _ in }, startup: TorRuntimeStartupNative.fixture { _, _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return OpaquePointer(bitPattern: 1)
            }
        ))
        let blockingPrepare = Task { try await blocker.prepare() }
        await fulfillment(of: [entered], timeout: 2)
        let queued = expectation(description: "wallet startup queued")
        let settled = expectation(description: "Off lifecycle settled before unrelated startup returns")
        let begins = OSAllocatedUnfairLock(initialState: 0)
        var native = TorRuntimeStartupNative.fixture { _, _ in nil }
        native.begin = { _, _ in
            begins.withLock { $0 += 1 }
            return nil
        }
        let client = TorClient(
            torDir: testTempDirectory,
            httpGetNative: TorHTTPGetNative(startup: native),
            startupInterestChanged: { _ in queued.fulfill() }
        )
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start()
        let enable = Task { try await sync.tor(enabled: true) }
        await fulfillment(of: [queued], timeout: 2)
        let off = Task {
            try await sync.tor(enabled: false)
            settled.fulfill()
        }
        await fulfillment(of: [settled], timeout: 0.5)
        XCTAssertEqual(sync.torTransitionState?.phase, .ready)
        XCTAssertEqual(sync.torTransitionState?.requestedEnabled, false)
        XCTAssertFalse(mockContainer.resolve(SDKFlags.self).routeAdmission.isFenced)
        release.signal()
        try await blockingPrepare.value
        _ = await enable.result
        try await off.value
        try await blocker.close()
        await withCheckedContinuation { continuation in
            TorRuntimeStartup.workerQueue.async { continuation.resume() }
        }
        XCTAssertEqual(begins.withLock { $0 }, 0)
        await sync.stopAndWait()
    }

    func testStopRejectsLateStart() async throws {
        let engine = GatedFakeSlipstreamEngine()
        engine.torStartup.ready.close()
        let nativeStart = expectation(description: "native startup entered")
        await engine.onCall("startTor") { nativeStart.fulfill() }
        let entered = expectation(description: "bootstrap entered")
        let release = DispatchSemaphore(value: 0)
        let native = TorHTTPGetNative(freeRuntime: { _ in }, startup: TorRuntimeStartupNative.fixture { _, _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return OpaquePointer(bitPattern: 1)
        })
        let client = TorClient(torDir: testTempDirectory, httpGetNative: native)
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start()
        let enable = Task { try await sync.tor(enabled: true) }
        await fulfillment(of: [entered], timeout: 2)
        await fulfillment(of: [nativeStart], timeout: 2)
        let startsBeforeStop = await engine.calls.filter { $0 == "start" }.count
        sync.stop()
        release.signal()
        _ = await enable.result
        await sync.stopAndWait()
        let starts = await engine.calls.filter { $0 == "start" }.count
        XCTAssertEqual(starts, startsBeforeStop, "A stop request must invalidate a queued bootstrap restart")
    }

    func testWipeRejectsLateNativeReadiness() async throws {
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            freeRuntime: { _ in }, startup: TorRuntimeStartupNative.fixture { _, _ in OpaquePointer(bitPattern: 1) }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        engine.torStartup.ready.close()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.stopped)
        let enable = Task { try await sync.tor(enabled: true) }
        // Idle enable does not need native work; start an ordinary run to require it.
        try await enable.value
        let start = Task { try await sync.start() }
        await engine.torStartup.entered.wait()
        let wiped = expectation(description: "wallet wipe completes")
        let subscription = sync.wipe().sink(receiveCompletion: { completion in
            if case .failure(let error) = completion { XCTFail("Wipe failed: \(error)") }
            wiped.fulfill()
        }, receiveValue: { _ in })
        XCTAssertTrue(engine.torStartup.isCancelled, "Wipe invalidates startup before waiting for lifecycle ownership")
        engine.torStartup.ready.open()
        _ = await start.result
        await fulfillment(of: [wiped], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(sync.torTransitionState?.phase, .cancelled)
        XCTAssertFalse(sync.latestState.internalSyncStatus.isPrepared)
        let open = await engine.isOpen
        XCTAssertFalse(open)
    }

    func testNativePendingPreventsReady() async throws {
        let client = TorClient(runtimePtr: OpaquePointer(bitPattern: 1)!, torDir: testTempDirectory,
                               httpGetNative: TorHTTPGetNative(freeRuntime: { _ in }))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        engine.torStartup.ready.close()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start()
        let nativeStart = expectation(description: "native start requested")
        await engine.onCall("startTor") { nativeStart.fulfill() }
        let request = sync.requestTorTransition(enabled: true)
        let applying = Task { try await request.apply() }
        await fulfillment(of: [nativeStart], timeout: 0.2)
        XCTAssertNotEqual(sync.torTransitionState?.phase, .ready)
        engine.torStartup.ready.open()
        try await applying.value
        await sync.stopAndWait()
    }

    func testBroadcasterAdmissionSurvivesAcceptedReturnAndFanoutTail() async throws {
        let flags = SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        let bothEntered = expectation(description: "both endpoints entered")
        bothEntered.expectedFulfillmentCount = 2
        let tailFinished = expectation(description: "tail finished")
        let winner = Gate()
        let tail = Gate()
        let endpoints = [LightWalletEndpoint(address: "winner.test", port: 443), LightWalletEndpoint(address: "tail.test", port: 443)]
        let endpointSubmitter = ClosureEndpointSubmitter { endpoint in
            bothEntered.fulfill()
            if endpoint.host == "winner.test" { await winner.wait() } else { await tail.wait() }
            let tor = await flags.torEnabled
            XCTAssertFalse(tor, "Both halves of the admitted fanout retain the original route")
            if endpoint.host == "tail.test" { tailFinished.fulfill() }
        }
        mockContainer.mock(type: SDKFlags.self, isSingleton: true) { _ in flags }
        mockContainer.mock(type: MultiEndpointSubmitter.self, isSingleton: true) { _ in
            MultiEndpointSubmitter(endpointSubmitter: endpointSubmitter, logger: NullLogger())
        }
        let sync = try makeSlipstreamSynchronizer(engine: GatedFakeSlipstreamEngine())
        let send = Task {
            await sync.broadcaster.submit(
                transaction: CreatedTransaction(txId: Data(repeating: 1, count: 32), raw: Data([2]), expiryHeight: 0),
                to: endpoints, timing: SubmissionTiming(responseTimeout: 5, postAcceptanceGraceDelay: 5)
            )
        }
        await fulfillment(of: [bothEntered], timeout: 2)
        flags.routeAdmission.require(true)
        winner.open()
        let outcome = await send.value
        XCTAssertEqual(outcome, .accepted(by: endpoints[0]))
        do {
            try await flags.routeAdmission.drain(deadline: 0)
            XCTFail("Returning accepted must not release the still-running fanout tail")
        } catch {}
        tail.open()
        await fulfillment(of: [tailFinished], timeout: 2)
        try await flags.routeAdmission.drain(deadline: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
    }

    func testImportAfterTorFenceCannotProvisionOrWrite() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let welding = ZcashRustBackendWeldingMock()
        welding.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceReturnValue = TestsData.mockedAccountUUID
        let sync = try makeSlipstreamSynchronizer(engine: GatedFakeSlipstreamEngine(), welding: welding, restoreAnchor: { _, _, _, _, _, _ in
            calls.withLock { $0 += 1 }
            return nil
        })
        _ = sync.requestTorTransition(enabled: true)
        do {
            _ = try await sync.importAccount(
                ufvk: "viewing-key", seedFingerprint: nil, zip32AccountIndex: nil,
                purpose: .viewOnly, name: "Imported", keySource: nil, birthday: 3_000_000
            )
            XCTFail("A new import cannot provision behind the route fence")
        } catch {
            XCTAssertEqual(error as? TorTransitionState.Failure, .routeUnavailable)
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertEqual(welding.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceCallsCount, 0)
        await sync.stopAndWait()
    }

    func testAdmittedImportFinishesDirectAnchorBeforeTorStop() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let welding = ZcashRustBackendWeldingMock()
        welding.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceReturnValue = TestsData.mockedAccountUUID
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            freeRuntime: { _ in }, startup: TorRuntimeStartupNative.fixture { _, _ in OpaquePointer(bitPattern: 1) }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let entered = expectation(description: "import captured its anchor route")
        let release = Gate()
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding, restoreAnchor: { _, _, _, _, _, torDirectory in
            entered.fulfill()
            await release.wait()
            XCTAssertNil(torDirectory)
            let stopped = await engine.calls.contains("stop")
            XCTAssertFalse(stopped, "The route stop cannot pass admitted anchor dispatch")
            return nil
        })
        let importing = Task {
            try await sync.importAccount(
                ufvk: "viewing-key", seedFingerprint: nil, zip32AccountIndex: nil,
                purpose: .viewOnly, name: "Imported", keySource: nil, birthday: 3_000_000
            )
        }
        await fulfillment(of: [entered], timeout: 2)
        let request = sync.requestTorTransition(enabled: true)
        let applying = Task { try await request.apply() }
        let stopped = expectation(description: "stop remains behind admitted import provisioning")
        stopped.isInverted = true
        await engine.onCall("stop") { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 0.05)
        await engine.onCall("stop") {}
        release.open()
        _ = try await importing.value
        try await applying.value
        XCTAssertEqual(welding.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceCallsCount, 1)
        await sync.stopAndWait()
    }

    func testServerSelectionCannotProbePastRouteFence() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            startup: TorRuntimeStartupNative.fixture { _, _ in
                calls.withLock { $0 += 1 }
                return nil
            }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let sync = try makeSlipstreamSynchronizer(engine: GatedFakeSlipstreamEngine())
        _ = sync.requestTorTransition(enabled: true)
        let candidates = await sync.evaluateBestOf(endpoints: [LightWalletEndpointBuilder.default])
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertEqual(calls.withLock { $0 }, 0, "A new endpoint probe must not enter networking behind a route fence")
        await sync.stopAndWait()
    }

    func testOrdinaryHTTPEntryCannotBypassFence() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.closeGate(.stop)
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        let transition = sync.requestTorTransition(enabled: false)
        do {
            _ = try await sync.httpRequestOverOHTTP(for: URLRequest(url: URL(string: "https://unsupported.test")!), viaTor: false)
            XCTFail("Retired route must reject ordinary HTTP entry")
        } catch {
            XCTAssertEqual(error as? TorTransitionState.Failure, .routeUnavailable)
        }
        engine.stopGate.open()
        try await transition.apply()
    }

    func testRequestFencesButDoesNotApplyBeforeAppGuard() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.closeGate(.stop)
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        _ = sync.requestTorTransition(enabled: false)
        XCTAssertEqual(sync.lifecycleQueueDepthForTesting(), 0, "A dormant ticket must not apply behind the app guard")
        XCTAssertTrue(mockContainer.resolve(SDKFlags.self).routeAdmission.isFenced)
        engine.stopGate.open()
        await sync.stopAndWait()
    }

    func testOrdinaryStartDoesNotActivateDormantRouteRequest() async throws {
        for enabled in [false, true] {
            let engine = GatedFakeSlipstreamEngine()
            let sync = try makeSlipstreamSynchronizer(engine: engine)
            await sync.setInternalSyncStatusForTesting(.stopped)
            let request = sync.requestTorTransition(enabled: enabled)
            do {
                try await sync.start()
                XCTFail("Ordinary start cannot activate a ticket still waiting for the app guard")
            } catch { XCTAssertEqual(error as? TorTransitionState.Failure, .routeUnavailable) }
            XCTAssertEqual(sync.torTransitionState?.requestID, request.id)
            XCTAssertEqual(sync.torTransitionState?.phase, .waitingForWork)
            let calls = await engine.calls
            XCTAssertTrue(calls.isEmpty)
            request.cancelBeforeApplying()
            await sync.stopAndWait()
        }
    }

    func testOrdinaryStartQueuesBehindApplyingOffRequest() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.stopped)
        let enteredStop = expectation(description: "Explicit Off owns the lifecycle turn")
        await engine.closeGate(.stop)
        await engine.onCall("stop") { enteredStop.fulfill() }
        let request = sync.requestTorTransition(enabled: false)
        let applying = Task { try await request.apply() }
        await fulfillment(of: [enteredStop], timeout: 2)
        let depth = sync.lifecycleQueueDepthForTesting()
        let resume = Task { try await sync.start() }
        let queued = await waitUntil { sync.lifecycleQueueDepthForTesting() > depth }
        XCTAssertTrue(queued)
        XCTAssertEqual(sync.torTransitionState?.requestID, request.id)
        let heldCalls = await engine.calls
        XCTAssertEqual(heldCalls.filter { $0 == "stop" }.count, 1)
        XCTAssertFalse(heldCalls.contains("start"))
        await engine.openGate(.stop)
        try await applying.value
        try await resume.value
        XCTAssertEqual(sync.torTransitionState?.requestID, request.id)
        XCTAssertEqual(sync.torTransitionState?.phase, .ready)
        let finalCalls = await engine.calls
        XCTAssertEqual(finalCalls.filter { $0 == "start" }.count, 1)
        await sync.stopAndWait()
    }

    func testDormantExpiryCannotApplyAndBudgetDoesNotReset() async throws {
        let time = OSAllocatedUnfairLock(initialState: UInt64(100))
        let timer = Gate()
        let owner = TorRouteTransition(now: { time.withLock { $0 } }, sleep: { _ in
            await timer.wait()
            try Task.checkCancellation()
        })
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, torTransition: owner)
        let request = sync.requestTorTransition(enabled: false)
        time.withLock { $0 = 30_000_000_101 }
        do {
            try await request.apply()
            XCTFail("Applying must not renew a dormant ticket's acquisition budget")
        } catch { XCTAssertEqual(error as? TorTransitionState.Failure, .acquisitionTimedOut) }
        timer.open()
        let stops = await engine.calls.filter { $0 == "stop" }.count
        XCTAssertEqual(stops, 0, "An expired ticket has no ownership to tear down")
        XCTAssertEqual(sync.torTransitionState?.failure, .acquisitionTimedOut)
    }

    func testActiveAcquisitionExpiryRetiresNativePassWithoutCancellingAdmittedSend() async throws {
        try await assertFailedAcquisitionRetiresNativePass(activate: true, cancel: false)
    }

    func testNeverActivatedExpiryRetiresNativePassWithoutApplyingReplacement() async throws {
        try await assertFailedAcquisitionRetiresNativePass(activate: false, cancel: false)
    }

    func testDormantCancellationRetiresNativePassWithoutCancellingAdmittedSend() async throws {
        try await assertFailedAcquisitionRetiresNativePass(activate: false, cancel: true)
    }

    func testNonquiescentRetirementDoesNotFreeResourcesOrRewriteAcquisitionFailure() async throws {
        try await assertFailedAcquisitionRetiresNativePass(activate: true, cancel: false, nonquiescent: true)
    }

    private func assertFailedAcquisitionRetiresNativePass(activate: Bool, cancel: Bool, nonquiescent: Bool = false) async throws {
        let time = OSAllocatedUnfairLock(initialState: DispatchTime.now().uptimeNanoseconds)
        let timerEntered = expectation(description: "acquisition timer registered")
        let timer = Gate()
        let owner = TorRouteTransition(now: { time.withLock { $0 } }, sleep: { _ in
            timerEntered.fulfill()
            await timer.wait()
            try Task.checkCancellation()
        })
        let rootFrees = OSAllocatedUnfairLock(initialState: 0)
        let client = TorClient(runtimePtr: OpaquePointer(bitPattern: 1)!, torDir: testTempDirectory,
                               httpGetNative: TorHTTPGetNative(freeRuntime: { _ in rootFrees.withLock { $0 += 1 } }))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let sendEntered = expectation(description: "original direct broadcast admitted")
        let releaseSend = Gate()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let endpoint = LightWalletEndpoint(address: "admitted.test", port: 443)
        mockContainer.mock(type: MultiEndpointSubmitter.self, isSingleton: true) { container in
            let flags = container.resolve(SDKFlags.self)
            return MultiEndpointSubmitter(endpointSubmitter: ClosureEndpointSubmitter { _ in
                calls.withLock { $0 += 1 }
                sendEntered.fulfill()
                await releaseSend.wait()
                let usesTor = await flags.torEnabled
                XCTAssertFalse(usesTor, "Retirement must preserve the admitted broadcast's original route")
            }, logger: NullLogger())
        }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, torTransition: owner)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start()
        let service = mockContainer.resolve(LightWalletService.self) as! LightWalletServiceMock
        let send = Task {
            await sync.broadcaster.submit(
                transaction: CreatedTransaction(txId: Data(repeating: 3, count: 32), raw: Data([1]), expiryHeight: 0),
                to: [endpoint], timing: SubmissionTiming(responseTimeout: 5, postAcceptanceGraceDelay: 0)
            )
        }
        await fulfillment(of: [sendEntered], timeout: 2)
        let retirementEntered = expectation(description: "failed acquisition owns native retirement")
        await engine.onCall("stop") { retirementEntered.fulfill() }
        engine.stopGate.close()
        if nonquiescent { engine.stopReport = .passStillRunning }
        let request = sync.requestTorTransition(enabled: true)
        await fulfillment(of: [timerEntered], timeout: 2)
        let applying: Task<Void, Error>? = activate ? Task { try await request.apply() } : nil
        if activate {
            let queued = await waitUntil { sync.lifecycleQueueDepthForTesting() > 0 }
            XCTAssertTrue(queued)
        }
        if cancel {
            XCTAssertTrue(request.cancelBeforeApplying())
        } else {
            time.withLock { $0 += 30_000_000_001 }
            timer.open()
        }
        let observerFinished = expectation(description: "terminal observer does not wait for held native retirement")
        let observer = Task {
            defer { observerFinished.fulfill() }
            do {
                try await request.wait()
                XCTFail("Failed acquisition must finish its observer before native cleanup returns")
            } catch {
                if cancel { XCTAssertTrue(error is CancellationError) } else {
                    XCTAssertEqual(error as? TorTransitionState.Failure, .acquisitionTimedOut)
                }
            }
        }
        await fulfillment(of: [observerFinished, retirementEntered], timeout: 0.2)
        XCTAssertTrue(mockContainer.resolve(SDKFlags.self).routeAdmission.isFenced)
        XCTAssertEqual(rootFrees.withLock { $0 }, 0)
        XCTAssertEqual(service.closeConnectionsCallsCount, 0)
        let heldCalls = await engine.calls
        XCTAssertFalse(heldCalls.contains("startTor"))
        XCTAssertFalse(heldCalls.contains("close"))
        releaseSend.open()
        let outcome = await send.value
        XCTAssertEqual(outcome, .accepted(by: endpoint))
        XCTAssertEqual(calls.withLock { $0 }, 1)
        engine.stopGate.open()
        timer.open()
        _ = await applying?.result
        await observer.value
        let drained = await waitUntil { sync.lifecycleQueueDepthForTesting() == 0 }
        XCTAssertTrue(drained)
        let running = await sync.isRunningForTesting()
        XCTAssertFalse(running, "The failed choice must not leave the old native request loop running")
        let retiredCalls = await engine.calls
        XCTAssertTrue(retiredCalls.contains("stop:done"))
        XCTAssertFalse(retiredCalls.contains("close"))
        XCTAssertFalse(retiredCalls.contains(where: { $0.hasPrefix("reopen") }))
        XCTAssertEqual(sync.torTransitionState?.phase, cancel ? .cancelled : .failed)
        if !cancel { XCTAssertEqual(sync.torTransitionState?.failure, .acquisitionTimedOut) }
        do {
            try await request.apply()
            XCTFail("Retirement cannot reactivate an expired/cancelled replacement")
        } catch {
            if cancel { XCTAssertTrue(error is CancellationError) } else {
                XCTAssertEqual(error as? TorTransitionState.Failure, .acquisitionTimedOut)
            }
        }
        await sync.stopAndWait()
    }

    func testDelayedFailedRetirementCannotStopInstalledSuccessorAndRetryKeepsIntent() async throws {
        let rootFrees = OSAllocatedUnfairLock(initialState: 0)
        let client = TorClient(runtimePtr: OpaquePointer(bitPattern: 1)!, torDir: testTempDirectory,
                               httpGetNative: TorHTTPGetNative(freeRuntime: { _ in rootFrees.withLock { $0 += 1 } }))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start()
        let failed = sync.requestTorTransition(enabled: true)
        XCTAssertTrue(failed.cancelBeforeApplying())
        let retired = await waitUntil { sync.lifecycleQueueDepthForTesting() == 0 }
        XCTAssertTrue(retired)
        let stopped = await sync.isRunningForTesting()
        XCTAssertFalse(stopped)
        let successor = sync.requestTorTransition(enabled: true)
        XCTAssertNotEqual(successor.id, failed.id)
        try await successor.apply()
        let resumed = await sync.isRunningForTesting()
        XCTAssertTrue(resumed, "Native-only retirement preserves intended-running state for explicit retry")
        let stopsBeforeDelayedCleanup = await engine.calls.filter { $0 == "stop" }.count
        // A newer dormant choice fences again without retiring this successful successor yet.
        // Deliver the older request's cleanup late through the actual lifecycle entry point.
        let latest = sync.requestTorTransition(enabled: false)
        await sync.scheduleTorRetirement(failed).value
        let stopsAfterDelayedCleanup = await engine.calls.filter { $0 == "stop" }.count
        XCTAssertEqual(stopsAfterDelayedCleanup, stopsBeforeDelayedCleanup)
        let stillRunning = await sync.isRunningForTesting()
        XCTAssertTrue(stillRunning, "A stale predecessor token cannot stop a newly installed pass")
        XCTAssertEqual(sync.torTransitionState?.requestID, latest.id)
        XCTAssertEqual(sync.torTransitionState?.phase, .waitingForWork)
        XCTAssertEqual(rootFrees.withLock { $0 }, 0)
        do {
            try await failed.wait()
            XCTFail("Retirement and successor success cannot rewrite the old terminal result")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(latest.cancelBeforeApplying())
        await sync.stopAndWait()
    }

    func testNativeStartupCancellationRemainsCancellationError() async throws {
        let client = TorClient(runtimePtr: OpaquePointer(bitPattern: 1)!, torDir: testTempDirectory,
                               httpGetNative: TorHTTPGetNative(freeRuntime: { _ in }))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start()
        await engine.setStartError(CancellationError())
        do {
            try await sync.tor(enabled: true)
            XCTFail("Cancelled native startup cannot succeed")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(sync.torTransitionState?.phase, .cancelled)
        await sync.stopAndWait()
    }

    func testHTTPStartupTimeoutReturnsTypedFailure() async throws {
        var startup = TorRuntimeStartupNative.fixture { _, _ in nil }
        startup.wait = { _ in 3 }
        startup.take = { _ in FfiTorStartupResultV1(status: 3, runtime: nil) }
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(startup: startup))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let sync = try makeSlipstreamSynchronizer(engine: GatedFakeSlipstreamEngine())
        do {
            try await sync.tor(enabled: true)
            XCTFail("HTTP timeout must fail startup")
        } catch { XCTAssertEqual(error as? TorTransitionState.Failure, .startupTimedOut) }
        XCTAssertEqual(sync.torTransitionState?.failure, .startupTimedOut)
        await sync.stopAndWait()
    }

    func testNativeStartupTimeoutReturnsTypedFailure() async throws {
        let client = TorClient(runtimePtr: OpaquePointer(bitPattern: 1)!, torDir: testTempDirectory,
                               httpGetNative: TorHTTPGetNative(freeRuntime: { _ in }))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start()
        await engine.setStartError(URLError(.timedOut))
        do {
            try await sync.requestTorTransition(enabled: true).apply()
            XCTFail("Native timeout must fail startup")
        } catch { XCTAssertEqual(error as? TorTransitionState.Failure, .startupTimedOut) }
        XCTAssertEqual(sync.torTransitionState?.failure, .startupTimedOut)
        await sync.stopAndWait()
    }

    func testJoinersActivateOnceAndWaiterCancellationDoesNotCancelOwner() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.closeGate(.stop)
        let entered = expectation(description: "owner acquired lifecycle")
        await engine.onCall("stop") { entered.fulfill() }
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        let request = sync.requestTorTransition(enabled: false)
        let first = Task { try await request.apply() }
        await fulfillment(of: [entered], timeout: 2)
        let joined = sync.requestTorTransition(enabled: false)
        XCTAssertEqual(request.id, joined.id)
        XCTAssertFalse(joined.cancelBeforeApplying())
        let second = Task { try await joined.apply() }
        let cancelled = expectation(description: "only the observer cancels")
        let observer = Task {
            do {
                try await request.wait()
                XCTFail("Cancelled observer must stop waiting")
            } catch is CancellationError { cancelled.fulfill() } catch { XCTFail("Unexpected failure") }
        }
        observer.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        engine.stopGate.open()
        try await first.value
        try await second.value
        let stops = await engine.calls.filter { $0 == "stop" }.count
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(sync.torTransitionState?.phase, .ready)
    }

    func testRapidOnOffOnLatestChoiceRestartsOriginalIntent() async throws {
        let creations = OSAllocatedUnfairLock(initialState: 0)
        let frees = OSAllocatedUnfairLock(initialState: 0)
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            freeRuntime: { _ in frees.withLock { $0 += 1 } },
            startup: TorRuntimeStartupNative.fixture { _, _ in
                creations.withLock { $0 += 1 }
                return OpaquePointer(bitPattern: 1)
            }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        engine.torStartup.ready.close()
        let entered = expectation(description: "first native start")
        await engine.onCall("startTor") { entered.fulfill() }
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start()
        let first = sync.requestTorTransition(enabled: true)
        let firstApply = Task { try await first.apply() }
        await fulfillment(of: [entered], timeout: 2)
        // Hold actor admission after the old HTTP owner is ready. Its cancellation close
        // must finish under the old lifecycle slot before the next On can start.
        try await client.prepare()
        let actorHeld = expectation(description: "HTTP actor held before cancellation close")
        let releaseActor = DispatchSemaphore(value: 0)
        let blocker = Task { await client.holdRouteTransitionAdmission(entered: actorHeld, release: releaseActor) }
        await fulfillment(of: [actorHeld], timeout: 2)
        let off = sync.requestTorTransition(enabled: false)
        XCTAssertTrue(engine.torStartup.isCancelled, "Off cancels startup before it acquires the app guard")
        let latest = sync.requestTorTransition(enabled: true)
        XCTAssertNotEqual(latest.id, first.id)
        _ = await firstApply.result
        let latestApply = Task { try await latest.apply() }
        XCTAssertNotEqual(sync.torTransitionState?.phase, .ready)
        releaseActor.signal()
        await blocker.value
        try await latestApply.value
        try await client.prepare()
        XCTAssertEqual(creations.withLock { $0 }, 2)
        XCTAssertEqual(frees.withLock { $0 }, 1, "No late close may retire the replacement runtime")
        do {
            try await off.apply()
            XCTFail("A superseded dormant ticket must never apply")
        } catch {}
        XCTAssertEqual(sync.torTransitionState?.requestID, latest.id)
        XCTAssertEqual(sync.torTransitionState?.phase, .ready)
        XCTAssertTrue(sync.latestState.internalSyncStatus.isSyncing)
        await sync.stopAndWait()
    }

    func testOrdinaryStartRecoversStoppedPendingHTTPStartup() async throws {
        try await assertOrdinaryStartRecoversRetainedTorIntent(pendingHTTP: true, failBeforeStop: false)
    }

    func testOrdinaryStartRecoversStoppedPendingNativeStartup() async throws {
        try await assertOrdinaryStartRecoversRetainedTorIntent(pendingHTTP: false, failBeforeStop: false)
    }

    func testOrdinaryStartRecoversTorFailureBeforeBackground() async throws {
        try await assertOrdinaryStartRecoversRetainedTorIntent(pendingHTTP: false, failBeforeStop: true)
    }

    private func assertOrdinaryStartRecoversRetainedTorIntent(pendingHTTP: Bool, failBeforeStop: Bool) async throws {
        let httpEntered = failBeforeStop ? nil : expectation(description: "HTTP startup entered")
        let releaseHTTP = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            freeRuntime: { _ in }, startup: TorRuntimeStartupNative.fixture { _, _ in
                let first = calls.withLock { count in
                    count += 1
                    return count == 1
                }
                if first {
                    httpEntered?.fulfill()
                    if pendingHTTP { _ = releaseHTTP.wait(timeout: .now() + 5) }
                }
                return OpaquePointer(bitPattern: 1)
            }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.stopped)
        try await sync.start()
        if !pendingHTTP && !failBeforeStop { engine.torStartup.ready.close() }
        if failBeforeStop { await engine.setStartError(ZcashError.rustSlipstreamStart("synthetic startup failure")) }
        let enable = Task { try await sync.tor(enabled: true) }
        if let httpEntered { await fulfillment(of: [httpEntered], timeout: 2) }
        if failBeforeStop {
            do {
                try await enable.value
                XCTFail("Initial native startup must fail")
            } catch { XCTAssertEqual(error as? TorTransitionState.Failure, .startupFailed) }
        } else if !pendingHTTP {
            await engine.torStartup.entered.wait()
        }
        let previous = sync.torTransitionState
        sync.stop()
        releaseHTTP.signal()
        _ = await enable.result
        await sync.stopAndWait()
        XCTAssertTrue(mockContainer.resolve(SDKFlags.self).routeAdmission.isFenced)
        XCTAssertFalse(sync.latestState.internalSyncStatus.isSyncing)
        await engine.setStartError(nil)
        let startsBeforeResume = await engine.calls.filter { $0 == "startTor" }.count
        do {
            try await sync.start()
        } catch {
            XCTFail("Ordinary resume must revalidate retained Tor intent: \(error)")
        }
        XCTAssertNotEqual(sync.torTransitionState?.requestID, previous?.requestID)
        XCTAssertEqual(sync.torTransitionState?.phase, .ready)
        XCTAssertEqual(sync.torTransitionState?.requestedEnabled, true)
        XCTAssertTrue(sync.latestState.internalSyncStatus.isSyncing)
        let torStarts = await engine.calls.filter { $0 == "startTor" }.count
        XCTAssertEqual(torStarts, startsBeforeResume + 1, "Resume must start a fresh Tor run, never Direct")
        XCTAssertFalse(mockContainer.resolve(SDKFlags.self).routeAdmission.isFenced)
        await sync.stopAndWait()
        try await client.close()
    }

    func testOrdinaryResumeReconcilesFailedPublishedSwitchBeforeTorStartup() async throws {
        try await assertFailedPublishedSwitchReconciles(explicitTorRetry: false)
    }

    func testExplicitTorRetryReconcilesFailedPublishedSwitchBeforeStartup() async throws {
        try await assertFailedPublishedSwitchReconciles(explicitTorRetry: true)
    }

    func testRestartReconcilesFailedPublishedEndpointBeforeOrdinaryStart() async throws {
        try await assertFailedPublishedSwitchReconciles(explicitTorRetry: false, restart: true)
    }

    private func assertFailedPublishedSwitchReconciles(explicitTorRetry: Bool, restart: Bool = false) async throws {
        let original = LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443, secure: true)
        let candidate = LightWalletEndpoint(address: "public.example.com", port: 443, secure: true)
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            freeRuntime: { _ in }, startup: TorRuntimeStartupNative.fixture { _, _ in OpaquePointer(bitPattern: 1) }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: original)
        await sync.setInternalSyncStatusForTesting(.stopped)
        try await sync.tor(enabled: true)
        try await sync.start()
        await engine.setStartError(ZcashError.rustSlipstreamStart("fast startup failure after reopen"))
        do {
            if restart { try await sync.restartSync(at: candidate) } else { try await sync.switchTo(endpoint: candidate) }
            XCTFail("The published switch must report the Tor startup failure")
        } catch { XCTAssertEqual(error as? TorTransitionState.Failure, .startupFailed) }
        let published = await sync.currentEndpointForTesting()
        XCTAssertEqual(published, candidate, "Regression must cross actual SDK endpoint publication")
        XCTAssertTrue(mockContainer.resolve(SDKFlags.self).routeAdmission.isFenced)
        await engine.setReopenError(URLError(.cannotConnectToHost))
        do {
            try await sync.switchTo(endpoint: original)
            XCTFail("The app's move-back cannot reopen the original endpoint yet")
        } catch {}
        await engine.setStartError(nil)
        let beforeRetry = await engine.calls.filter { $0 == "start" }.count
        do {
            if explicitTorRetry { try await sync.tor(enabled: true) } else { try await sync.start() }
            XCTFail("Unreconciled endpoint must refuse every Tor restart entry point")
        } catch {}
        let afterRetry = await engine.calls.filter { $0 == "start" }.count
        XCTAssertEqual(afterRetry, beforeRetry, "No native startup may revive the unrecorded public route")
        XCTAssertTrue(mockContainer.resolve(SDKFlags.self).routeAdmission.isFenced)
        XCTAssertTrue(mockContainer.resolve(SDKFlags.self).routeAdmission.selectedTor)
        XCTAssertFalse(sync.latestState.internalSyncStatus.isSyncing)
        await engine.setReopenError(nil)
        if explicitTorRetry { try await sync.tor(enabled: true) }
        try await sync.start()
        let restored = await sync.currentEndpointForTesting()
        XCTAssertEqual(restored, original)
        XCTAssertEqual(sync.torTransitionState?.phase, .ready)
        XCTAssertTrue(sync.latestState.internalSyncStatus.isSyncing)
        let calls = await engine.calls
        XCTAssertTrue(calls.contains("reopen(\(original.host):443)"))
        await sync.stopAndWait()
        try await client.close()
    }

    func testOffSupersedingFailedSwitchRetainsEndpointRecovery() async throws {
        let original = LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443, secure: true)
        let candidate = LightWalletEndpoint(address: "public.example.com", port: 443, secure: true)
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            freeRuntime: { _ in }, startup: TorRuntimeStartupNative.fixture { _, _ in OpaquePointer(bitPattern: 1) }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: original)
        await sync.setInternalSyncStatusForTesting(.stopped)
        try await sync.tor(enabled: true)
        try await sync.start()
        await engine.onCall("startTor") { _ = sync.requestTorTransition(enabled: false) }
        await engine.setStartError(ZcashError.rustSlipstreamStart("superseded startup failure"))
        do {
            try await sync.switchTo(endpoint: candidate)
            XCTFail("Superseded restart must fail")
        } catch {}
        XCTAssertFalse(mockContainer.resolve(SDKFlags.self).routeAdmission.selectedTor)
        await engine.setReopenError(URLError(.cannotConnectToHost))
        do {
            try await sync.switchTo(endpoint: original)
            XCTFail("Move back is still unavailable")
        } catch {}
        await engine.setStartError(nil)
        do {
            try await sync.start()
            XCTFail("Ordinary Off resume cannot bypass failed endpoint restoration")
        } catch {}
        do {
            try await sync.tor(enabled: false)
            XCTFail("Explicit Off must also restore the endpoint before admitting Direct")
        } catch {}
        XCTAssertTrue(mockContainer.resolve(SDKFlags.self).routeAdmission.isFenced)
        XCTAssertFalse(mockContainer.resolve(SDKFlags.self).routeAdmission.selectedTor)
        await engine.setReopenError(nil)
        try await sync.start()
        let endpoint = await sync.currentEndpointForTesting()
        XCTAssertEqual(endpoint, original)
        XCTAssertEqual(sync.torTransitionState?.requestedEnabled, false)
        XCTAssertTrue(sync.latestState.internalSyncStatus.isSyncing)
        await sync.stopAndWait()
        try await client.close()
    }

    func testOffDuringSwitchReopenRetainsFailedPublicationRecovery() async throws {
        try await assertFailedPublicationRecoveryAfterReopen(restart: false, newerChoice: false)
    }

    func testOffDuringRestartReopenRetainsFailedPublicationRecovery() async throws {
        try await assertFailedPublicationRecoveryAfterReopen(restart: true, newerChoice: false)
    }

    func testOffDuringSwitchReopenAllowsNewExplicitEndpoint() async throws {
        try await assertFailedPublicationRecoveryAfterReopen(restart: false, newerChoice: true)
    }

    func testOffDuringRestartReopenAllowsNewExplicitEndpoint() async throws {
        try await assertFailedPublicationRecoveryAfterReopen(restart: true, newerChoice: true)
    }

    func testDirectStartupFailureRetainsFailedPublicationRecovery() async throws {
        try await assertFailedPublicationRecoveryAfterReopen(restart: false, newerChoice: false, offDuringReopen: false)
    }

    private func assertFailedPublicationRecoveryAfterReopen(
        restart: Bool,
        newerChoice: Bool,
        offDuringReopen: Bool = true
    ) async throws {
        let original = LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443, secure: true)
        let candidate = LightWalletEndpoint(address: "public.example.com", port: 443, secure: true)
        let replacement = LightWalletEndpoint(address: "replacement.example.com", port: 443, secure: true)
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            freeRuntime: { _ in }, startup: TorRuntimeStartupNative.fixture { _, _ in OpaquePointer(bitPattern: 1) }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: original)
        let admission = mockContainer.resolve(SDKFlags.self).routeAdmission
        await sync.setInternalSyncStatusForTesting(.stopped)
        if offDuringReopen { try await sync.tor(enabled: true) }
        try await sync.start()
        let enteredReopen = expectation(description: "Candidate reopen suspended before endpoint publication")
        await engine.closeGate(.reopen)
        await engine.onCall("reopen") { enteredReopen.fulfill() }
        let change = Task {
            if restart { try await sync.restartSync(at: candidate) } else { try await sync.switchTo(endpoint: candidate) }
        }
        await fulfillment(of: [enteredReopen], timeout: 2)
        let beforePublication = await sync.currentEndpointForTesting()
        XCTAssertEqual(beforePublication, original)
        if offDuringReopen {
            _ = sync.requestTorTransition(enabled: false)
            XCTAssertTrue(admission.isFenced)
        } else {
            await engine.setStartError(ZcashError.rustSlipstreamStart("Direct restart failed after publication"))
        }
        XCTAssertFalse(admission.selectedTor)
        await engine.openGate(.reopen)
        do {
            try await change.value
            XCTFail("The required restart after candidate publication must fail")
        } catch {
            if offDuringReopen { XCTAssertEqual(error as? TorTransitionState.Failure, .routeUnavailable) }
        }
        let published = await sync.currentEndpointForTesting()
        XCTAssertEqual(published, candidate)
        XCTAssertTrue(admission.isFenced, "Every failed required restart fences the unaccepted endpoint")
        XCTAssertThrowsError(try admission.acquire(), "New requests must not use the unaccepted route")
        await engine.setStartError(nil)
        await engine.setReopenError(URLError(.cannotConnectToHost))
        do {
            try await sync.switchTo(endpoint: original)
            XCTFail("The captured original endpoint cannot yet be restored")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
        let afterRollbackFailure = await sync.currentEndpointForTesting()
        XCTAssertEqual(afterRollbackFailure, candidate)
        let callsBeforeResume = await engine.calls
        for explicitOff in [false, true] {
            do {
                if explicitOff { try await sync.tor(enabled: false) } else { try await sync.start() }
                XCTFail("Neither ordinary resume nor Off may admit the unrecorded public endpoint")
            } catch {}
            XCTAssertTrue(admission.isFenced)
            XCTAssertFalse(admission.selectedTor, "Endpoint recovery must preserve the newest Off intent")
        }
        let callsAfterResume = await engine.calls
        XCTAssertEqual(callsAfterResume.filter { $0 == "start" }, callsBeforeResume.filter { $0 == "start" })
        XCTAssertThrowsError(try admission.acquire())
        XCTAssertFalse(sync.latestState.internalSyncStatus.isSyncing)
        await engine.setReopenError(nil)
        let expected = newerChoice ? replacement : original
        if newerChoice { try await sync.switchTo(endpoint: replacement) }
        try await sync.start()
        let recovered = await sync.currentEndpointForTesting()
        XCTAssertEqual(recovered, expected)
        XCTAssertFalse(admission.selectedTor)
        XCTAssertFalse(admission.isFenced)
        XCTAssertTrue(sync.latestState.internalSyncStatus.isSyncing)
        let finalCalls = await engine.calls
        let lastReopen = try XCTUnwrap(finalCalls.lastIndex { $0 == "reopen(\(expected.host):443)" })
        let lastStart = try XCTUnwrap(finalCalls.lastIndex(of: "start"))
        XCTAssertLessThan(lastReopen, lastStart, "Only the restored or newer explicitly accepted route can restart")
        await sync.stopAndWait()
        try await client.close()
    }

    func testNewExplicitEndpointChoiceRetiresFailedSwitchRecovery() async throws {
        try await assertRecoveryRetiresAtWalletOrRouteReplacement(wipeWallet: false)
    }

    func testWipeRetiresFailedSwitchRecoveryWithoutReopeningOldWallet() async throws {
        try await assertRecoveryRetiresAtWalletOrRouteReplacement(wipeWallet: true)
    }

    private func assertRecoveryRetiresAtWalletOrRouteReplacement(wipeWallet: Bool) async throws {
        let original = LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443, secure: true)
        let candidate = LightWalletEndpoint(address: "public.example.com", port: 443, secure: true)
        let replacement = LightWalletEndpoint(address: "replacement.example.com", port: 443, secure: true)
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            freeRuntime: { _ in }, startup: TorRuntimeStartupNative.fixture { _, _ in OpaquePointer(bitPattern: 1) }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: original)
        await sync.setInternalSyncStatusForTesting(.stopped)
        try await sync.tor(enabled: true)
        try await sync.start()
        await engine.setStartError(ZcashError.rustSlipstreamStart("startup failure after publication"))
        do {
            try await sync.switchTo(endpoint: candidate)
            XCTFail("Initial published switch must fail")
        } catch { XCTAssertEqual(error as? TorTransitionState.Failure, .startupFailed) }
        await engine.setStartError(nil)
        if wipeWallet {
            for try await _ in sync.wipe().values {}
            let previousCalls = await engine.calls
            try await sync.tor(enabled: true)
            let calls = await engine.calls
            XCTAssertEqual(calls.filter { $0.hasPrefix("reopen(") }, previousCalls.filter { $0.hasPrefix("reopen(") })
            XCTAssertFalse(sync.latestState.internalSyncStatus.isPrepared)
        } else {
            try await sync.switchTo(endpoint: replacement)
            try await sync.start()
            let endpoint = await sync.currentEndpointForTesting()
            XCTAssertEqual(endpoint, replacement, "A stale restoration target cannot override a newer successful explicit choice")
            XCTAssertTrue(sync.latestState.internalSyncStatus.isSyncing)
            await sync.stopAndWait()
        }
        try await client.close()
    }

    func testIdleAndUnpreparedDoNotStartNativeWork() async throws {
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            freeRuntime: { _ in }, startup: TorRuntimeStartupNative.fixture { _, _ in OpaquePointer(bitPattern: 1) }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        try await sync.tor(enabled: true)
        XCTAssertFalse(sync.latestState.internalSyncStatus.isPrepared)
        await sync.setInternalSyncStatusForTesting(.stopped)
        try await sync.tor(enabled: false)
        try await sync.tor(enabled: true)
        let starts = await engine.calls.filter { $0 == "start" || $0 == "startTor" }
        XCTAssertEqual(starts, [])
        try await client.close()
    }

    func testNonquiescentEnableDoesNotRestartDirect() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start()
        engine.stopReport = SlipstreamStopReport(settled: false, drained: true, settleWait: .seconds(10), drainWait: .zero)
        do {
            try await sync.tor(enabled: true)
            XCTFail("Nonquiescence must refuse the route change")
        } catch { XCTAssertEqual(error as? TorTransitionState.Failure, .nonquiescent) }
        let starts = await engine.calls.filter { $0 == "start" }.count
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(mockContainer.resolve(SDKFlags.self).routeAdmission.isFenced)
        let tor = await mockContainer.resolve(SDKFlags.self).torEnabled
        XCTAssertTrue(tor)
        XCTAssertEqual(sync.ohttpHealthBinding?.snapshot().phase, .replacing)
        await sync.stopAndWait()
    }

    func testSwiftPendingPreventsReadyAndSyncPublication() async throws {
        let entered = expectation(description: "HTTP bootstrap entered")
        let nativeEntered = expectation(description: "native session entered")
        let release = DispatchSemaphore(value: 0)
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            freeRuntime: { _ in }, startup: TorRuntimeStartupNative.fixture { _, _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return OpaquePointer(bitPattern: 1)
            }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start()
        await engine.onCall("startTor") { nativeEntered.fulfill() }
        let enable = Task { try await sync.tor(enabled: true) }
        await fulfillment(of: [entered, nativeEntered], timeout: 2)
        XCTAssertEqual(sync.torTransitionState?.phase, .starting)
        XCTAssertFalse(sync.latestState.internalSyncStatus.isSyncing, "The stopped pass cannot remain published as syncing")
        release.signal()
        try await enable.value
        XCTAssertTrue(sync.latestState.internalSyncStatus.isSyncing)
        await sync.stopAndWait()
    }

    func testAdmittedSubmissionKeepsRecoveryRouteAfterGuardCancellation() async throws {
        let sync = try makeSlipstreamSynchronizer(engine: GatedFakeSlipstreamEngine())
        let service = mockContainer.resolve(LightWalletService.self) as! LightWalletServiceMock
        service.latestBlockHeightModeReturnValue = 3_543_404
        let entered = expectation(description: "broadcast admitted")
        let release = Gate()
        service.submitSpendTransactionModeClosure = { _, mode in
            XCTAssertEqual(mode, .direct)
            entered.fulfill()
            await release.wait()
            var rejected = SendResponse()
            rejected.errorCode = -25
            return rejected
        }
        service.fetchTransactionTxIdModeClosure = { _, mode in
            XCTAssertEqual(mode, .direct, "Outcome recovery belongs to the original admitted route")
            return (tx: nil, status: .mined(3_543_404))
        }
        let txID = Data(repeating: 9, count: 32)
        let stream = await sync.submitTransactions([CreatedTransaction(txId: txID, raw: Data([1]), expiryHeight: 0)])
        let send = Task {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        await fulfillment(of: [entered], timeout: 2)
        let choice = sync.requestTorTransition(enabled: true)
        XCTAssertTrue(choice.cancelBeforeApplying(), "Failure to acquire the host guard cancels only the dormant ticket")
        release.open()
        guard case .success(let receivedID) = try await send.value else { return XCTFail("A known transaction remains a business success") }
        XCTAssertEqual(receivedID, txID)
        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 1)
        XCTAssertEqual(service.fetchTransactionTxIdModeCallsCount, 1)
        XCTAssertTrue(mockContainer.resolve(SDKFlags.self).routeAdmission.isFenced)
    }

    func testNativeFailureFencesDirectAndRetryUsesNewIdentity() async throws {
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            freeRuntime: { _ in }, startup: TorRuntimeStartupNative.fixture { _, _ in OpaquePointer(bitPattern: 1) }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start()
        await engine.setStartError(ZcashError.rustSlipstreamStart("synthetic startup failure"))
        let first = sync.requestTorTransition(enabled: true)
        do {
            try await first.apply()
            XCTFail("Native failure cannot become ready")
        } catch { XCTAssertEqual(error as? TorTransitionState.Failure, .startupFailed) }
        XCTAssertEqual(sync.torTransitionState?.phase, .failed)
        XCTAssertEqual(sync.torTransitionState?.failure, .startupFailed)
        XCTAssertTrue(mockContainer.resolve(SDKFlags.self).routeAdmission.isFenced)
        let tor = await mockContainer.resolve(SDKFlags.self).torEnabled
        XCTAssertTrue(tor)
        await engine.setStartError(nil)
        let retry = sync.requestTorTransition(enabled: true)
        XCTAssertNotEqual(retry.id, first.id)
        try await retry.apply()
        XCTAssertEqual(sync.torTransitionState?.phase, .ready)
        XCTAssertTrue(sync.latestState.internalSyncStatus.isSyncing)
        await sync.stopAndWait()
    }

    func testIdleEnableThenNormalStartPublishesCurrentNativeFailure() async throws {
        try await assertLaterNormalStartError(ZcashError.rustSlipstreamStart("synthetic normal-start failure"), expected: .startupFailed)
    }

    func testIdleEnableThenNormalStartReturnsTypedTimeout() async throws {
        try await assertLaterNormalStartError(URLError(.timedOut), expected: .startupTimedOut)
    }

    private func assertLaterNormalStartError(_ error: Error, expected: TorTransitionState.Failure) async throws {
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            freeRuntime: { _ in }, startup: TorRuntimeStartupNative.fixture { _, _ in OpaquePointer(bitPattern: 1) }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.stopped)
        try await sync.tor(enabled: true)
        let previous = sync.torTransitionState
        await engine.setStartError(error)
        do {
            try await sync.start()
            XCTFail("Required native startup fails")
        } catch { XCTAssertEqual(error as? TorTransitionState.Failure, expected) }
        XCTAssertEqual(sync.torTransitionState?.phase, .failed)
        XCTAssertEqual(sync.torTransitionState?.failure, expected)
        XCTAssertNotEqual(sync.torTransitionState?.generation, previous?.generation)
        let initialized = await sync.isTorSuccessfullyInitialized()
        XCTAssertEqual(initialized, false)
        await sync.stopAndWait()
    }

    func testIdleEnableThenNormalStartPublishesPendingAndReadyWithoutChangingTicketResult() async throws {
        try await assertLaterNormalStart(cancel: false)
    }

    func testStopDuringLaterNormalStartRejectsLateReadiness() async throws {
        try await assertLaterNormalStart(cancel: true)
    }

    private func assertLaterNormalStart(cancel: Bool) async throws {
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(
            freeRuntime: { _ in }, startup: TorRuntimeStartupNative.fixture { _, _ in OpaquePointer(bitPattern: 1) }
        ))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.stopped)
        let choice = sync.requestTorTransition(enabled: true)
        try await choice.apply()
        let idleState = sync.torTransitionState
        engine.torStartup.ready.close()
        let start = Task { try await sync.start() }
        await engine.torStartup.entered.wait()
        XCTAssertEqual(sync.torTransitionState?.phase, .starting)
        XCTAssertNotEqual(sync.torTransitionState?.generation, idleState?.generation)
        let pending = await sync.isTorSuccessfullyInitialized()
        XCTAssertNil(pending)
        XCTAssertFalse(sync.latestState.internalSyncStatus.isSyncing)
        try await choice.wait()
        if cancel {
            let cleanupEntered = expectation(description: "startup cleanup owns lifecycle")
            let priorStops = await engine.calls.filter { $0 == "stop" }.count
            engine.stopGate.close()
            await engine.onCall("stop") { cleanupEntered.fulfill() }
            sync.stop()
            await fulfillment(of: [cleanupEntered], timeout: 2)
            // The fake holds cleanup indefinitely; this interval only checks absence of entry.
            try await Task.sleep(nanoseconds: 50_000_000)
            let heldStops = await engine.calls.filter { $0 == "stop" }.count
            XCTAssertEqual(heldStops, priorStops + 1, "The lifecycle slot must remain owned through startup cleanup")
            engine.stopGate.open()
            await sync.stopAndWait()
            engine.torStartup.ready.open()
            do {
                try await start.value
                XCTFail("Stopped startup cannot become ready")
            } catch {}
            XCTAssertEqual(sync.torTransitionState?.phase, .cancelled)
            XCTAssertFalse(sync.latestState.internalSyncStatus.isSyncing)
        } else {
            engine.torStartup.ready.open()
            try await start.value
            XCTAssertEqual(sync.torTransitionState?.phase, .ready)
            let ready = await sync.isTorSuccessfullyInitialized()
            XCTAssertEqual(ready, true)
            XCTAssertTrue(sync.latestState.internalSyncStatus.isSyncing)
            await sync.stopAndWait()
        }
        try await choice.wait()
    }

    func testFencedBroadcasterRetainsCreatedRetryPlanWithoutResurrectingWipe() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        mockContainer.mock(type: MultiEndpointSubmitter.self, isSingleton: true) { _ in
            MultiEndpointSubmitter(endpointSubmitter: ClosureEndpointSubmitter { _ in
                calls.withLock { $0 += 1 }
            }, logger: NullLogger())
        }
        let sync = try makeSlipstreamSynchronizer(engine: GatedFakeSlipstreamEngine())
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let tx = CreatedTransaction(txId: Data(repeating: 7, count: 32), raw: Data([1]), expiryHeight: 0)
        let endpoints = [LightWalletEndpoint(address: "intended.test", port: 443)]
        let lifecycle = await store.currentLifecycle()
        await store.markAwaitingSubmission(txIds: [tx.txId], lifecycle: lifecycle)
        _ = sync.requestTorTransition(enabled: true)
        let outcome = await sync.broadcaster.submit(transaction: tx, to: endpoints, timing: .default)
        XCTAssertEqual(outcome, .unreachable)
        let plan = await store.plan(for: tx.txId)
        XCTAssertEqual(plan, .ready(endpoints, acceptedBy: nil))
        await store.wipe()
        let repeated = await sync.broadcaster.submit(transaction: tx, to: endpoints, timing: .default)
        XCTAssertEqual(repeated, .unreachable)
        let afterWipe = await store.plan(for: tx.txId)
        XCTAssertNil(afterWipe)
        XCTAssertEqual(calls.withLock { $0 }, 0)
        await sync.stopAndWait()
    }

    func testNativeCapabilityRetainsUpperGenerationAndTimeout() throws {
        let startup = try SlipstreamTorStartup(generation: 0xfedc_ba98_7654_3210, remainingMilliseconds: 0)
        XCTAssertEqual(startup.snapshot.generation, 0xfedc_ba98_7654_3210)
        XCTAssertEqual(startup.snapshot.status, 3)
        startup.cancel()
        XCTAssertEqual(startup.snapshot.status, 3)
    }

    func testQueuedNewSubmissionCannotSendOnRetiredRoute() async throws {
        let client = TorClient(torDir: testTempDirectory, httpGetNative: TorHTTPGetNative(startup: TorRuntimeStartupNative.fixture { _, _ in nil }))
        mockContainer.mock(type: TorClient.self, isSingleton: true) { _ in client }
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        let service = mockContainer.resolve(LightWalletService.self) as! LightWalletServiceMock
        service.latestBlockHeightModeReturnValue = 3_543_404
        service.submitSpendTransactionModeReturnValue = SendResponse()
        let welding = mockContainer.resolve(ZcashRustBackendWelding.self) as! ZcashRustBackendWeldingMock
        welding.checkTransactionSubmittableSubmissionServerHeightReturnValue = nil
        let request = sync.requestTorTransition(enabled: true)
        let stream = await sync.submitTransactions([CreatedTransaction(txId: Data([1]), raw: Data([2]), expiryHeight: 0)])
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("A request recorded before submission entry must fence the broadcast")
        } catch {}
        XCTAssertEqual(service.submitSpendTransactionModeCallsCount, 0)
        sync.stop()
        _ = await request.waitResult()
        await sync.stopAndWait()
    }

}

private extension TorTransitionRequest {
    func waitResult() async -> Result<Void, Error> {
        do {
            try await wait()
            return .success(())
        } catch { return .failure(error) }
    }
}

private struct ClosureEndpointSubmitter: EndpointSubmitter {
    let operation: (LightWalletEndpoint) async throws -> Void
    func submit(transaction: CreatedTransaction, to endpoint: LightWalletEndpoint) async throws { try await operation(endpoint) }
}

private extension TorClient {
    func holdRouteTransitionAdmission(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
    }
}
