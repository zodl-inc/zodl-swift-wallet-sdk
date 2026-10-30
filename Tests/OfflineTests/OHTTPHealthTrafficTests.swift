import XCTest
@testable import ZODLSwiftWalletSDK

final class OHTTPHealthTrafficTests: XCTestCase {
    private func route() -> OHTTPHealthRoute {
        OHTTPHealthRoute(network: .testnet, gatewayHost: "ohttp-gateway-testnet.example", relayURL: "https://\(UUID().uuidString.lowercased()).test/relay", viaTor: false)
    }

    private func transport(_ route: OHTTPHealthRoute, error: Error, keyFailure: Bool = false) -> OHTTPTransport {
        OHTTPTransport(
            gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
            testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(), keyCache: OHTTPKeyCache(),
            httpSender: { request, _ in
                if keyFailure || request.httpMethod == "POST" { throw error }
                return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
            }
        )
    }

    func testUnaryTransportFailureRetainsOriginalOperationWithoutChangingError() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let operation = OHTTPHealthOperation()
        let transport = transport(route, error: URLError(.cannotConnectToHost))
        await OHTTPHealthContext.withOperation(operation) {
            do {
                _ = try await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
                XCTFail("Expected the original error")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
            }
        }
        let evidence = try XCTUnwrap(session.snapshot().observations.first { $0.outcome == .transportUnavailable })
        XCTAssertEqual(evidence.operation, operation)
        XCTAssertEqual(evidence.purpose, .userOperation)
        XCTAssertEqual(evidence.generation, session.generation)
    }

    func testCancelledSenderIsNotRelayUnavailable() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        _ = try? await transport(route, error: CancellationError()).roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
        XCTAssertTrue(session.snapshot().observations.contains { $0.outcome == .cancelled })
        XCTAssertFalse(session.snapshot().observations.contains { $0.outcome == .transportUnavailable })
    }

    func testKeyNetworkFailureIsObservedAfterFallbackEnds() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        _ = try? await transport(route, error: URLError(.networkConnectionLost), keyFailure: true)
            .roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
        let evidence = try XCTUnwrap(session.snapshot().observations.first { $0.outcome == .transportUnavailable })
        XCTAssertEqual(evidence.stage, .keyConfiguration)
    }

    func testSizeFailureDoesNotBecomeRelayUnavailable() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        _ = try? await transport(route, error: OHTTPError.responseTooLarge("too large"))
            .roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
        XCTAssertTrue(session.snapshot().observations.contains { $0.outcome == .responseRejected })
        XCTAssertFalse(session.snapshot().observations.contains { $0.outcome == .transportUnavailable })
    }

    func testExternalBackendFailureStillProvidesRouteSuccess() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
            testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(), keyCache: OHTTPKeyCache(),
            streamSender: { _, _ in
                OHTTPOuterStream(status: 200, contentType: "message/ohttp-chunked-res", retryAfter: nil, body: AsyncThrowingStream { continuation in
                    continuation.yield(Data([1]))
                    continuation.finish()
                })
            },
            streamDecoderFactory: { _ in PassThroughStreamDecoder(status: 503) },
            httpSender: { request, _ in (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200)) }
        )
        let request = OHTTPRequest(method: "GET", scheme: "https", authority: "near.zodl.com", path: "/quote", headers: [], body: Data())
        let response = try await transport.stream(request: request, timeoutMS: 5000)
        for try await _ in response.body {}
        let observations = session.snapshot().observations
        XCTAssertTrue(observations.contains { $0.scope == .swaps && $0.outcome == .backendUnavailable })
        XCTAssertTrue(observations.contains { $0.scope == .route && $0.outcome == .usable })
        XCTAssertFalse(observations.contains { $0.outcome == .transportUnavailable })
    }
    func testKnownOuterPolicyResponseSurvivesBodyNetworkFailure() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
            testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(), keyCache: OHTTPKeyCache(),
            streamSender: { _, _ in
                OHTTPOuterStream(status: 403, contentType: "text/plain", retryAfter: nil, body: AsyncThrowingStream { continuation in
                    continuation.finish(throwing: URLError(.networkConnectionLost))
                })
            },
            httpSender: { request, _ in (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200)) }
        )
        _ = try? await transport.stream(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
        XCTAssertTrue(session.snapshot().observations.contains { $0.outcome == .policyRejected })
        XCTAssertFalse(session.snapshot().observations.contains { $0.outcome == .transportUnavailable })
    }

    func testRealTruncatedNativeDecoderReportsAvailabilityRatherThanCryptoFailure() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
            testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(), keyCache: OHTTPKeyCache(),
            streamSender: { _, _ in
                OHTTPOuterStream(status: 200, contentType: "message/ohttp-chunked-res", retryAfter: nil, body: AsyncThrowingStream { continuation in
                    continuation.yield(Data(repeating: 0, count: 8))
                    continuation.finish()
                })
            },
            httpSender: { request, _ in (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200)) }
        )
        _ = try? await transport.stream(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
        XCTAssertTrue(session.snapshot().observations.contains { $0.outcome == .transportUnavailable })
        XCTAssertFalse(session.snapshot().observations.contains { $0.outcome == .configurationFailure })
    }

    func testDiscardedFreshnessStreamCannotOverrideFinalRetryFailure() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let firstBody = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        let finished = expectation(description: "discarded decoder finished")
        var posts = 0
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
            testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(), keyCache: OHTTPKeyCache(),
            streamSender: { _, _ in
                posts += 1
                if posts == 1 {
                    firstBody.continuation.yield(Data([1]))
                    return OHTTPOuterStream(status: 200, contentType: "message/ohttp-chunked-res", retryAfter: nil, body: firstBody.stream)
                }
                firstBody.continuation.finish()
                await self.fulfillment(of: [finished], timeout: 2)
                throw URLError(.networkConnectionLost)
            },
            streamDecoderFactory: { _ in LateRefusalDecoder(finished: finished) },
            httpSender: { request, _ in (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200)) }
        )
        _ = try? await transport.stream(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
        XCTAssertEqual(posts, 2)
        XCTAssertTrue(session.snapshot().observations.contains { $0.outcome == .transportUnavailable })
        XCTAssertFalse(session.snapshot().observations.contains { $0.outcome == .responseRejected })
    }

    func testCancelledDiagnosticKeyFetchDoesNotCancelSharedRealRequest() async throws {
        let route = route()
        let started = expectation(description: "real key fetch started")
        let diagnosticStarted = expectation(description: "diagnostic has independent key ownership")
        let gate = HealthKeyGate()
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
            testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(), keyCache: OHTTPKeyCache(),
            httpSender: { request, _ in
                if OHTTPHealthProbe.budget != nil {
                    diagnosticStarted.fulfill()
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } else {
                    started.fulfill()
                    await gate.wait()
                }
                return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
            }
        )
        let real = Task { try await transport.keyConfig() }
        await fulfillment(of: [started], timeout: 2)
        let probe = Task {
            try await OHTTPHealthProbe.$budget.withValue(OHTTPHealthProbeBudget(milliseconds: 5000)) {
                try await transport.keyConfig()
            }
        }
        await fulfillment(of: [diagnosticStarted], timeout: 2)
        probe.cancel()
        do {
            _ = try await probe.value
            XCTFail("Diagnostic must cancel")
        } catch { XCTAssertTrue(error is CancellationError) }
        await gate.release()
        _ = try await real.value
    }

    func testDirectExchangeDeadlineIsAvailabilityAndPreservesOriginalError() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PendingHealthURLProtocol.self]
        let urlSession = URLSession(configuration: config)
        defer { urlSession.invalidateAndCancel() }
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
            testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(), keyCache: OHTTPKeyCache(),
            httpSender: { request, maxBytes in
                if request.httpMethod == "POST" {
                    let (data, response) = try await OHTTPTransport.boundedDataWithDeadline(
                        for: request, maxBytes: maxBytes, session: urlSession, deadlineSeconds: 0.01
                    )
                    return (data, response as! HTTPURLResponse)
                }
                return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
            }
        )
        do {
            _ = try await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
            XCTFail("Deadline must fail")
        } catch {
            guard case .transportError = error as? OHTTPError else { return XCTFail("Original transport error must remain") }
        }
        XCTAssertTrue(session.snapshot().observations.contains { $0.outcome == .transportUnavailable })
    }

    func testKnownInnerPolicySurvivesTypedTruncatedBody() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let body = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
            testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(), keyCache: OHTTPKeyCache(),
            streamSender: { _, _ in
                body.continuation.yield(Data([1]))
                return OHTTPOuterStream(status: 200, contentType: "message/ohttp-chunked-res", retryAfter: nil, body: body.stream)
            },
            streamDecoderFactory: { _ in RejectedTruncatedDecoder() },
            httpSender: { request, _ in (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200)) }
        )
        let response = try await transport.stream(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
        body.continuation.finish()
        do { for try await _ in response.body {} } catch { }
        XCTAssertTrue(session.snapshot().observations.contains { $0.outcome == .policyRejected && $0.stage == .responseBody })
        XCTAssertFalse(session.snapshot().observations.contains { $0.outcome == .transportUnavailable })
    }

    func testSharedKeyFailureKeepsTypedProvenanceForEveryWaiter() async throws {
        let route = OHTTPHealthRoute(network: .testnet, gatewayHost: "unknown.test", relayURL: "https://shared-key.test/relay", viaTor: false)
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let started = expectation(description: "shared key fetch started")
        let gate = HealthKeyGate()
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
            keyCache: OHTTPKeyCache(), httpSender: { _, _ in
                started.fulfill()
                await gate.wait()
                OHTTPHealthTraffic.current?.classify(.configurationFailure)
                throw ZcashError.rustTorHttpRequest("a structured native failure")
            }
        )
        let first = OHTTPHealthOperation()
        let second = OHTTPHealthOperation()
        let a = OHTTPHealthAttempt(operation: first)
        let b = OHTTPHealthAttempt(operation: second)
        let tasks = [(first, a), (second, b)].map { operation, attempt in
            Task {
                await OHTTPHealthContext.withOperation(operation) {
                    await OHTTPHealthContext.withAttempt(attempt) {
                        _ = try? await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 100)
                    }
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        try await Task.sleep(nanoseconds: 20_000_000)
        await gate.release()
        for task in tasks { await task.value }
        XCTAssertTrue(a.evidence(route: route, generation: session.generation).contains { $0.outcome == .configurationFailure })
        XCTAssertTrue(b.evidence(route: route, generation: session.generation).contains { $0.outcome == .configurationFailure })
    }

}


private actor HealthKeyGate {
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

private final class LateRefusalDecoder: OHTTPStreamDecoding {
    let finished: XCTestExpectation
    init(finished: XCTestExpectation) { self.finished = finished }
    func push(_ bytes: Data) throws -> OHTTPStreamEvents {
        var events = OHTTPStreamEvents()
        events.head = (400, [("ohttp-freshness", "rejected")])
        return events
    }
    func finish() throws -> OHTTPStreamEvents {
        OHTTPHealthTraffic.current?.nativeFailure(4)
        finished.fulfill()
        throw OHTTPError.binaryHttpError("discarded response")
    }
}

private final class PendingHealthURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

private final class RejectedTruncatedDecoder: OHTTPStreamDecoding {
    func push(_ bytes: Data) throws -> OHTTPStreamEvents {
        var events = OHTTPStreamEvents()
        events.head = (403, [])
        return events
    }
    func finish() throws -> OHTTPStreamEvents {
        OHTTPHealthTraffic.current?.nativeFailure(2)
        throw OHTTPError.transportError("truncated")
    }
}
