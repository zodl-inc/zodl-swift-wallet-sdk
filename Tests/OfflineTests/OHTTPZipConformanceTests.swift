//
//  OHTTPZipConformanceTests.swift
//  OfflineTests
//
//  The transport rules on key caching, relay headers, 429 back-off, request resends, error mapping and
//  gateway selection.
//

import XCTest
import CryptoKit
import os
@testable import ZODLSwiftWalletSDK

final class OHTTPZipConformanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OHTTPTestSupport.installExampleConfiguration()
    }

    private final class Recorder: @unchecked Sendable {
        var keyFetches = 0
        var posts: [URLRequest] = []
        var gets: [URLRequest] = []
    }

    private let request = OHTTPRequest(
        method: "POST",
        scheme: "https",
        authority: OHTTPTestSupport.testnetHost,
        path: "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLatestBlock",
        headers: [],
        body: Data([0x00])
    )

    private func makeTransport(
        recorder: Recorder,
        cache: OHTTPKeyCache,
        postAnswer: @escaping (URLRequest) -> (Int, [String: String]?) = { _ in (503, nil) }
    ) -> OHTTPTransport {
        OHTTPTestSupport.makeTransport(keyCache: cache) { request, _ in
            if request.httpMethod == "GET" {
                recorder.keyFetches += 1
                recorder.gets.append(request)
                return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
            }
            recorder.posts.append(request)
            let (status, headers) = postAnswer(request)
            return (Data(), OHTTPTestSupport.response(for: request.url, status: status, headers: headers))
        }
    }

    // MARK: - Key configuration cache

    func testTransportsOfOneRelayShareTheCachedKeyConfiguration() async throws {
        let recorder = Recorder()
        let cache = OHTTPKeyCache()

        for _ in 0..<3 {
            let transport = makeTransport(recorder: recorder, cache: cache)
            _ = try await transport.keyConfig()
        }

        XCTAssertEqual(recorder.keyFetches, 1, "a transport made per call must reuse the cached key configuration")
    }

    func testConcurrentColdCallsShareOneKeyFetch() async throws {
        let recorder = Recorder()
        let cache = OHTTPKeyCache()
        let transports = (0..<4).map { _ in
            OHTTPTestSupport.makeTransport(keyCache: cache) { request, _ in
                recorder.keyFetches += 1
                try await Task.sleep(nanoseconds: 200_000_000)
                return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for transport in transports {
                group.addTask { _ = try await transport.keyConfig() }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(recorder.keyFetches, 1, "concurrent cold calls must not each fetch the key configuration")
    }

    func testTorAndDirectTransportsKeepSeparateEntries() async throws {
        let recorder = Recorder()
        let cache = OHTTPKeyCache()
        let sender: OHTTPTransport.HTTPSender = { request, _ in
            recorder.keyFetches += 1
            return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
        }
        for viaTor in [false, true, false, true] {
            let transport = OHTTPTransport(
                gatewayHost: OHTTPTestSupport.testnetHost,
                relayURL: "https://testnet-operator-relay.example.invalid/relay",
                testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(),
                viaTor: viaTor,
                keyCache: cache,
                httpSender: sender
            )
            _ = try await transport.keyConfig()
        }

        XCTAssertEqual(recorder.keyFetches, 2)
    }

    // MARK: - Relay headers

    func testRelayRequestsCarryFixedUserAgentAndLanguage() async throws {
        let recorder = Recorder()
        let transport = makeTransport(recorder: recorder, cache: OHTTPKeyCache())

        _ = try? await transport.roundTrip(request: request, timeoutMS: 5000)

        let requests = recorder.gets + recorder.posts
        XCTAssertFalse(recorder.posts.isEmpty)
        for sent in requests {
            XCTAssertEqual(sent.value(forHTTPHeaderField: "User-Agent"), "zodl-ohttp/1.0")
            XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept-Language"), "en")
            XCTAssertNil(sent.value(forHTTPHeaderField: "Cookie"))
        }
    }

    // MARK: - 429

    func testRetryAfterIsReadInSecondsAndCapped() {
        XCTAssertEqual(OHTTPTransport.retryAfter("7"), 7)
        XCTAssertEqual(OHTTPTransport.retryAfter("3600"), OHTTPTransport.maxRetryAfter)
        XCTAssertNil(OHTTPTransport.retryAfter(nil))
        XCTAssertNil(OHTTPTransport.retryAfter("soon"))
        XCTAssertNil(OHTTPTransport.retryAfter("-5"))
    }

    func testACallDuringTheRetryAfterPauseFailsLocallyWithoutRefetchingTheKey() async throws {
        let recorder = Recorder()
        let cache = OHTTPKeyCache()
        let transport = makeTransport(recorder: recorder, cache: cache) { _ in (429, ["Retry-After": "30"]) }

        do {
            _ = try await transport.roundTrip(request: request, timeoutMS: 5000)
            XCTFail("a 429 is an error")
        } catch OHTTPError.httpStatusError(let status, _) {
            XCTAssertEqual(status, 429)
        }
        XCTAssertEqual(recorder.posts.count, 1, "a 429 is not retried within the call")

        let secondCall = Date()
        do {
            _ = try await transport.roundTrip(request: request, timeoutMS: 5000)
            XCTFail("a call during the pause fails")
        } catch OHTTPError.httpStatusError(let status, _) {
            XCTAssertEqual(status, 429)
        }
        XCTAssertLessThan(Date().timeIntervalSince(secondCall), 1, "a call during the pause fails at once, it does not wait the pause out")
        XCTAssertEqual(recorder.posts.count, 1, "a call during the pause is failed locally, not posted")
        XCTAssertEqual(recorder.keyFetches, 1, "a 429 never refetches the key configuration")
    }

    func testA429BacksOffEveryGatewayBehindTheSameRelay() async throws {
        let recorder = Recorder()
        let cache = OHTTPKeyCache()
        let limited = makeTransport(recorder: recorder, cache: cache) { _ in (429, ["Retry-After": "1"]) }
        _ = try? await limited.roundTrip(request: request, timeoutMS: 5000)
        let otherRecorder = Recorder()

        let other = OHTTPTransport(
            gatewayHost: "cmc.zodl.com",
            relayURL: "https://testnet-operator-relay.example.invalid/relay",
            testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(),
            keyCache: cache
        ) { request, _ in
            otherRecorder.gets.append(request)
            if request.httpMethod == "GET" {
                return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
            }
            return (Data(), OHTTPTestSupport.response(for: request.url, status: 503))
        }
        do {
            _ = try await other.roundTrip(request: request, timeoutMS: 5000)
            XCTFail("the relay pause applies to every gateway behind it")
        } catch OHTTPError.httpStatusError(let status, _) {
            XCTAssertEqual(status, 429)
        }
        XCTAssertEqual(otherRecorder.gets.count, 0, "the back-off belongs to the relay, not to one gateway")
    }

    func testAKeyFetchDuringTheRelayPauseIsFailedLocallyWithoutAnyRequest() async throws {
        let recorder = Recorder()
        let cache = OHTTPKeyCache()
        // A known gateway host, so the DNS source exists; the key cache is empty.
        let transport = makeTransport(recorder: recorder, cache: cache)
        await transport.noteRelayAnswer(status: 429, retryAfter: "30")

        do {
            _ = try await transport.keyConfig()
            XCTFail("a key fetch during the pause fails")
        } catch OHTTPError.httpStatusError(let status, _) {
            XCTAssertEqual(status, 429)
        }
        XCTAssertEqual(recorder.gets.count, 0, "during the pause nothing is sent: no relay GET and no DoH query")
    }

    func testARelay429OnTheKeyFetchIsBackOffNotAReasonForDNS() async throws {
        let recorder = Recorder()
        let transport = OHTTPTestSupport.makeTransport(keyCache: OHTTPKeyCache()) { request, _ in
            recorder.gets.append(request)
            return (Data(), OHTTPTestSupport.response(for: request.url, status: 429, headers: ["Retry-After": "7"]))
        }

        do {
            _ = try await transport.keyConfig()
            XCTFail("a 429 on the key fetch is an error")
        } catch OHTTPError.httpStatusError(let status, _) {
            XCTAssertEqual(status, 429)
        }
        XCTAssertEqual(recorder.gets.map { $0.url?.host }, ["testnet-operator-relay.example.invalid"], "the relay's 429 is final: no DoH resolver is asked")
        do {
            try await transport.checkRelayBackoff()
            XCTFail("the Retry-After of the key fetch's 429 starts the relay pause")
        } catch OHTTPError.httpStatusError(let status, _) {
            XCTAssertEqual(status, 429)
        }
    }

    func testA429WithoutRetryAfterStartsTheDefaultPause() async throws {
        let recorder = Recorder()
        let cache = OHTTPKeyCache()
        let transport = makeTransport(recorder: recorder, cache: cache) { _ in (429, nil) }

        do {
            _ = try await transport.roundTrip(request: request, timeoutMS: 5000)
            XCTFail("a 429 is an error")
        } catch OHTTPError.httpStatusError(let status, _) {
            XCTAssertEqual(status, 429)
        }
        let remaining = await transport.relayPauseRemaining()
        XCTAssertEqual(
            try XCTUnwrap(remaining, "a 429 with no Retry-After starts the client's own pause"),
            OHTTPTransport.defaultRateLimitPause,
            accuracy: 2
        )
        XCTAssertEqual(OHTTPTransport.defaultRateLimitPause, 30, "the ZIP's reference default")

        do {
            _ = try await transport.roundTrip(request: request, timeoutMS: 5000)
            XCTFail("a call during the pause fails")
        } catch OHTTPError.httpStatusError(let status, _) {
            XCTAssertEqual(status, 429)
        }
        XCTAssertEqual(recorder.posts.count, 1, "the next call is failed locally, not posted")
    }

    func testACancelledCallerStopsWaitingWhileTheSharedKeyFetchContinues() async throws {
        let recorder = Recorder()
        let cache = OHTTPKeyCache()
        let transport = OHTTPTestSupport.makeTransport(keyCache: cache) { request, _ in
            recorder.keyFetches += 1
            try await Task.sleep(nanoseconds: 600_000_000)
            return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
        }

        let cancelled = Task { try await transport.keyConfig() }
        let other = Task { try await transport.keyConfig() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelledAt = Date()
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("a cancelled caller does not get the key")
        } catch is CancellationError {
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.3, "a cancelled caller stops waiting at once")

        _ = try await other.value
        XCTAssertEqual(recorder.keyFetches, 1, "the fetch the cancelled caller started served the other caller")
        _ = try await transport.keyConfig()
        XCTAssertEqual(recorder.keyFetches, 1, "the shared fetch's key is stored")
    }

    func testTheKeyOfAFetchWhoseOnlyCallerWasCancelledIsStored() async throws {
        let recorder = Recorder()
        let cache = OHTTPKeyCache()
        let transport = OHTTPTestSupport.makeTransport(keyCache: cache) { request, _ in
            recorder.keyFetches += 1
            try await Task.sleep(nanoseconds: 300_000_000)
            return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
        }

        let only = Task { try await transport.keyConfig() }
        try await Task.sleep(nanoseconds: 100_000_000)
        only.cancel()
        _ = try? await only.value
        try await Task.sleep(nanoseconds: 400_000_000)

        _ = try await transport.keyConfig()
        XCTAssertEqual(recorder.keyFetches, 1, "the fetch ran on after its caller left and its key was stored")
    }

    // MARK: - No transparent resend

    func testTheRelayBodyIsAStreamThatCannotBeReplayed() throws {
        var post = URLRequest(url: try XCTUnwrap(URL(string: "https://testnet-operator-relay.example.invalid/relay")))
        post.httpMethod = "POST"
        post.httpBody = Data(repeating: 7, count: 42)

        let streamed = OHTTPTransport.oneShotBody(post)

        XCTAssertNil(streamed.httpBody)
        XCTAssertNotNil(streamed.httpBodyStream)
        XCTAssertEqual(streamed.value(forHTTPHeaderField: "Content-Length"), "42")
    }

    func testTheRelaySessionIsReplacedAfterItsLifetime() {
        XCTAssertLessThanOrEqual(OHTTPTransport.sessionLifetime, 30 * 60)
        let lifetime = OHTTPTransport.sessionLifetime
        let sessions = RotatingSession(lifetime: lifetime)
        let start = Date()

        let first = sessions.acquire(now: start)
        XCTAssertTrue(
            first.session === sessions.acquire(now: start.addingTimeInterval(lifetime - 1)).session,
            "within its lifetime the session is reused"
        )
        let second = sessions.acquire(now: start.addingTimeInterval(lifetime))
        XCTAssertFalse(first.session === second.session, "once it is as old as its lifetime a fresh session replaces it")
        XCTAssertTrue(second.session === sessions.acquire(now: start.addingTimeInterval(lifetime + 1)).session)
    }

    // MARK: - gRPC status of a failed exchange

    func testFailedExchangesMapToTheZipStatuses() {
        func code(_ error: Error) -> Int? {
            if case LightWalletServiceError.failed(let code, _) = OHTTPGRPCClient.serviceError(for: error) {
                return code
            }
            return nil
        }

        XCTAssertEqual(code(OHTTPError.requestTooLarge("big")), 8)
        XCTAssertEqual(code(OHTTPError.httpStatusError(statusCode: 413, message: "")), 8)
        XCTAssertEqual(code(OHTTPError.binaryHttpError("bad framing")), 13)
        XCTAssertEqual(code(OHTTPError.responseTooLarge("big answer")), 13)
        XCTAssertEqual(code(OHTTPError.native("the gateway's answer does not open")), 13)
        XCTAssertEqual(code(OHTTPError.native("the gateway's answer ended before its final chunk")), 14)
        for status in [401, 403, 409, 426, 429, 500, 502, 503] {
            XCTAssertEqual(code(OHTTPError.httpStatusError(statusCode: status, message: "")), 14, "\(status)")
        }
        XCTAssertEqual(code(OHTTPError.transportError("cut")), 14)
        XCTAssertEqual(code(OHTTPError.keyConfigError("refused")), 14)
        XCTAssertEqual(code(URLError(.networkConnectionLost)), 14)
        XCTAssertTrue(OHTTPGRPCClient.serviceError(for: CancellationError()) is CancellationError)
    }

    func testNativeOpenFailuresAreFormatErrors() {
        guard case .binaryHttpError = OHTTPError.native("the gateway's answer does not open") else {
            return XCTFail("an answer that does not open is a format failure")
        }
        guard case .transportError = OHTTPError.native("the gateway's answer ended before its final chunk") else {
            return XCTFail("a response cut off before its final chunk is a transport failure (UNAVAILABLE)")
        }
        guard case .responseTooLarge = OHTTPError.native("an answer larger than 10 bytes") else {
            return XCTFail("an oversized answer is a size failure")
        }
    }

    func testGRPCStatusIsTakenFromTheTrailersFirst() {
        let response = OHTTPResponse(
            status: 200,
            headers: [("grpc-status", "0")],
            body: Data(),
            trailers: [("grpc-status", "14")]
        )
        XCTAssertEqual(response.field("grpc-status"), "14")
    }

    // MARK: - Gateway selection

    func testThirdPartyHostsUseTheGatewayOfTheWalletNetwork() throws {
        let testnet = try OHTTPEndpoints.proxyRoute(for: "vote.zodl.com", network: .testnet)
        XCTAssertEqual(testnet.gatewayHost, OHTTPTestSupport.testnetHost)
        XCTAssertEqual(testnet.relayURL, OHTTPNative.relayURL(for: OHTTPTestSupport.testnetHost))

        let mainnet = try OHTTPEndpoints.proxyRoute(for: "cmc.zodl.com", network: .mainnet)
        XCTAssertEqual(mainnet.gatewayHost, OHTTPTestSupport.mainnetHost)

        let gateway = try OHTTPEndpoints.proxyRoute(for: OHTTPTestSupport.testnetHost, network: .testnet)
        XCTAssertEqual(gateway.gatewayHost, OHTTPTestSupport.testnetHost)
        XCTAssertThrowsError(
            try OHTTPEndpoints.proxyRoute(for: OHTTPTestSupport.mainnetHost, network: .testnet),
            "a testnet call never goes to the mainnet gateway"
        )
    }

    func testAGatewayOfTheOtherNetworkIsRefusedBeforeAnyRequest() async throws {
        XCTAssertNoThrow(try OHTTPEndpoints.checkGatewayNetwork(host: OHTTPTestSupport.mainnetHost, network: .mainnet))
        XCTAssertNoThrow(try OHTTPEndpoints.checkGatewayNetwork(host: OHTTPTestSupport.testnetHost, network: .testnet))
        XCTAssertNoThrow(try OHTTPEndpoints.checkGatewayNetwork(host: "lwd.example.com", network: .testnet))
        XCTAssertThrowsError(try OHTTPEndpoints.checkGatewayNetwork(host: OHTTPTestSupport.mainnetHost, network: .testnet))
        XCTAssertThrowsError(try OHTTPEndpoints.checkGatewayNetwork(host: OHTTPTestSupport.testnetHost, network: .mainnet))

        let endpoint = LightWalletEndpoint(address: OHTTPTestSupport.mainnetHost, port: 443, secure: true)
        let service = LightWalletOHTTPService(
            endpoint: endpoint,
            singleCallTimeout: 1000,
            streamingCallTimeout: 1000,
            tor: TorClient(torDir: FileManager.default.temporaryDirectory),
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        )
        service.walletNetwork = .testnet
        do {
            _ = try await service.latestBlock(mode: .direct)
            XCTFail("a testnet wallet must not call the mainnet gateway")
        } catch ZcashError.compactBlockProcessorChainName {
        }
    }

    func testMempoolStreamIsAvailableOverOHTTP() throws {
        // GetMempoolStream works over OHTTP using the streaming transport (ZIP #10, lines 149-153).
        // The gateway ends it with grpc-status: 0 after ~25s without messages, which the caller
        // treats as "poll again later", not an error (ZIP #10, lines 1294-1295).
        let endpoint = LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443, secure: true)
        let service = LightWalletOHTTPService(endpoint: endpoint, tor: TorClient(torDir: FileManager.default.temporaryDirectory))
        service.walletNetwork = .testnet
        // S2: inject testClearnetSender so this offline test makes no real network call
        service.testClearnetSender = { request, _ in
            (Data(), OHTTPTestSupport.response(for: request.url, status: 200))
        }

        // GetMempoolStream no longer throws before any request (the old behavior that this replaces).
        // It returns a stream that will go through the relay when iterated.
        let stream = try service.getMempoolStream()
        XCTAssertNotNil(stream, "GetMempoolStream returns a stream over OHTTP")

        // Full streaming behavior (clean end = poll again) is tested in OHTTPStreamingTests
        // and integration tests, not here where we have no fake relay infrastructure.
    }

    func testMempoolStreamInTorModeUsesTorStreamSender() async throws {
        // S2: when Tor is in use, getMempoolStream must use the Tor circuit, not clearnet
        let endpoint = LightWalletEndpoint(address: OHTTPTestSupport.testnetHost, port: 443, secure: true)
        let runtimes = TorTestRuntimes()
        let state = TorRoutingState()
        let torDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohttp-tor-routing-\(UUID().uuidString)", isDirectory: true)
        let native = TorHTTPGetNative(
            isolateRuntime: { pointer in
                state.withLock { $0.runtimeIsolations += 1 }
                XCTAssertTrue(runtimes.isAlive(pointer))
                return runtimes.clone(pointer)
            },
            freeRuntime: { pointer in
                runtimes.free(pointer)
            },
            startup: TorRuntimeStartupNative.fixture { path, _ in
                state.withLock { $0.runtimeCreations += 1 }
                XCTAssertEqual(path, torDirectory.path)
                return runtimes.parent
            }
        )
        let tor = TorClient(torDir: torDirectory, httpGetNative: native)
        let service = LightWalletOHTTPService(endpoint: endpoint, tor: tor)
        service.walletNetwork = .testnet
        service.sdkFlags = SDKFlags(torEnabled: true, exchangeRateEnabled: false)

        defer { try? FileManager.default.removeItem(at: torDirectory) }

        // Stub key verifier for the transport
        let stubKeyVerifier: (Data, Date) throws -> OHTTPVerifiedKey = { _, _ in
            var keyBytes = Data([0x01])
            keyBytes.append(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
            return OHTTPVerifiedKey(
                bytes: keyBytes,
                notAfter: UInt64(Date().timeIntervalSince1970) + 3600,
                isTestnet: true
            )
        }

        service.testKeyVerifier = stubKeyVerifier
        // The key-configuration GET goes through the Tor HTTP sender: stub it too, so the test
        // never bootstraps Tor or depends on a key another test left in the shared cache.
        service.testTorSender = { isolated in
            state.withLock { $0.isolatedRuntime = isolated }
            return { request, _ in
                (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
            }
        }
        service.testTorStreamSender = { isolated in
            state.withLock { $0.isolatedRuntime = isolated }
            return { _, _ in
                state.withLock { $0.torStreamCalls += 1 }
                // A malformed response is enough once the stream route itself is exercised.
                return OHTTPOuterStream(
                    status: 200,
                    contentType: "message/ohttp-chunked-res",
                    retryAfter: nil,
                    body: AsyncThrowingStream { continuation in
                        // Yield enough data for a minimal OHTTP sealed response (just a header)
                        continuation.yield(Data(repeating: 0, count: 48))
                        continuation.finish()
                    }
                )
            }
        }
        service.testClearnetSender = { _, _ in
            state.withLock { $0.clearnetHTTPCalls += 1 }
            throw OHTTPError.transportError("Unexpected clearnet HTTP sender invocation")
        }
        service.testClearnetStreamSender = { _, _ in
            state.withLock { $0.clearnetStreamCalls += 1 }
            throw OHTTPError.transportError("Unexpected clearnet stream sender invocation")
        }

        do {
            // The transport is lazy, so iterate to trigger creation and its sender.
            let stream = try service.getMempoolStream()
            XCTAssertNotNil(stream, "GetMempoolStream returns a stream")
            var iterator = stream.makeAsyncIterator()
            _ = try await iterator.next()
        } catch {
            let calls = state.withLock { $0 }
            XCTAssertEqual(calls.torStreamCalls, 1, "Only a malformed response after Tor routing is expected to fail")
        }

        let isolatedRuntime = state.withLock { counts -> TorClient? in
            let isolatedRuntime = counts.isolatedRuntime
            counts.isolatedRuntime = nil
            return isolatedRuntime
        }
        try await isolatedRuntime?.close()
        try await tor.close()
        XCTAssertNil(state.withLock { $0.isolatedRuntime }, "The routing state must release its isolated runtime")
        let calls = state.withLock { $0 }
        XCTAssertEqual(calls.runtimeCreations, 1, "Tor runtime creation must be injected")
        XCTAssertEqual(calls.runtimeIsolations, 1, "Tor stream transport must receive an isolated runtime")
        XCTAssertEqual(calls.torStreamCalls, 1, "Tor mode must invoke the Tor stream sender")
        XCTAssertEqual(calls.clearnetHTTPCalls, 0, "Tor mode must not invoke clearnet HTTP")
        XCTAssertEqual(calls.clearnetStreamCalls, 0, "Tor mode must not invoke clearnet streaming")
        XCTAssertFalse(runtimes.isAlive(runtimes.parent), "Closing the client must release its fake runtime")
    }

    private final class TorRoutingState: Sendable {
        struct Counts: Sendable {
            var runtimeCreations = 0
            var runtimeIsolations = 0
            var torStreamCalls = 0
            var clearnetHTTPCalls = 0
            var clearnetStreamCalls = 0
            var isolatedRuntime: TorClient?
        }

        private let counts = OSAllocatedUnfairLock(initialState: Counts())

        func withLock<T: Sendable>(_ body: @Sendable (inout Counts) -> T) -> T {
            counts.withLock(body)
        }
    }

    // MARK: - One client per circuit

    func testConcurrentFirstCallsOnOneCircuitMakeOneClient() async throws {
        final class Made: @unchecked Sendable { var count = 0 }
        let pool = OHTTPClientPool()
        let made = Made()
        let make: @Sendable () async throws -> OHTTPGRPCClient = {
            made.count += 1
            try await Task.sleep(nanoseconds: 100_000_000)
            let transport = OHTTPTestSupport.makeTransport { _, _ in throw OHTTPError.transportError("unused") }
            return OHTTPGRPCClient(authority: OHTTPTestSupport.testnetHost, transport: transport, singleCallTimeoutMS: 1000, streamingCallTimeoutMS: 1000)
        }

        let clients = try await withThrowingTaskGroup(of: OHTTPGRPCClient.self) { group in
            for _ in 0..<4 {
                group.addTask { try await pool.client(for: "shared", make: make) }
            }
            var clients: [OHTTPGRPCClient] = []
            for try await client in group {
                clients.append(client)
            }
            return clients
        }

        XCTAssertEqual(made.count, 1, "concurrent first calls on one circuit share one creation")
        XCTAssertTrue(clients.allSatisfy { $0 === clients[0] })
        let later = try await pool.client(for: "shared", make: make)
        XCTAssertTrue(later === clients[0], "a later call finds the stored client")
        _ = try await pool.client(for: nil, make: make)
        XCTAssertEqual(made.count, 2, "another circuit gets its own client")
    }

    // MARK: - Tor mode on the gRPC service

    func testDirectCallsGoOverTorWhileTorModeIsOn() async throws {
        let endpoint = LightWalletEndpoint(address: "lwd.example.com", port: 443, secure: true)
        let service = LightWalletGRPCServiceOverTor(endpoint: endpoint, tor: TorClient(torDir: FileManager.default.temporaryDirectory))

        var resolved = await service.resolvedMode(.direct)
        XCTAssertEqual(resolved, .direct, "no Tor mode known: direct stays direct")

        service.sdkFlags = SDKFlags(torEnabled: true, exchangeRateEnabled: false)
        resolved = await service.resolvedMode(.direct)
        XCTAssertEqual(resolved, .defaultTor)
        resolved = await service.resolvedMode(.uniqueTor)
        XCTAssertEqual(resolved, .uniqueTor)

        service.sdkFlags = SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        resolved = await service.resolvedMode(.direct)
        XCTAssertEqual(resolved, .direct)
    }

    func testStreamingCallsAreRefusedOverPlainGRPCWhileTorModeIsOn() async throws {
        let endpoint = LightWalletEndpoint(address: "lwd.example.com", port: 443, secure: true)
        let service = LightWalletGRPCServiceOverTor(endpoint: endpoint, tor: TorClient(torDir: FileManager.default.temporaryDirectory))
        service.sdkFlags = SDKFlags(torEnabled: true, exchangeRateEnabled: false)

        do {
            for try await _ in try service.blockStream(startHeight: 1, endHeight: 2, mode: .direct) {}
            XCTFail("a plain gRPC stream must not be opened in Tor mode")
        } catch ZcashError.grpcServiceCalledWithTorMode {
        }
    }

    // MARK: - GRPCFrameDecoder unit tests

    func testGRPCFrameDecoderHandlesTwoFramesInSequence() throws {
        let decoder = GRPCFrameDecoder<BlockID>()

        // Create a simple BlockID message
        var block1 = BlockID()
        block1.height = 12345
        let data1 = try block1.serializedData()

        var block2 = BlockID()
        block2.height = 67890
        let data2 = try block2.serializedData()

        // Frame 1: 5-byte header + data1
        var chunk = Data()
        chunk.append(0x00) // not compressed
        let len1 = UInt32(data1.count)
        chunk.append(UInt8((len1 >> 24) & 0xFF))
        chunk.append(UInt8((len1 >> 16) & 0xFF))
        chunk.append(UInt8((len1 >> 8) & 0xFF))
        chunk.append(UInt8(len1 & 0xFF))
        chunk.append(data1)

        // Frame 2: 5-byte header + data2
        chunk.append(0x00)
        let len2 = UInt32(data2.count)
        chunk.append(UInt8((len2 >> 24) & 0xFF))
        chunk.append(UInt8((len2 >> 16) & 0xFF))
        chunk.append(UInt8((len2 >> 8) & 0xFF))
        chunk.append(UInt8(len2 & 0xFF))
        chunk.append(data2)

        let messages = try decoder.push(chunk)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].height, 12345)
        XCTAssertEqual(messages[1].height, 67890)
    }

    func testGRPCFrameDecoderHandlesFramePlusHalfFrame() throws {
        let decoder = GRPCFrameDecoder<BlockID>()

        var block1 = BlockID()
        block1.height = 11111
        let data1 = try block1.serializedData()

        var block2 = BlockID()
        block2.height = 22222
        let data2 = try block2.serializedData()

        // First chunk: complete frame 1 + half of frame 2 header
        var chunk1 = Data()
        chunk1.append(0x00)
        let len1 = UInt32(data1.count)
        chunk1.append(UInt8((len1 >> 24) & 0xFF))
        chunk1.append(UInt8((len1 >> 16) & 0xFF))
        chunk1.append(UInt8((len1 >> 8) & 0xFF))
        chunk1.append(UInt8(len1 & 0xFF))
        chunk1.append(data1)
        chunk1.append(0x00) // first 3 bytes of frame 2 header
        chunk1.append(UInt8((UInt32(data2.count) >> 24) & 0xFF))
        chunk1.append(UInt8((UInt32(data2.count) >> 16) & 0xFF))

        let messages1 = try decoder.push(chunk1)
        XCTAssertEqual(messages1.count, 1)
        XCTAssertEqual(messages1[0].height, 11111)

        // Second chunk: rest of frame 2 header + body
        var chunk2 = Data()
        let len2 = UInt32(data2.count)
        chunk2.append(UInt8((len2 >> 8) & 0xFF))
        chunk2.append(UInt8(len2 & 0xFF))
        chunk2.append(data2)

        let messages2 = try decoder.push(chunk2)
        XCTAssertEqual(messages2.count, 1)
        XCTAssertEqual(messages2[0].height, 22222)
    }

    func testGRPCFrameDecoderHandlesHeaderSplitAcrossChunks() throws {
        let decoder = GRPCFrameDecoder<BlockID>()

        var block = BlockID()
        block.height = 99999
        let data = try block.serializedData()

        // First chunk: just the first 2 bytes of the header
        var chunk1 = Data()
        chunk1.append(0x00)
        chunk1.append(UInt8((UInt32(data.count) >> 24) & 0xFF))

        let messages1 = try decoder.push(chunk1)
        XCTAssertEqual(messages1.count, 0, "incomplete header should not produce messages")

        // Second chunk: rest of header + body
        var chunk2 = Data()
        let len = UInt32(data.count)
        chunk2.append(UInt8((len >> 16) & 0xFF))
        chunk2.append(UInt8((len >> 8) & 0xFF))
        chunk2.append(UInt8(len & 0xFF))
        chunk2.append(data)

        let messages2 = try decoder.push(chunk2)
        XCTAssertEqual(messages2.count, 1)
        XCTAssertEqual(messages2[0].height, 99999)
    }

    func testGRPCFrameDecoderRejectsOversizedLength() throws {
        let decoder = GRPCFrameDecoder<BlockID>()

        // Create a frame header with length > 4 MiB
        var chunk = Data()
        chunk.append(0x00) // not compressed
        let oversizedLen: UInt32 = 5 * 1024 * 1024 // 5 MiB
        chunk.append(UInt8((oversizedLen >> 24) & 0xFF))
        chunk.append(UInt8((oversizedLen >> 16) & 0xFF))
        chunk.append(UInt8((oversizedLen >> 8) & 0xFF))
        chunk.append(UInt8(oversizedLen & 0xFF))

        do {
            _ = try decoder.push(chunk)
            XCTFail("oversized frame length must be rejected")
        } catch {
            // Expected to throw
        }
    }

    func testGRPCFrameDecoderFinishRejectsPartialTrailingFrame() throws {
        let decoder = GRPCFrameDecoder<BlockID>()

        // Push a partial frame (just 2 bytes of header)
        var chunk = Data()
        chunk.append(0x00)
        chunk.append(0x00)

        let messages = try decoder.push(chunk)
        XCTAssertEqual(messages.count, 0)

        do {
            try decoder.finish()
            XCTFail("finish() must throw when partial frame remains")
        } catch {
            // Expected to throw
        }
    }

    func testGRPCFrameDecoderFinishSucceedsWhenBufferEmpty() throws {
        let decoder = GRPCFrameDecoder<BlockID>()

        var block = BlockID()
        block.height = 12345
        let data = try block.serializedData()

        var chunk = Data()
        chunk.append(0x00)
        let len = UInt32(data.count)
        chunk.append(UInt8((len >> 24) & 0xFF))
        chunk.append(UInt8((len >> 16) & 0xFF))
        chunk.append(UInt8((len >> 8) & 0xFF))
        chunk.append(UInt8(len & 0xFF))
        chunk.append(data)

        _ = try decoder.push(chunk)
        try decoder.finish() // Should not throw
    }

    // MARK: - gRPC streaming end-to-end tests

    private func makeGRPCFrame(_ message: BlockID) throws -> Data {
        let serialized = try message.serializedData()
        var frame = Data()
        frame.append(0x00) // not compressed
        let len = UInt32(serialized.count)
        frame.append(UInt8((len >> 24) & 0xFF))
        frame.append(UInt8((len >> 16) & 0xFF))
        frame.append(UInt8((len >> 8) & 0xFF))
        frame.append(UInt8(len & 0xFF))
        frame.append(serialized)
        return frame
    }

    /// Passes chunks through and provides trailers at the end. Used for testing gRPC streaming.
    final class GRPCTestStreamDecoder: OHTTPStreamDecoding {
        let status: Int
        let headers: [(String, String)]
        let trailers: [(String, String)]?
        private var headSent = false

        init(status: Int = 200, headers: [(String, String)] = [("content-type", "application/grpc")], trailers: [(String, String)]? = nil) {
            self.status = status
            self.headers = headers
            self.trailers = trailers
        }

        func push(_ bytes: Data) throws -> OHTTPStreamEvents {
            var events = OHTTPStreamEvents()
            if !headSent {
                headSent = true
                events.head = (status, headers)
            }
            events.body = bytes
            return events
        }

        func finish() throws -> OHTTPStreamEvents {
            var events = OHTTPStreamEvents()
            events.trailers = trailers
            events.end = true
            return events
        }
    }

    private func makeGRPCStreamTransport(
        chunks: [Data],
        trailers: [(String, String)]? = nil,
        headers: [(String, String)] = [("content-type", "application/grpc")]
    ) -> OHTTPTransport {
        OHTTPTransport(
            gatewayHost: OHTTPTestSupport.testnetHost,
            relayURL: "https://testnet-operator-relay.example.invalid/relay",
            testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(),
            streamSender: { _, _ in
                OHTTPOuterStream(
                    status: 200,
                    contentType: "message/ohttp-chunked-res",
                    retryAfter: nil,
                    body: AsyncThrowingStream { continuation in
                        for chunk in chunks {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    }
                )
            },
            streamDecoderFactory: { _ in
                GRPCTestStreamDecoder(status: 200, headers: headers, trailers: trailers)
            },
            httpSender: { request, _ in
                (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
            }
        )
    }

    func testGRPCStreamWithTwoFramesAndGRPCStatus0() async throws {
        var block1 = BlockID()
        block1.height = 100
        var block2 = BlockID()
        block2.height = 200

        let frame1 = try makeGRPCFrame(block1)
        let frame2 = try makeGRPCFrame(block2)

        let transport = makeGRPCStreamTransport(
            chunks: [frame1, frame2],
            trailers: [("grpc-status", "0")]
        )

        let client = OHTTPGRPCClient(authority: "test.zodl.com", transport: transport, singleCallTimeoutMS: 30000, streamingCallTimeoutMS: 30000)

        let stream: AsyncThrowingStream<BlockID, Error> = try await client.serverStreamingIncremental(path: "/test", request: BlockID())
        var messages: [BlockID] = []
        for try await message in stream {
            messages.append(message)
        }

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].height, 100)
        XCTAssertEqual(messages[1].height, 200)
    }

    func testGRPCStreamWithStatus13ReturnsError() async throws {
        var block1 = BlockID()
        block1.height = 100
        var block2 = BlockID()
        block2.height = 200

        let frame1 = try makeGRPCFrame(block1)
        let frame2 = try makeGRPCFrame(block2)

        let transport = makeGRPCStreamTransport(
            chunks: [frame1, frame2],
            trailers: [("grpc-status", "13"), ("grpc-message", "test%20error")]
        )

        let client = OHTTPGRPCClient(authority: "test.zodl.com", transport: transport, singleCallTimeoutMS: 30000, streamingCallTimeoutMS: 30000)

        let stream: AsyncThrowingStream<BlockID, Error> = try await client.serverStreamingIncremental(path: "/test", request: BlockID())
        var messages: [BlockID] = []
        var caughtError: Error?

        do {
            for try await message in stream {
                messages.append(message)
            }
        } catch {
            caughtError = error
        }

        XCTAssertEqual(messages.count, 2, "messages should be emitted before the error")
        XCTAssertNotNil(caughtError, "stream must throw on non-zero grpc-status")
        if let serviceError = caughtError as? LightWalletServiceError,
           case .failed(let statusCode, _) = serviceError {
            XCTAssertEqual(statusCode, 13)
        } else {
            XCTFail("expected LightWalletServiceError.failed with status 13")
        }
    }

    func testGRPCStreamWithNoStatusReturnsInternalError() async throws {
        var block1 = BlockID()
        block1.height = 100

        let frame1 = try makeGRPCFrame(block1)

        // No grpc-status in trailers or headers
        let transport = makeGRPCStreamTransport(
            chunks: [frame1],
            trailers: []
        )

        let client = OHTTPGRPCClient(authority: "test.zodl.com", transport: transport, singleCallTimeoutMS: 30000, streamingCallTimeoutMS: 30000)

        let stream: AsyncThrowingStream<BlockID, Error> = try await client.serverStreamingIncremental(path: "/test", request: BlockID())
        var messages: [BlockID] = []
        var caughtError: Error?

        do {
            for try await message in stream {
                messages.append(message)
            }
        } catch {
            caughtError = error
        }

        XCTAssertEqual(messages.count, 1, "messages should be emitted before the error")
        XCTAssertNotNil(caughtError, "stream must throw when grpc-status is missing")
        if let serviceError = caughtError as? LightWalletServiceError,
           case .failed(let statusCode, _) = serviceError {
            XCTAssertEqual(statusCode, OHTTPGRPCStatus.internalError)
        } else {
            XCTFail("expected LightWalletServiceError.failed with status INTERNAL")
        }
    }
}
