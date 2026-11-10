import XCTest
import os
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class OHTTPHealthLifecycleTests: ZcashTestCase {
    private let endpoint = LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443, secure: true)

    override func setUp() {
        super.setUp()
        OHTTPTestSupport.installExampleConfiguration()
    }

    private func session(_ sync: SlipstreamSynchronizer) async throws -> OHTTPHealthSession {
        try await sync.makeOHTTPHealthSession(
            route: OHTTPHealthRoute(
                network: .testnet,
                gatewayHost: endpoint.host,
                relayURL: OHTTPEndpoints.relayURL(for: endpoint.host),
                viaTor: false
            ), generation: UUID()
        )
    }

    func testStallReopenFencesHealthBeforeReopen() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: endpoint)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let binding = try XCTUnwrap(sync.ohttpHealthBinding)
        let old = try await session(sync)
        defer { old.close() }
        let before = binding.snapshot()
        engine.reopenGate.close()
        engine.startGate.close()
        defer {
            engine.reopenGate.open()
            engine.startGate.open()
            sync.stop()
        }
        let generation = await sync.passGenerationForTesting()
        let stopGeneration = await sync.stopRequestGenerationForTesting()
        let recovery = Task {
            await sync.runStallRecovery(expectedPassGeneration: generation, expectedStopRequestGeneration: stopGeneration, attempt: 1)
        }
        let reopened = await waitUntil { await engine.calls.contains { $0.hasPrefix("reopen(") } }
        XCTAssertTrue(reopened)
        XCTAssertFalse(old.isValid)
        XCTAssertEqual(binding.snapshot().phase, .replacing)
        engine.reopenGate.open()
        let started = await waitUntil { await engine.calls.contains("start") }
        XCTAssertTrue(started)
        XCTAssertEqual(binding.snapshot().phase, .replacing)
        engine.startGate.open()
        await recovery.value
        XCTAssertEqual(binding.snapshot().phase, .ready)
        XCTAssertNotEqual(binding.snapshot().bindingID, before.bindingID)
        XCTAssertEqual(binding.snapshot().continuityID, before.continuityID)
    }

    func testSameEndpointRestartFencesHealthUntilStartSettles() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: endpoint)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let binding = try XCTUnwrap(sync.ohttpHealthBinding)
        let old = try await session(sync)
        let operation = OHTTPHealthOperation()
        let request = await OHTTPHealthContext.withOperation(operation) {
            OHTTPHealthCenter.shared.begin(route: old.route, scope: .lightwalletd)
        }
        let before = binding.snapshot()
        engine.reopenGate.close()
        engine.startGate.close()
        defer {
            engine.reopenGate.open()
            engine.startGate.open()
            old.close()
            sync.stop()
        }
        let restart = Task { try await sync.restartSync(at: endpoint) }
        let reopened = await waitUntil { await engine.calls.contains { $0.hasPrefix("reopen(") } }
        XCTAssertTrue(reopened)
        XCTAssertFalse(old.isValid)
        XCTAssertEqual(binding.snapshot().phase, .replacing)
        engine.reopenGate.open()
        let started = await waitUntil { await engine.calls.contains("start") }
        XCTAssertTrue(started)
        XCTAssertEqual(binding.snapshot().phase, .replacing)
        engine.startGate.open()
        try await restart.value
        XCTAssertEqual(binding.snapshot().phase, .ready)
        XCTAssertNotEqual(binding.snapshot().bindingID, before.bindingID)
        XCTAssertEqual(binding.snapshot().continuityID, before.continuityID)
        let current = try await session(sync)
        defer { current.close() }
        request.record(outcome: .transportUnavailable, stage: .complete)
        await OHTTPHealthContext.complete(operation, failed: true)
        XCTAssertTrue(current.snapshot().observations.filter { !$0.historical }.isEmpty)
    }

    func testFailedReopenAndFailedStartSettleIndependentHealth() async throws {
        for failReopen in [true, false] {
            let engine = GatedFakeSlipstreamEngine()
            let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: endpoint)
            await sync.setInternalSyncStatusForTesting(.disconnected)
            let binding = try XCTUnwrap(sync.ohttpHealthBinding)
            let old = try await session(sync)
            defer { old.close() }
            let before = binding.snapshot()
            if failReopen {
                await engine.setReopenError(URLError(.cannotConnectToHost))
            } else {
                await engine.setStartError(URLError(.cannotConnectToHost))
            }
            do {
                try await sync.restartSync(at: endpoint)
                XCTFail("Scripted engine failure must propagate")
            } catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
            XCTAssertFalse(old.isValid)
            XCTAssertEqual(binding.snapshot().phase, .ready)
            XCTAssertNotEqual(binding.snapshot().bindingID, before.bindingID)
            let current = try await session(sync)
            XCTAssertTrue(current.isValid)
            current.close()
        }
    }

    func testFailedStallReopenAndStartSettleIndependentHealth() async throws {
        for failReopen in [true, false] {
            let engine = GatedFakeSlipstreamEngine()
            let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: endpoint)
            await sync.setInternalSyncStatusForTesting(.disconnected)
            let binding = try XCTUnwrap(sync.ohttpHealthBinding)
            let old = try await session(sync)
            defer { old.close() }
            let before = binding.snapshot()
            if failReopen {
                await engine.setReopenError(URLError(.cannotConnectToHost))
            } else {
                await engine.setStartError(URLError(.cannotConnectToHost))
            }
            await sync.runStallRecovery(
                expectedPassGeneration: await sync.passGenerationForTesting(),
                expectedStopRequestGeneration: await sync.stopRequestGenerationForTesting(),
                attempt: 1
            )
            let attempts = await sync.stallRestartAttemptsForTesting()
            XCTAssertEqual(attempts, 1)
            guard case .error(let error) = sync.latestState.internalSyncStatus else { return XCTFail("Recovery failure must still publish") }
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
            XCTAssertFalse(old.isValid)
            XCTAssertEqual(binding.snapshot().phase, .ready)
            XCTAssertNotEqual(binding.snapshot().bindingID, before.bindingID)
            let current = try await session(sync)
            XCTAssertTrue(current.isValid)
            current.close()
        }
    }

    func testFailedTargetReopenKeepsActualOldRoute() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: endpoint)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let binding = try XCTUnwrap(sync.ohttpHealthBinding)
        let before = binding.snapshot()
        let old = try await session(sync)
        defer { old.close() }
        await engine.setReopenError(URLError(.cannotConnectToHost))
        do {
            try await sync.switchTo(endpoint: LightWalletEndpoint(address: endpoint.host, port: 444, secure: true))
            XCTFail("Scripted reopen failure must propagate")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
        XCTAssertFalse(old.isValid)
        XCTAssertEqual(binding.snapshot().phase, .ready)
        XCTAssertEqual(binding.snapshot().continuityID, before.continuityID)
        XCTAssertNotEqual(binding.snapshot().bindingID, before.bindingID)
        let selected = await sync.currentEndpointForTesting()
        XCTAssertTrue(selected.isSameServer(as: endpoint))
        let current = try await session(sync)
        XCTAssertTrue(current.isValid)
        current.close()
    }

    func testRefusedOrNonReplacingOperationsKeepBinding() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let backend = ZcashRustBackendWeldingMock()
        backend.truncateToChainStateChainStateClosure = { _ in }
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: backend, endpoint: endpoint)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let binding = try XCTUnwrap(sync.ohttpHealthBinding)
        let old = try await session(sync)
        defer { old.close() }
        let before = binding.snapshot()
        try await sync.switchTo(endpoint: endpoint)
        try await sync.start(retry: false)
        sync.stop()
        try await sync.start(retry: false)
        try await GiftCardRedeemer.awaitCompletion(of: sync.rewind(.birthday))
        engine.stopReport = .passStillRunning
        do {
            try await sync.restartSync(at: endpoint)
            XCTFail("Unproved stop must refuse replacement")
        } catch { }
        XCTAssertEqual(binding.snapshot(), before)
        XCTAssertTrue(old.isValid)
        engine.stopReport = .quiescent
        sync.stop()
    }
    private struct PreparedFixture {
        let sync: SlipstreamSynchronizer
        let engine: GatedFakeSlipstreamEngine
        let directory: URL
    }

    private func preparedFixture() async throws -> PreparedFixture {
        let directory = testTempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dataDb = directory.appendingPathComponent("data.db")
        let backend = ZcashRustBackendWeldingMock()
        backend.initDataDbSeedReturnValue = .success
        backend.listAccountsReturnValue = [
            Account(
            id: TestsData.mockedAccountUUID,
            name: "Health",
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: nil,
            ufvk: nil,
                uivk: nil
            )
        ]
        let repository = TransactionRepositoryMock()
        repository.closeDBConnectionClosure = {}
        let service = LightWalletServiceMock()
        service.closeConnectionsClosure = {}
        let storage = CompactBlockRepositoryMock()
        storage.createClosure = {}
        let container = DIContainer()
        container.isTestEnvironment = true
        container.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in backend }
        container.mock(type: TransactionRepository.self, isSingleton: true) { _ in repository }
        container.mock(type: LightWalletService.self, isSingleton: true) { _ in service }
        container.mock(type: CompactBlockRepository.self, isSingleton: true) { _ in storage }
        let initializer = Initializer(
            container: container,
            cacheDbURL: nil,
            fsBlockDbRoot: directory.appendingPathComponent("blocks"),
            generalStorageURL: directory.appendingPathComponent("general"),
            dataDbURL: dataDb,
            torDirURL: directory.appendingPathComponent("tor"),
            endpoint: endpoint,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: .tests,
            loggingPolicy: .noLogging,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
        let engine = GatedFakeSlipstreamEngine()
        let sync = SlipstreamSynchronizer(
            initializer: initializer,
            alternateEndpoints: [],
            engine: engine,
            restoreAnchor: { _, _, _, _, _, _ in nil }
        )
        _ = try await sync.prepare(with: nil, walletBirthday: nil, name: "Health", keySource: nil)
        FileManager.default.createFile(atPath: dataDb.path, contents: Data())
        return PreparedFixture(sync: sync, engine: engine, directory: directory)
    }

    func testWipeFailureRetiresWalletBeforeClose() async throws {
        let fixture = try await preparedFixture()
        let sync = fixture.sync
        let engine = fixture.engine
        let directory = fixture.directory
        let binding = try XCTUnwrap(sync.ohttpHealthBinding)
        let old = try await session(sync)
        defer { old.close() }
        let before = binding.snapshot()
        await engine.onCall("close") {
            XCTAssertFalse(old.isValid)
            XCTAssertEqual(binding.snapshot().phase, .replacing)
            XCTAssertNotEqual(binding.snapshot().continuityID, before.continuityID)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        do {
            try await GiftCardRedeemer.awaitCompletion(of: sync.wipe())
            XCTFail("Read-only parent must reject wallet deletion after engine closure")
        } catch { XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain) }
        XCTAssertEqual(binding.snapshot().phase, .ready)
        XCTAssertNotEqual(binding.snapshot().continuityID, before.continuityID)
        let interim = try await session(sync)
        defer { interim.close() }
        let wiped = binding.snapshot()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        _ = try await sync.prepare(with: nil, walletBirthday: nil, name: "Health", keySource: nil)
        XCTAssertFalse(interim.isValid, "Actual open after failed wipe must fence independent health")
        XCTAssertEqual(binding.snapshot().continuityID, wiped.continuityID)
        XCTAssertNotEqual(binding.snapshot().bindingID, wiped.bindingID)
        let calls = await engine.calls
        XCTAssertEqual(calls.filter { $0 == "open" }.count, 2, "Business failed-wipe path remains open, not reopen")
    }

    func testOpenAfterCloseRetiresInterimHealth() async throws {
        let fixture = try await preparedFixture()
        let sync = fixture.sync
        let engine = fixture.engine
        let binding = try XCTUnwrap(sync.ohttpHealthBinding)
        let initial = binding.snapshot()
        let old = try await session(sync)
        defer { old.close() }
        _ = try await sync.prepare(with: nil, walletBirthday: nil, name: "Health", keySource: nil)
        XCTAssertEqual(binding.snapshot(), initial, "Idempotent prepare keeps health ownership")
        XCTAssertTrue(old.isValid)
        try await GiftCardRedeemer.awaitCompletion(of: sync.wipe())
        XCTAssertFalse(old.isValid)
        let wiped = binding.snapshot()
        XCTAssertNotEqual(wiped.continuityID, initial.continuityID)
        let interim = try await session(sync)
        defer { interim.close() }
        _ = try await sync.prepare(with: nil, walletBirthday: nil, name: "Health", keySource: nil)
        XCTAssertFalse(interim.isValid)
        XCTAssertEqual(binding.snapshot().continuityID, wiped.continuityID)
        XCTAssertNotEqual(binding.snapshot().bindingID, wiped.bindingID)
        XCTAssertEqual(binding.snapshot().phase, .ready)
        let calls = await engine.calls
        XCTAssertTrue(calls.contains("reopen(\(endpoint.host):443)"))
    }

    func testPostWipeRouteRebindAndPortTLSChangesRetireHealth() async throws {
        let fixture = try await preparedFixture()
        let sync = fixture.sync
        let engine = fixture.engine
        try await GiftCardRedeemer.awaitCompletion(of: sync.wipe())
        let binding = try XCTUnwrap(sync.ohttpHealthBinding)
        for target in [
            LightWalletEndpoint(address: endpoint.host, port: 444, secure: true),
            LightWalletEndpoint(address: endpoint.host, port: 444, secure: false)
        ] {
            let before = binding.snapshot()
            let old = try await session(sync)
            try await sync.switchTo(endpoint: target)
            XCTAssertFalse(old.isValid)
            old.close()
            XCTAssertNotEqual(binding.snapshot().continuityID, before.continuityID)
            XCTAssertNotEqual(binding.snapshot().bindingID, before.bindingID)
            XCTAssertEqual(binding.snapshot().phase, .ready)
        }
        let calls = await engine.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("reopen(") })
    }

    func testProviderFactoryRejectsBindingChangedDuringLookup() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: endpoint)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let route = OHTTPHealthRoute(
            network: .testnet,
            gatewayHost: endpoint.host,
            relayURL: try OHTTPEndpoints.relayURL(for: endpoint.host),
            viaTor: false
        )
        let entered = expectation(description: "captured binding before real lookup")
        let release = Gate()
        defer { release.open() }
        let factory = Task {
            try await sync.makeOHTTPHealthSession(route: route, generation: UUID()) {
                entered.fulfill()
                await release.wait()
                return await sync.healthBinding()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        try await sync.restartSync(at: endpoint)
        sync.stop()
        release.open()
        do {
            let stale = try await factory.value
            stale.close()
            XCTFail("Factory may not admit a session from a retired capture")
        } catch { XCTAssertEqual(error as? OHTTPHealthError, .bindingUnavailable) }
        let current = try await session(sync)
        XCTAssertTrue(current.isValid)
        current.close()
    }

    func testProviderFactoryReportsDeferredBindingWhenSelectedRouteAlsoChanged() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: endpoint)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let route = OHTTPHealthRoute(
            network: .testnet,
            gatewayHost: endpoint.host,
            relayURL: try OHTTPEndpoints.relayURL(for: endpoint.host),
            viaTor: false
        )
        let entered = expectation(description: "captured binding before real lookup")
        let release = Gate()
        defer { release.open() }
        let factory = Task {
            try await sync.makeOHTTPHealthSession(route: route, generation: UUID()) {
                entered.fulfill()
                await release.wait()
                return await sync.healthBinding()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        try await sync.restartSync(at: LightWalletEndpoint(address: "fallback.invalid", port: 443, secure: true))
        sync.stop()
        release.open()
        do {
            let stale = try await factory.value
            stale.close()
            XCTFail("Factory may not admit a session from a retired capture")
        } catch { XCTAssertEqual(error as? OHTTPHealthError, .bindingUnavailable) }
        XCTAssertEqual(sync.ohttpHealthBinding?.snapshot().phase, .ready)
    }

    func testRetiredProbeCannotDispatchAfterLookup() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: endpoint)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let old = try await session(sync)
        defer { old.close() }
        let entered = expectation(description: "probe waiting for actual provider lookup")
        let release = Gate()
        defer { release.open() }
        let probe = Task {
            await sync.probeOHTTPHealth(session: old) {
                entered.fulfill()
                await release.wait()
                return await sync.healthBinding()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        try await sync.restartSync(at: LightWalletEndpoint(address: "fallback.invalid", port: 443, secure: true))
        sync.stop()
        release.open()
        let result = await probe.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertTrue(old.snapshot().observations.isEmpty)
    }

    func testAcceptedInnerDiagnosticPauseSurvivesReplacementUntilOriginalDeadline() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: endpoint)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let old = try await session(sync)
        defer {
            old.close()
            sync.stop()
        }
        let posts = OSAllocatedUnfairLock(initialState: 0)
        let transport = OHTTPTransport(
            gatewayHost: old.route.gatewayHost,
            relayURL: old.route.relayURL,
            walletNetwork: .testnet,
            testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(),
            keyCache: OHTTPKeyCache(),
            streamSender: { _, _ in
                posts.withLock { $0 += 1 }
                return OHTTPOuterStream(
                    status: 200,
                    contentType: "message/ohttp-chunked-res",
                    retryAfter: nil,
                    body: AsyncThrowingStream { continuation in
                        continuation.yield(Data([1]))
                        continuation.finish()
                    }
                )
            },
            streamDecoderFactory: { _ in
                PassThroughStreamDecoder(status: posts.withLock { $0 == 1 ? 429 : 403 }, headers: [("retry-after", "2")])
            },
            httpSender: { request, _ in (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200)) }
        )
        let client = OHTTPGRPCClient(authority: old.route.gatewayHost, transport: transport, singleCallTimeoutMS: 5000, streamingCallTimeoutMS: 5000)
        let before = OHTTPHealthClock.nowNanoseconds
        _ = await OHTTPHealthProbe.run(session: old) { _ in
            try await OHTTPHealthProbe.readInfo(client: client, network: .testnet)
        }
        let after = OHTTPHealthClock.nowNanoseconds
        let pause = try XCTUnwrap(old.snapshot().observations.first {
            if case .rateLimited = $0.outcome { return $0.scope == .lightwalletd && $0.purpose == .diagnostic }
            return false
        })
        guard case .rateLimited(let deadline) = pause.outcome else { return XCTFail("Expected decoded inner 429 pause") }
        XCTAssertGreaterThanOrEqual(deadline, before + 2_000_000_000)
        XCTAssertLessThanOrEqual(deadline, after + 2_000_000_000)
        XCTAssertEqual(posts.withLock { $0 }, 1)

        try await sync.restartSync(at: endpoint)
        XCTAssertFalse(old.isValid)
        let current = try await session(sync)
        defer { current.close() }
        XCTAssertLessThan(OHTTPHealthClock.nowNanoseconds, deadline)
        let paused = await OHTTPHealthProbe.run(session: current) { _ in
            try await OHTTPHealthProbe.readInfo(client: client, network: .testnet)
        }
        XCTAssertEqual(paused.outcome, .rateLimited(retryNotBefore: deadline))
        XCTAssertEqual(posts.withLock { $0 }, 1, "The replacement must not dispatch inside the accepted server pause")
        XCTAssertTrue(
            current.snapshot().observations.filter { $0.purpose == .diagnostic }.allSatisfy {
                $0.outcome == .rateLimited(retryNotBefore: deadline)
            },
            "Diagnostic availability evidence remains owned by its original session"
        )

        let now = OHTTPHealthClock.nowNanoseconds
        if deadline > now { try await Task.sleep(nanoseconds: deadline - now + 1_000_000) }
        let resumed = await OHTTPHealthProbe.run(session: current) { _ in
            try await OHTTPHealthProbe.readInfo(client: client, network: .testnet)
        }
        XCTAssertEqual(resumed.outcome, .policyRejected)
        XCTAssertEqual(posts.withLock { $0 }, 2, "The original deadline must expire without being restarted by admission")
        let later = try await session(sync)
        defer { later.close() }
        XCTAssertFalse(later.snapshot().observations.contains { $0.purpose == .diagnostic }, "Expired pauses and availability do not replay")
    }

    func testActualOuterPauseCacheSeparatesAcceptedAndRetiredSenderCompletion() async throws {
        for retireBeforeResponse in [false, true] {
            let engine = GatedFakeSlipstreamEngine()
            let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: endpoint)
            await sync.setInternalSyncStatusForTesting(.disconnected)
            let old = try await session(sync)
            let entered = expectation(description: "actual relay sender entered")
            let release = Gate()
            let posts = OSAllocatedUnfairLock(initialState: 0)
            let originalRequest = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
            let transport = OHTTPTransport(
                gatewayHost: old.route.gatewayHost,
                relayURL: old.route.relayURL,
                walletNetwork: .testnet,
                testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(),
                streamSender: { _, _ in
                    posts.withLock { $0 += 1 }
                    originalRequest.withLock { $0 = OHTTPHealthTraffic.current?.ticket.requestID }
                    entered.fulfill()
                    await release.wait()
                    return OHTTPOuterStream(status: 429, contentType: nil, retryAfter: "1", body: AsyncThrowingStream { $0.finish() })
                },
                httpSender: { request, _ in
                    (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
                }
            )
            let client = OHTTPGRPCClient(
                authority: old.route.gatewayHost,
                transport: transport,
                singleCallTimeoutMS: 5000,
                streamingCallTimeoutMS: 5000
            )
            defer {
                release.open()
                old.close()
                sync.stop()
            }
            let probe = Task {
                await OHTTPHealthProbe.run(session: old) { budget in
                    try budget.admit()
                    return try await OHTTPHealthProbe.readInfo(client: client, network: .testnet)
                }
            }
            await fulfillment(of: [entered], timeout: 2)
            if retireBeforeResponse {
                try await sync.restartSync(at: endpoint)
                await sync.stopAndWait()
                XCTAssertFalse(old.isValid)
                probe.cancel()
            }
            let beforeResponse = OHTTPHealthClock.nowNanoseconds
            release.open()
            let result = await probe.value
            let afterResponse = OHTTPHealthClock.nowNanoseconds
            XCTAssertEqual(posts.withLock { $0 }, 1)
            let cacheKey = "\(old.route.relayURL)|direct"
            let cachedDeadline = await OHTTPKeyCache.shared.backoffDeadline(for: cacheKey)
            let transportDeadline = try XCTUnwrap(cachedDeadline)
            XCTAssertGreaterThan(transportDeadline.timeIntervalSinceNow, 0)
            XCTAssertLessThanOrEqual(transportDeadline.timeIntervalSinceNow, 1)
            if !retireBeforeResponse {
                guard case .rateLimited(let deadline) = result.outcome else { return XCTFail("Accepted outer pause must remain typed") }
                XCTAssertGreaterThanOrEqual(deadline, beforeResponse + 1_000_000_000)
                XCTAssertLessThanOrEqual(deadline, afterResponse + 1_000_000_000)
                try await sync.restartSync(at: endpoint)
                await sync.stopAndWait()
                let current = try await session(sync)
                let paused = await OHTTPHealthProbe.run(session: current) { _ in
                    XCTFail("Accepted pause must prevent replacement dispatch")
                    return .usable
                }
                XCTAssertEqual(paused.outcome, result.outcome)
                current.close()
            } else {
                XCTAssertEqual(result.outcome, .cancelled)
                let current = try await session(sync)
                XCTAssertFalse(current.snapshot().observations.contains { $0.purpose == .diagnostic })
                current.close()
                let later = try await session(sync)
                XCTAssertFalse(
                    later.snapshot().observations.contains { $0.purpose == .diagnostic },
                    "Late sender completion cannot replay old health"
                )
                let freshStart = OHTTPHealthClock.nowNanoseconds
                let fresh = OHTTPTransport(
                    gatewayHost: old.route.gatewayHost,
                    relayURL: old.route.relayURL,
                    walletNetwork: .testnet,
                    httpSender: { _, _ in
                        XCTFail("The shared server pause must prevent fresh network dispatch")
                        throw URLError(.cannotConnectToHost)
                    }
                )
                let localPause = await OHTTPHealthProbe.run(session: later) { budget in
                    try budget.admit()
                    _ = try await fresh.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
                    return .usable
                }
                guard case .rateLimited = localPause.outcome else { return XCTFail("Fresh request must observe local transport backoff") }
                let newEvidence = later.snapshot().observations.filter { $0.purpose == .diagnostic }
                XCTAssertFalse(newEvidence.isEmpty)
                XCTAssertTrue(
                    newEvidence.allSatisfy {
                        !$0.historical && $0.generation == later.generation && $0.startedAtNanoseconds >= freshStart &&
                        $0.requestID != originalRequest.withLock { $0 }
                    },
                    "A later local backoff is fresh current-owner evidence, never retired-sender replay"
                )
                later.close()
            }
            // A real server response still owns the transport pause even after caller retirement.
            // A second transport sharing the production cache must fail locally without sending.
            let next = OHTTPTransport(gatewayHost: old.route.gatewayHost, relayURL: old.route.relayURL)
            do {
                try await next.checkRelayBackoff()
                XCTFail("The existing shared transport pause must be preserved")
            } catch {
                guard case .httpStatusError(let status, _) = error as? OHTTPError else {
                    return XCTFail("Expected unchanged local backoff error")
                }
                XCTAssertEqual(status, 429)
            }
            let unchangedDeadline = await OHTTPKeyCache.shared.backoffDeadline(for: cacheKey)
            XCTAssertEqual(unchangedDeadline, transportDeadline)
            let remaining = transportDeadline.timeIntervalSinceNow
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000) + 1_000_000) }
            try await next.checkRelayBackoff()
            old.close()
            sync.stop()
        }
    }

    func testDelayedDiagnosticChildCannotCaptureReplacementSession() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: endpoint)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let old = try await session(sync)
        defer { old.close() }
        let entered = expectation(description: "diagnostic parent admitted")
        let release = Gate()
        defer { release.open() }
        defer {
            OHTTPHealthCenter.shared.begin(route: old.route, scope: .lightwalletd, purpose: .background)
                .record(outcome: .rateLimited(retryNotBefore: 0), stage: .complete)
            OHTTPHealthCenter.shared.begin(route: old.route, scope: .other, purpose: .background)
                .record(outcome: .rateLimited(retryNotBefore: 0), stage: .complete)
        }
        let pause = OHTTPHealthClock.nowNanoseconds + 60_000_000_000
        let probe = Task {
            await OHTTPHealthProbe.run(session: old) { budget in
                try budget.admit()
                let captured = OHTTPHealthTraffic(route: old.route, request: OHTTPRequest(
                    method: "POST", scheme: "https", authority: old.route.gatewayHost, path: "/test", headers: [], body: Data()
                ))
                entered.fulfill()
                await release.wait()
                captured.ticket.record(outcome: .rateLimited(retryNotBefore: pause), stage: .responseHead)
                let child = OHTTPHealthTraffic(route: old.route, request: OHTTPRequest(
                    method: "POST", scheme: "https", authority: "lightwalletd.test", path: "/test", headers: [], body: Data()
                ))
                child.ticket.record(outcome: .rateLimited(retryNotBefore: pause), stage: .responseHead)
                return .usable
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        try await sync.restartSync(at: endpoint)
        sync.stop()
        let current = try await session(sync)
        defer { current.close() }
        let before = current.snapshot()
        release.open()
        let result = await probe.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(current.snapshot(), before, "Late child may not reach a new same-route owner")
        let later = try await session(sync)
        defer { later.close() }
        XCTAssertFalse(
            later.snapshot().observations.contains { $0.purpose == .diagnostic && $0.outcome == .rateLimited(retryNotBefore: pause) },
            "Retired diagnostics must not enter a later owner via route history"
        )
    }

    func testRetiredAdmittedProbeDrainsAndReturnsCancelled() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: endpoint)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let old = try await session(sync)
        defer { old.close() }
        let entered = expectation(description: "admitted work")
        let drained = expectation(description: "drained work")
        let release = Gate()
        defer { release.open() }
        let probe = Task {
            await OHTTPHealthProbe.run(session: old) { budget in
                try budget.admit()
                entered.fulfill()
                await release.wait()
                XCTAssertTrue(Task.isCancelled, "Session retirement cancels its active budget")
                drained.fulfill()
                return .usable
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        try await sync.restartSync(at: endpoint)
        sync.stop()
        release.open()
        let result = await probe.value
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(result.outcome, .cancelled)
    }

    func testProviderRejectsForeignAndUnboundSessionsBeforeLookup() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let sync = try makeSlipstreamSynchronizer(engine: engine, endpoint: LightWalletEndpoint(address: "fallback.invalid", port: 443, secure: true))
        let foreign = try makeSlipstreamSynchronizer(engine: GatedFakeSlipstreamEngine(), endpoint: endpoint)
        let other = try await session(foreign)
        let unbound = try OHTTPHealthSession(route: other.route, generation: UUID())
        defer {
            other.close()
            unbound.close()
        }
        for session in [other, unbound] {
            let result = await sync.probeOHTTPHealth(session: session) {
                XCTFail("Foreign session cannot even enter lookup")
                return await sync.healthBinding()
            }
            XCTAssertEqual(result.outcome, .cancelled)
        }
    }

    func testOpenAfterFailedReopenRetiresInterimHealth() async throws {
        let fixture = try await preparedFixture()
        let sync = fixture.sync
        let engine = fixture.engine
        let binding = try XCTUnwrap(sync.ohttpHealthBinding)
        await engine.setReopenError(URLError(.cannotConnectToHost))
        do {
            try await sync.restartSync(at: endpoint)
            XCTFail("Reopen must report the scripted failure")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
        let before = binding.snapshot()
        let interim = try await session(sync)
        defer { interim.close() }
        _ = try await sync.prepare(with: nil, walletBirthday: nil, name: "Health", keySource: nil)
        XCTAssertFalse(interim.isValid)
        XCTAssertNotEqual(binding.snapshot().bindingID, before.bindingID)
        XCTAssertEqual(binding.snapshot().continuityID, before.continuityID)
        XCTAssertEqual(binding.snapshot().phase, .ready)
    }

    func testProviderDestructionRetiresRetainedHandleAndSession() async throws {
        var sync: SlipstreamSynchronizer? = try makeSlipstreamSynchronizer(engine: GatedFakeSlipstreamEngine(), endpoint: endpoint)
        let binding = try XCTUnwrap(sync?.ohttpHealthBinding)
        let old = try await session(XCTUnwrap(sync))
        sync = nil
        XCTAssertFalse(old.isValid)
        XCTAssertEqual(binding.snapshot().phase, .unavailable)
        old.close()
    }
}
