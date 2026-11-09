import XCTest
import os
import libzcashlc
@testable import ZODLSwiftWalletSDK

final class OHTTPHealthProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OHTTPTestSupport.installExampleConfiguration()
    }

    private func route(viaTor: Bool = false) -> OHTTPHealthRoute {
        OHTTPHealthRoute(network: .testnet, gatewayHost: OHTTPTestSupport.testnetHost, relayURL: "https://\(UUID().uuidString.lowercased()).test/relay", viaTor: viaTor)
    }

    func testInnerBackend429DoesNotPauseLightwalletProbe() async throws {
        try await assertBackendPauseScope(outerStatus: 200, shouldPause: false)
    }

    func testOuterRelay429StillPausesProbe() async throws {
        try await assertBackendPauseScope(outerStatus: 429, shouldPause: true)
    }

    private func assertBackendPauseScope(outerStatus: Int, shouldPause: Bool) async throws {
        for viaTor in [false, true] {
            let route = route(viaTor: viaTor)
            let session = try OHTTPHealthSession(route: route, generation: UUID())
            defer { session.close() }
            let transport = OHTTPTransport(
                gatewayHost: route.gatewayHost,
                relayURL: route.relayURL,
                walletNetwork: .testnet,
                testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(),
                viaTor: viaTor,
                keyCache: OHTTPKeyCache(),
                streamSender: { _, _ in self.outer(body: Data([1]), status: outerStatus) },
                streamDecoderFactory: { _ in PassThroughStreamDecoder(status: 429, headers: [("retry-after", "120")]) },
                httpSender: { request, _ in
                    (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
                }
            )
            let request = OHTTPRequest(method: "GET", scheme: "https", authority: "cmc.zodl.com", path: "/rates", headers: [], body: Data())
            do {
                let response = try await transport.stream(request: request, timeoutMS: 5000)
                for try await _ in response.body { }
            } catch {
                guard shouldPause else { throw error }
            }
            let pauses = session.snapshot().observations.filter {
                if case .rateLimited = $0.outcome { return true }
                return false
            }
            XCTAssertTrue(pauses.contains { $0.scope == .exchangeRates })
            XCTAssertEqual(pauses.contains { $0.scope == .route }, shouldPause)
            let dispatches = OSAllocatedUnfairLock(initialState: 0)
            let frame = try infoFrame()
            let client = probeClient(
                route: route,
                decoder: { PassThroughStreamDecoder(headers: [("content-type", "application/grpc")], trailers: [("grpc-status", "0")]) },
                sender: { _, _ in
                    dispatches.withLock { $0 += 1 }
                    return self.outer(body: frame)
                }
            )
            let result = await OHTTPHealthProbe.run(session: session) { _ in
                try await OHTTPHealthProbe.readInfo(client: client, network: .testnet)
            }
            XCTAssertEqual(dispatches.withLock { $0 }, shouldPause ? 0 : 1)
            if shouldPause {
                guard case .rateLimited = result.outcome else { return XCTFail("Outer relay pause must prohibit the probe") }
            } else {
                XCTAssertEqual(result.outcome, .usable)
            }
        }
    }

    func testProbeBudgetsAreFiveAndTwentySeconds() {
        XCTAssertEqual(OHTTPHealthProbe.budgetMilliseconds(viaTor: false), 5000)
        XCTAssertEqual(OHTTPHealthProbe.budgetMilliseconds(viaTor: true), 20000)
    }

    func testProbeDeadlineAndCallerCancellationHaveDifferentOutcomes() async throws {
        let session = try OHTTPHealthSession(route: route(), generation: UUID())
        defer { session.close() }
        let expired = await OHTTPHealthProbe.run(session: session, timeoutMilliseconds: 10) { _ in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return .usable
        }
        XCTAssertEqual(expired.outcome, .inconclusive)
        let task = Task {
            await OHTTPHealthProbe.run(session: session, timeoutMilliseconds: 1000) { _ in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return .usable
            }
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertEqual(cancelled.generation, session.generation)
    }

    func testQueuedProbeExpiryIsInconclusive() async throws {
        let clock = TorTestClock()
        let executor = TorHTTPRequestExecutor(now: { clock.now }, sleepUntil: { try await clock.sleepUntil($0) })
        let first = TorWorkerGate()
        let second = TorWorkerGate()
        defer {
            first.release()
            second.release()
        }
        let downloads = [first, second].map { gate in
            Task { try await executor.execute(deadlineUptime: UInt64.max, operation: { try gate.run($0) }) }
        }
        await fulfillment(of: [first.entered, second.entered], timeout: 3)
        let budget = OHTTPHealthProbeBudget(milliseconds: 60_000, nativeDeadline: true, now: { clock.now })
        let nativeCalls = OSAllocatedUnfairLock(initialState: 0)
        let disposals = OSAllocatedUnfairLock(initialState: 0)
        let probe = Task {
            await budget.run {
                try budget.admit()
                _ = try await executor.execute(
                    deadlineUptime: budget.deadline,
                    operation: { _ in
                        nativeCalls.withLock { $0 += 1 }
                        return TorWorkerGate.response
                    },
                    dispose: { disposals.withLock { $0 += 1 } },
                    onStart: { try budget.beginNetworkAttempt() }
                )
                return .usable
            }
        }
        await clock.waitForSleepers(1)
        clock.advance(to: budget.deadline)
        let outcome = await probe.value
        XCTAssertEqual(outcome, .inconclusive)
        XCTAssertEqual(nativeCalls.withLock { $0 }, 0)
        XCTAssertEqual(disposals.withLock { $0 }, 1)
        first.release()
        second.release()
        for task in downloads { _ = try await task.value }
        XCTAssertEqual(nativeCalls.withLock { $0 }, 0, "Expired work cannot dispatch after a slot becomes free")
        XCTAssertEqual(disposals.withLock { $0 }, 1)
    }

    func testExpiredBetweenAdmissionAndWorkerNeverDispatches() async throws {
        let clock = TorTestClock()
        let queue = DispatchQueue(label: "probe.delayed.worker", attributes: .concurrent)
        let blocked = expectation(description: "Worker queue blocked")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        queue.async(flags: .barrier) {
            blocked.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        await fulfillment(of: [blocked], timeout: 3)
        let admitted = expectation(description: "Executor admission read")
        let executor = TorHTTPRequestExecutor(workerQueue: queue, now: {
            if clock.now == 0 { admitted.fulfill() }
            return clock.now
        })
        let budget = OHTTPHealthProbeBudget(milliseconds: 60_000, nativeDeadline: true, now: { clock.now })
        let nativeCalls = OSAllocatedUnfairLock(initialState: 0)
        let disposals = OSAllocatedUnfairLock(initialState: 0)
        let probe = Task {
            await budget.run {
                try budget.admit()
                _ = try await executor.execute(
                    deadlineUptime: budget.deadline,
                    operation: { _ in
                        nativeCalls.withLock { $0 += 1 }
                        return TorWorkerGate.response
                    },
                    dispose: { disposals.withLock { $0 += 1 } },
                    onStart: { try budget.beginNetworkAttempt() }
                )
                return .usable
            }
        }
        await fulfillment(of: [admitted], timeout: 3)
        clock.advance(to: budget.deadline)
        release.signal()
        let outcome = await probe.value
        XCTAssertEqual(outcome, .inconclusive)
        XCTAssertEqual(nativeCalls.withLock { $0 }, 0)
        XCTAssertEqual(disposals.withLock { $0 }, 1)
    }

    func testSubmillisecondQueuedBudgetIsInconclusive() async {
        let clock = TorTestClock()
        let executor = TorHTTPRequestExecutor(now: { clock.now })
        let budget = OHTTPHealthProbeBudget(milliseconds: 60_000, nativeDeadline: true, now: { clock.now })
        let outcome = await budget.run {
            try budget.admit()
            clock.advance(to: budget.deadline - 1)
            _ = try await executor.execute(deadlineUptime: budget.deadline, operation: { _ in
                XCTFail("No whole millisecond remains for native dispatch")
                return TorWorkerGate.response
            }, onStart: { try budget.beginNetworkAttempt() })
            return .usable
        }
        XCTAssertEqual(outcome, .inconclusive)
    }

    func testDispatchedFailureRemainsUnavailable() async throws {
        try await assertDispatchedOutcome(status: nil, expected: .transportUnavailable)
    }

    func testResponseStatusWinsDeadlineRace() async throws {
        try await assertDispatchedOutcome(status: 403, expected: .policyRejected)
    }

    private func assertDispatchedOutcome(status: UInt16?, expected: OHTTPHealthOutcome) async throws {
        let clock = TorTestClock()
        let budget = OHTTPHealthProbeBudget(milliseconds: 60_000, nativeDeadline: true, now: { clock.now })
        let runtimes = TorTestRuntimes()
        let nativeCalls = OSAllocatedUnfairLock(initialState: 0)
        let disposals = OSAllocatedUnfairLock(initialState: 0)
        var native = TorHTTPGetNative(isolateRuntime: { runtimes.clone($0) }, freeRuntime: {
            disposals.withLock { $0 += 1 }
            runtimes.free($0)
        })
        native.classifiedGet = { _, _, _, _, _, _, _, outcome in
            nativeCalls.withLock { $0 += 1 }
            clock.advance(to: budget.deadline)
            outcome?.pointee = FfiTorHttpOutcome(kind: status == nil ? 2 : 1, http_status: status ?? 0, retry_not_before_ns: 0)
            return nil
        }
        let client = TorClient(runtimePtr: runtimes.parent, torDir: FileManager.default.temporaryDirectory, httpGetNative: native)
        let outcome = await budget.run {
            try budget.admit()
            return try await OHTTPHealthProbe.$budget.withValue(budget) {
                _ = try await client.httpRequestSentOnce(
                    for: URLRequest(url: URL(string: "https://probe.test/keys")!), maxBytes: 100, timeoutMilliseconds: 60_000
                )
                return .usable
            }
        }
        XCTAssertEqual(outcome, expected)
        XCTAssertEqual(nativeCalls.withLock { $0 }, 1)
        XCTAssertEqual(disposals.withLock { $0 }, 1)
        try await client.close()
        XCTAssertEqual(disposals.withLock { $0 }, 2, "Child and parent each dispose once")
    }

    func testNativeExplicitPausePreventsProbeDispatch() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let pause = OHTTPHealthClock.nowNanoseconds + 20_000_000_000
        OHTTPHealthCenter.shared.begin(route: route, scope: .route).record(outcome: .rateLimited(retryNotBefore: pause), stage: .responseHead)
        let result = await OHTTPHealthProbe.run(session: session) { _ in
            XCTFail("An explicit pause prohibits network work")
            return .usable
        }
        XCTAssertEqual(result.outcome, .rateLimited(retryNotBefore: pause))
    }

    func testFailedBackgroundSyncDoesNotProhibitFreshDiagnosticSuccess() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        OHTTPHealthCenter.shared.begin(route: route, scope: .lightwalletd).record(outcome: .transportUnavailable, stage: .connection)
        let result = await OHTTPHealthProbe.run(session: session) { _ in .usable }
        XCTAssertEqual(result.outcome, .usable)
        let diagnostic = try XCTUnwrap(session.snapshot().observations.first { $0.purpose == .diagnostic })
        XCTAssertNil(diagnostic.operation)
    }
    func testProbeReadsOneInfoAndRejectsWrongChainThroughRealGRPCDecoder() async throws {
        for chain in ["test", "main"] {
            let route = route()
            let session = try OHTTPHealthSession(route: route, generation: UUID())
            defer { session.close() }
            var info = LightdInfo()
            info.chainName = chain
            info.blockHeight = 3_100_000
            info.consensusBranchID = String(UInt32(bitPattern: zcashlc_branch_id_for_height(3_100_000, NetworkType.testnet.networkId)), radix: 16)
            let payload = try info.serializedData()
            var frame = Data([0])
            withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
            frame.append(payload)
            let responseFrame = frame
            var posts = 0
            let transport = OHTTPTransport(
                gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
                testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(), keyCache: OHTTPKeyCache(),
                streamSender: { _, _ in
                    posts += 1
                    return OHTTPOuterStream(status: 200, contentType: "message/ohttp-chunked-res", retryAfter: nil,
                        body: AsyncThrowingStream { continuation in
                            continuation.yield(responseFrame)
                            continuation.finish()
                        })
                },
                streamDecoderFactory: { _ in PassThroughStreamDecoder(headers: [("content-type", "application/grpc")], trailers: [("grpc-status", "0")]) },
                httpSender: { request, _ in (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200)) }
            )
            let client = OHTTPGRPCClient(authority: route.gatewayHost, transport: transport, singleCallTimeoutMS: 5000, streamingCallTimeoutMS: 5000)
            let result = await OHTTPHealthProbe.run(session: session) { _ in
                try await OHTTPHealthProbe.readInfo(client: client, network: .testnet)
            }
            XCTAssertEqual(result.outcome, chain == "test" ? .usable : .configurationFailure)
            XCTAssertEqual(posts, 1)
            XCTAssertTrue(session.snapshot().observations.allSatisfy { $0.purpose == .diagnostic })
        }
    }

    func testFinalInnerRejectionsPreserveTypedProbeOutcomeAndServiceError() async throws {
        for status in [429, 403, 503, 200] {
            let route = route()
            let session = try OHTTPHealthSession(route: route, generation: UUID())
            defer { session.close() }
            let responseEvidence = OSAllocatedUnfairLock<OHTTPHealthOutcome?>(initialState: nil)
            var posts = 0
            var keyFetches = 0
            let client = probeClient(
                route: route,
                decoder: {
                    PassThroughStreamDecoder(
                        status: status,
                        headers: [("content-type", "application/grpc"), ("retry-after", "2")],
                        trailers: [("grpc-status", status == 200 ? "14" : "0")]
                    )
                },
                keyFetch: { keyFetches += 1 },
                sender: { _, _ in
                    posts += 1
                    return self.outer(body: Data())
                }
            )
            let result = await OHTTPHealthProbe.run(session: session) { _ in
                do {
                    let outcome = try await OHTTPHealthProbe.readInfo(client: client, network: .testnet)
                    XCTFail("The original RPC must still fail for HTTP \(status)")
                    return outcome
                } catch {
                    guard case let LightWalletServiceError.failed(code, message) = error else {
                        XCTFail("Original service error changed: \(error)")
                        throw error
                    }
                    XCTAssertEqual(code, status == 200 ? 14 : 13)
                    XCTAssertEqual(message, status == 200 ? "" : "gateway/lightwalletd returned HTTP \(status)")
                    let observed = session.snapshot().observations.first {
                        $0.scope == .lightwalletd && $0.outcome != .usable
                    }
                    responseEvidence.withLock { $0 = observed?.outcome }
                    throw error
                }
            }
            let observations = session.snapshot().observations
            let response = try XCTUnwrap(responseEvidence.withLock { $0 })
            if status == 429 {
                guard case .rateLimited = response else { return XCTFail("Expected response pause") }
                XCTAssertEqual(result.outcome, response, "Keep the recorded absolute deadline")
            } else {
                XCTAssertEqual(result.outcome, status == 403 ? .policyRejected : .backendUnavailable)
            }
            XCTAssertEqual(result.route, route)
            XCTAssertEqual(result.generation, session.generation)
            XCTAssertEqual(posts, 1)
            XCTAssertEqual(keyFetches, 1)
            XCTAssertTrue(observations.allSatisfy {
                $0.route == route && $0.generation == session.generation && $0.purpose == .diagnostic
            })
            let exchanges = Set(observations.filter { $0.scope == .route && $0.outcome == .usable }.map(\.requestID))
            XCTAssertEqual(exchanges.count, 1, "One final logical response owns the exchange")
        }
    }

    func testProbeUsesOnlyFinalResponseAfterImmediateRecovery() async throws {
        for refusal in [400, 422, 0] {
            for finalFails in [false, true] {
                let route = route()
                let session = try OHTTPHealthSession(route: route, generation: UUID())
                defer { session.close() }
                let frame = try infoFrame()
                var posts = 0
                var keyFetches = 0
                let client = probeClient(
                    route: route,
                    decoder: {
                        if refusal == 0 && posts == 1 {
                            return PassThroughStreamDecoder(status: 400, headers: [("ohttp-freshness", "rejected")])
                        }
                        return PassThroughStreamDecoder(
                            headers: [("content-type", "application/grpc")],
                            trailers: [("grpc-status", "0")]
                        )
                    },
                    keyFetch: { keyFetches += 1 },
                    sender: { _, _ in
                        posts += 1
                        if posts == 1 { return self.outer(body: Data(), status: refusal == 0 ? 200 : refusal) }
                        if finalFails { throw URLError(.networkConnectionLost) }
                        return self.outer(body: frame)
                    }
                )
                let result = await OHTTPHealthProbe.run(session: session) { _ in
                    try await OHTTPHealthProbe.readInfo(client: client, network: .testnet)
                }
                XCTAssertEqual(result.outcome, finalFails ? .transportUnavailable : .usable)
                XCTAssertEqual(posts, 2, "Immediate recovery retries only once")
                XCTAssertEqual(keyFetches, 2)
                XCTAssertFalse(session.snapshot().observations.contains { $0.outcome == .responseRejected })
                XCTAssertEqual(result.route, route)
                XCTAssertEqual(result.generation, session.generation)
            }
        }
    }

    func testCallerCancellationOverridesReceivedPolicyAndPause() async throws {
        for status in [403, 429] {
            let route = route()
            let session = try OHTTPHealthSession(route: route, generation: UUID())
            defer { session.close() }
            let received = expectation(description: "typed rejection reached the original RPC caller")
            let gate = ProbeRejectionGate()
            var posts = 0
            let client = probeClient(
                route: route,
                decoder: {
                    PassThroughStreamDecoder(status: status, headers: [("retry-after", "2")])
                },
                sender: { _, _ in
                    posts += 1
                    return self.outer(body: Data())
                }
            )
            let task = Task {
                await OHTTPHealthProbe.run(session: session) { budget in
                    try budget.admit()
                    do {
                        return try await OHTTPHealthProbe.readInfo(client: client, network: .testnet)
                    } catch {
                        received.fulfill()
                        await gate.wait()
                        throw error
                    }
                }
            }
            await fulfillment(of: [received], timeout: 2)
            XCTAssertTrue(session.snapshot().observations.contains {
                if status == 403 { return $0.outcome == .policyRejected }
                if case .rateLimited = $0.outcome { return true }
                return false
            })
            task.cancel()
            await gate.release()
            let result = await task.value
            XCTAssertEqual(result.outcome, .cancelled)
            XCTAssertEqual(posts, 1)
        }
    }

    func testUsableHeadersDoNotMaskBodyOrGRPCValidationFailure() async throws {
        for bodyFails in [false, true] {
            let route = route()
            let session = try OHTTPHealthSession(route: route, generation: UUID())
            defer { session.close() }
            var posts = 0
            let client = probeClient(
                route: route,
                decoder: {
                    PassThroughStreamDecoder(
                        headers: [("content-type", "application/grpc")],
                        trailers: [("grpc-status", "0")]
                    )
                },
                sender: { _, _ in
                    posts += 1
                    return OHTTPOuterStream(
                        status: 200,
                        contentType: "message/ohttp-chunked-res",
                        retryAfter: nil,
                        body: AsyncThrowingStream { continuation in
                            continuation.yield(Data([0, 0]))
                            if bodyFails {
                                continuation.finish(throwing: URLError(.networkConnectionLost))
                            } else {
                                continuation.finish()
                            }
                        }
                    )
                }
            )
            let result = await OHTTPHealthProbe.run(session: session) { _ in
                try await OHTTPHealthProbe.readInfo(client: client, network: .testnet)
            }
            XCTAssertEqual(result.outcome, bodyFails ? .transportUnavailable : .inconclusive)
            XCTAssertEqual(posts, 1)
            XCTAssertTrue(session.snapshot().observations.contains { $0.scope == .route && $0.outcome == .usable })
        }
    }

    private func infoFrame() throws -> Data {
        var info = LightdInfo()
        info.chainName = "test"
        info.blockHeight = 3_100_000
        info.consensusBranchID = String(
            UInt32(bitPattern: zcashlc_branch_id_for_height(3_100_000, NetworkType.testnet.networkId)),
            radix: 16
        )
        let payload = try info.serializedData()
        var frame = Data([0])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    private func probeClient(
        route: OHTTPHealthRoute,
        decoder: @escaping () -> OHTTPStreamDecoding,
        keyFetch: @escaping () -> Void = {},
        sender: @escaping OHTTPTransport.StreamSender
    ) -> OHTTPGRPCClient {
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost,
            relayURL: route.relayURL,
            walletNetwork: .testnet,
            testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(),
            keyCache: OHTTPKeyCache(),
            streamSender: { request, maxBytes in
                try OHTTPHealthProbe.budget?.beginNetworkAttempt()
                return try await sender(request, maxBytes)
            },
            streamDecoderFactory: { _ in decoder() },
            httpSender: { request, _ in
                try OHTTPHealthProbe.budget?.beginNetworkAttempt()
                keyFetch()
                return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
            }
        )
        return OHTTPGRPCClient(
            authority: route.gatewayHost,
            transport: transport,
            singleCallTimeoutMS: 5000,
            streamingCallTimeoutMS: 5000
        )
    }

    private func outer(body: Data, status: Int = 200) -> OHTTPOuterStream {
        OHTTPOuterStream(
            status: status,
            contentType: "message/ohttp-chunked-res",
            retryAfter: nil,
            body: AsyncThrowingStream { continuation in
                continuation.yield(body)
                continuation.finish()
            }
        )
    }

    func testBudgetDoesNotResetBetweenKeyAndPost() throws {
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let budget = OHTTPHealthProbeBudget(milliseconds: 50, now: { clock.withLock { $0 } })
        XCTAssertEqual(budget.deadline, 1_050_000_000)
        XCTAssertEqual(try budget.remainingMilliseconds(), 50)
        clock.withLock { $0 = 1_020_000_000 }
        XCTAssertEqual(try budget.remainingMilliseconds(), 30)
        try budget.admit()
        XCTAssertEqual(budget.deadline, 1_050_000_000)
        clock.withLock { $0 = 1_050_000_000 }
        XCTAssertThrowsError(try budget.remainingMilliseconds()) { error in
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    func testBudgetPreservesMillisecondAndExpiryBoundaries() throws {
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let budget = OHTTPHealthProbeBudget(milliseconds: 50, now: { clock.withLock { $0 } })
        clock.withLock { $0 = 1_049_000_000 }
        XCTAssertEqual(try budget.remainingMilliseconds(), 1)
        clock.withLock { $0 = 1_049_500_000 }
        XCTAssertNoThrow(try budget.check())
        XCTAssertThrowsError(try budget.remainingMilliseconds()) { error in
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        clock.withLock { $0 = 1_050_000_000 }
        XCTAssertThrowsError(try budget.check()) { error in
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertThrowsError(try budget.remainingMilliseconds()) { error in
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    func testBudgetPreservesZeroAndOverflowDeadlines() throws {
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let zero = OHTTPHealthProbeBudget(milliseconds: 0, now: { clock.withLock { $0 } })
        XCTAssertEqual(zero.deadline, 1_000_000_000)
        XCTAssertThrowsError(try zero.check()) { error in
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertThrowsError(try zero.remainingMilliseconds()) { error in
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let durationOverflow = OHTTPHealthProbeBudget(milliseconds: UInt64.max, now: { clock.withLock { $0 } })
        XCTAssertEqual(durationOverflow.deadline, UInt64.max)
        XCTAssertNoThrow(try durationOverflow.check())
        clock.withLock { $0 = UInt64.max - 500_000 }
        let additionOverflow = OHTTPHealthProbeBudget(milliseconds: 1, now: { clock.withLock { $0 } })
        XCTAssertEqual(additionOverflow.deadline, UInt64.max)
        XCTAssertNoThrow(try additionOverflow.check())
    }

    func testDiagnosticPauseIsPinnedToOnlyItsSession() async throws {
        let route = route()
        let first = try OHTTPHealthSession(route: route, generation: UUID())
        let other = try OHTTPHealthSession(route: route, generation: UUID())
        defer {
            first.close()
            other.close()
        }
        let pause = OHTTPHealthClock.nowNanoseconds + 20_000_000_000
        OHTTPHealthCenter.shared.begin(route: route, scope: .route)
            .record(outcome: .rateLimited(retryNotBefore: pause), stage: .responseHead)
        let before = other.snapshot()
        let result = await OHTTPHealthProbe.run(session: first) { _ in
            XCTFail("Explicit pause must prevent dispatch")
            return .usable
        }
        XCTAssertEqual(result.outcome, .rateLimited(retryNotBefore: pause))
        XCTAssertEqual(other.snapshot(), before)
        XCTAssertTrue(first.snapshot().observations.contains { $0.purpose == .diagnostic })
        first.close()
        let retired = await OHTTPHealthProbe.run(session: first) { _ in
            XCTFail("Closed session cannot dispatch")
            return .usable
        }
        XCTAssertEqual(retired.outcome, .cancelled)
    }
}

private actor ProbeRejectionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
