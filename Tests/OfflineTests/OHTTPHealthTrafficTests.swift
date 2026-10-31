import XCTest
import libzcashlc
import Network
import os
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

    private struct GRPCFailureCase {
        let status: String?
        let trailer: String?
        let corrupt: Bool
        let nativeStatus: Int32
        let outcome: OHTTPHealthOutcome
    }

    @available(iOS 17, macOS 14, *)
    func testBufferedAuthenticatedGRPCRejectionSurvivesNativeDecodeFailure() throws {
        let cases = [
            GRPCFailureCase(status: "7", trailer: nil, corrupt: false, nativeStatus: 7, outcome: .policyRejected),
            GRPCFailureCase(status: "16", trailer: nil, corrupt: false, nativeStatus: 16, outcome: .policyRejected),
            GRPCFailureCase(status: "14", trailer: nil, corrupt: false, nativeStatus: 14, outcome: .backendUnavailable),
            GRPCFailureCase(status: "12", trailer: nil, corrupt: false, nativeStatus: 12, outcome: .responseRejected),
            GRPCFailureCase(status: "0", trailer: nil, corrupt: false, nativeStatus: 0, outcome: .transportUnavailable),
            GRPCFailureCase(status: nil, trailer: nil, corrupt: false, nativeStatus: -1, outcome: .transportUnavailable),
            GRPCFailureCase(status: "bad", trailer: nil, corrupt: false, nativeStatus: -1, outcome: .transportUnavailable),
            GRPCFailureCase(status: "7", trailer: "14", corrupt: false, nativeStatus: 14, outcome: .backendUnavailable),
            GRPCFailureCase(status: "7", trailer: "0", corrupt: false, nativeStatus: 0, outcome: .transportUnavailable),
            GRPCFailureCase(status: "7", trailer: nil, corrupt: true, nativeStatus: -1, outcome: .responseRejected)
        ]
        for item in cases {
            let route = route()
            let session = try OHTTPHealthSession(route: route, generation: UUID())
            defer { session.close() }
            let traffic = OHTTPHealthTraffic(route: route, request: OHTTPTestSupport.simpleRequest)
            let peer = try OHTTPTestSupport.grpcPeerResponse(status: item.status, trailer: item.trailer, corrupt: item.corrupt)
            OHTTPHealthTraffic.$current.withValue(traffic) {
                do {
                    _ = try peer.pending.complete(status: 200, contentType: "message/ohttp-chunked-res", body: peer.body, attempt: 0)
                    XCTFail("The original native decoding error must still be thrown")
                } catch {
                    XCTAssertEqual(zcashlc_ohttp_last_grpc_status(), item.nativeStatus)
                    if item.corrupt {
                        guard case .binaryHttpError = error as? OHTTPError else { return XCTFail("Expected original authentication error") }
                    } else {
                        guard case .transportError(let message) = error as? OHTTPError else { return XCTFail("Expected original truncation error") }
                        XCTAssertTrue(message.hasPrefix("the gateway's answer ended before its final chunk"))
                    }
                    traffic.failed(error)
                }
            }
            let outcomes = session.snapshot().observations.map(\.outcome)
            XCTAssertTrue(outcomes.contains(item.outcome), "status=\(item.status ?? "absent") trailer=\(item.trailer ?? "absent")")
            if item.outcome != .transportUnavailable { XCTAssertFalse(outcomes.contains(.transportUnavailable)) }
            XCTAssertFalse(
                session.snapshot().observations.contains { $0.scope != .route && $0.outcome == .usable },
                "An authenticated head cannot establish complete-body success"
            )
        }
    }

    @available(iOS 17, macOS 14, *)
    func testBufferedCompleteGRPCResponseUsesFinalStatusWithoutEarlyHeaderFailure() throws {
        for (header, trailer, expected) in [("7", "0", OHTTPHealthOutcome.usable), ("0", "16", .policyRejected), ("14", "7", .policyRejected)] {
            let traffic = OHTTPHealthTraffic(route: route(), request: OHTTPTestSupport.simpleRequest)
            let peer = try OHTTPTestSupport.grpcPeerResponse(status: header, trailer: trailer, complete: true)
            try OHTTPHealthTraffic.$current.withValue(traffic) {
                let completed = try peer.pending.complete(status: 200, contentType: "message/ohttp-chunked-res", body: peer.body, attempt: 0)
                guard case .response(let response) = completed else { return XCTFail("Expected complete response") }
                XCTAssertNil(traffic.failure, "Header status must not latch before body completion")
                XCTAssertEqual(OHTTPHealthTraffic.responseOutcome(response), expected)
            }
        }
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

    func testDiagnosticKeyHeadRejectionSurvivesBodyDeadlineAndBlocksRateLimitFallback() async throws {
        for status in [403, 426, 429] {
            let route = OHTTPHealthRoute(network: .testnet, gatewayHost: "ohttp-gateway-testnet.example", relayURL: "https://key-\(status).test/relay", viaTor: true)
            let session = try OHTTPHealthSession(route: route, generation: UUID())
            defer { session.close() }
            var requests = 0
            let transport = OHTTPTransport(
                gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
                testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(), viaTor: true, keyCache: OHTTPKeyCache(),
                httpSender: { _, _ in
                    requests += 1
                    try await Task.sleep(nanoseconds: 30_000_000)
                    throw OHTTPNativeHTTPFailure(FfiTorHttpOutcome(kind: 1, http_status: UInt16(status), retry_not_before_ns: OHTTPHealthClock.nowNanoseconds + 120_000_000_000))
                }
            )
            let result = await OHTTPHealthProbe.run(session: session, timeoutMilliseconds: 10) { budget in
                try budget.admit()
                _ = try await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
                return .usable
            }
            if status == 429 {
                guard case .rateLimited = result.outcome else { return XCTFail("Known key pause must survive deadline") }
            } else { XCTAssertEqual(result.outcome, .policyRejected) }
            XCTAssertEqual(requests, 1)
        }
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        var requests = 0
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
            keyCache: OHTTPKeyCache(), httpSender: { _, _ in
                requests += 1
                throw OHTTPNativeHTTPFailure(FfiTorHttpOutcome(kind: 2, http_status: 429, retry_not_before_ns: OHTTPHealthClock.nowNanoseconds + 120_000_000_000))
            }
        )
        let result = await OHTTPHealthProbe.run(session: session) { _ in
            _ = try await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
            return .usable
        }
        guard case .rateLimited = result.outcome else { return XCTFail("Early body failure must retain key pause") }
        XCTAssertEqual(requests, 1, "No DNS or POST may follow a known key pause")
    }

    func testDirectAndStreamOuterRejectionsSurviveBodyFailure() async throws {
        for status in [404, 409, 422] {
            for streaming in [false, true] {
                let route = OHTTPHealthRoute(network: .testnet, gatewayHost: "ohttp-gateway-testnet.example", relayURL: "https://\(UUID().uuidString.lowercased()).test/\(status)", viaTor: false)
                let session = try OHTTPHealthSession(route: route, generation: UUID())
                defer { session.close() }
                let peer = try RejectedHealthPeer(status: status)
                let ready = expectation(description: "local peer ready")
                peer.start { ready.fulfill() }
                await fulfillment(of: [ready], timeout: 2)
                defer { peer.close() }
                let urlSession = URLSession(configuration: URLSessionConfiguration.ephemeral)
                defer { urlSession.invalidateAndCancel() }
                let transport = OHTTPTransport(
                    gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
                    testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(), keyCache: OHTTPKeyCache(),
                    streamSender: { _, _ in
                        OHTTPOuterStream(status: status, contentType: "text/plain", retryAfter: nil, body: AsyncThrowingStream { continuation in
                            continuation.finish(throwing: URLError(.networkConnectionLost))
                        })
                    },
                    httpSender: { request, maxBytes in
                        if request.httpMethod == "POST" {
                            var local = request
                            local.url = URL(string: "http://127.0.0.1:\(peer.port)/rejected")!
                            local.timeoutInterval = 1
                            let (data, response) = try await OHTTPTransport.boundedData(for: local, maxBytes: maxBytes, session: urlSession)
                            return (data, response as! HTTPURLResponse)
                        }
                        return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
                    }
                )
                do {
                    if streaming { _ = try await transport.stream(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000) }
                    else { _ = try await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000) }
                    XCTFail("Original body error must remain")
                } catch { XCTAssertEqual((error as? URLError)?.code, streaming ? .networkConnectionLost : .timedOut, "\(error)") }
                XCTAssertTrue(session.snapshot().observations.contains { $0.outcome == .responseRejected }, "status \(status), streaming \(streaming)")
                XCTAssertFalse(session.snapshot().observations.contains { !$0.historical && $0.outcome == .transportUnavailable })
            }
        }
    }

    func testNativeDecodedPauseKeepsOriginalDeadlineAcrossSuccessfulBody() async throws {
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
            streamDecoderFactory: { _ in NativePauseDecoder() },
            httpSender: { request, _ in (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200)) }
        )
        let response = try await transport.stream(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
        for try await _ in response.body { }
        let pauses = session.snapshot().observations.compactMap { observation -> UInt64? in
            if case .rateLimited(let deadline) = observation.outcome { return deadline }
            return nil
        }
        XCTAssertFalse(pauses.isEmpty)
        XCTAssertTrue(pauses.allSatisfy { $0 == 123 }, "The expired authenticated head deadline must not restart in Swift")
    }

    func testInnerRetryAfterKeepsHeadDeadlineAfterDelayedBody() async throws {
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
            streamDecoderFactory: { _ in PassThroughStreamDecoder(status: 429, headers: [("retry-after", "1")]) },
            httpSender: { request, _ in (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200)) }
        )
        let beforeHead = OHTTPHealthClock.nowNanoseconds
        let response = try await transport.stream(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
        let afterHead = OHTTPHealthClock.nowNanoseconds
        let head = try XCTUnwrap(session.snapshot().observations.first { $0.stage == .responseHead && $0.scope != .route })
        guard case .rateLimited(let deadline) = head.outcome else { return XCTFail("Expected head pause") }
        XCTAssertGreaterThanOrEqual(deadline, beforeHead + 1_000_000_000)
        XCTAssertLessThanOrEqual(deadline, afterHead + 1_000_000_000)
        try await Task.sleep(nanoseconds: 1_020_000_000)
        body.continuation.finish()
        for try await _ in response.body {}
        let completed = try XCTUnwrap(session.snapshot().observations.first { $0.stage == .complete && $0.scope != .route })
        XCTAssertEqual(completed.outcome, .rateLimited(retryNotBefore: deadline))
        XCTAssertLessThan(deadline, OHTTPHealthClock.nowNanoseconds, "Body completion must not restart an expired pause")
    }

    func testDiagnosticDNSRateLimitStopsRemainingResolversAfterRelayPolicyFailure() async throws {
        let route = route()
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let pause = OHTTPHealthClock.nowNanoseconds + 120_000_000_000
        var requests = 0
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
            keyCache: OHTTPKeyCache(), httpSender: { _, _ in
                requests += 1
                if requests == 1 { throw OHTTPError.httpStatusError(statusCode: 403, message: "relay policy") }
                throw OHTTPNativeHTTPFailure(FfiTorHttpOutcome(kind: 2, http_status: 429, retry_not_before_ns: pause))
            }
        )
        let result = await OHTTPHealthProbe.run(session: session) { _ in
            _ = try await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
            return .usable
        }
        XCTAssertEqual(requests, 2, "A DNS pause prohibits the second resolver and POST")
        XCTAssertEqual(result.outcome, .rateLimited(retryNotBefore: pause))
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

private final class RejectedHealthPeer: @unchecked Sendable {
    let listener: NWListener
    let status: Int
    private let connections = OSAllocatedUnfairLock(initialState: [NWConnection]())
    var port: UInt16 { listener.port!.rawValue }
    init(status: Int) throws {
        self.status = status
        listener = try NWListener(using: .tcp, on: .any)
    }
    func start(ready: @escaping @Sendable () -> Void) {
        listener.stateUpdateHandler = { if case .ready = $0 { ready() } }
        listener.newConnectionHandler = { [self] connection in
            connections.withLock { $0.append(connection) }
            connection.start(queue: DispatchQueue.global())
            receiveRequest(connection, accumulated: Data())
        }
        listener.start(queue: DispatchQueue.global())
    }
    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] bytes, _, _, error in
            guard let bytes, error == nil else { return }
            var request = accumulated
            request.append(bytes)
            guard let separator = request.range(of: Data("\r\n\r\n".utf8)) else {
                receiveRequest(connection, accumulated: request)
                return
            }
            let headers = String(decoding: request[..<separator.lowerBound], as: UTF8.self)
            let length = headers.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            guard request.count >= separator.upperBound + length else {
                receiveRequest(connection, accumulated: request)
                return
            }
            var response = Data("HTTP/1.1 \(status) Rejected\r\nContent-Type: text/plain\r\nContent-Length: 65536\r\nConnection: close\r\n\r\n".utf8)
            // A large non-final fragment makes URLSession expose the head before the body stalls.
            response.append(Data(repeating: 120, count: 32768))
            connection.send(content: response, completion: .contentProcessed { _ in })
        }
    }
    func close() {
        listener.cancel()
        connections.withLock { connections in
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

private final class NativePauseDecoder: OHTTPStreamDecoding {
    private let decoder = PassThroughStreamDecoder(status: 429, headers: [("retry-after", "120")])
    func push(_ bytes: Data) throws -> OHTTPStreamEvents {
        OHTTPHealthTraffic.current?.decodedHead(FfiOhttpDecodeOutcome(kind: 0, http_status: 429, retry_not_before_ns: 123))
        return try decoder.push(bytes)
    }
    func finish() throws -> OHTTPStreamEvents { try decoder.finish() }
}
