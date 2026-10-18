//
//  OHTTPStreamingTests.swift
//  OfflineTests
//
//  OHTTP exchanges whose answer is read as it arrives (`OHTTPTransport.stream`): the order of head and
//  body, the retries shared with `roundTrip`, and the failures of a broken stream. The sealing is the
//  core's; the decoder is replaced by one that passes bytes through, since no test gateway seals answers.
//

import XCTest
@testable import ZODLSwiftWalletSDK

/// Passes every pushed chunk through as body bytes; the first push also yields the head.
final class PassThroughStreamDecoder: OHTTPStreamDecoding {
    let status: Int
    let headers: [(String, String)]
    let failOnFinish: Bool
    private var headSent = false

    init(status: Int = 200, headers: [(String, String)] = [("content-type", "text/event-stream")], failOnFinish: Bool = false) {
        self.status = status
        self.headers = headers
        self.failOnFinish = failOnFinish
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
        if failOnFinish {
            throw OHTTPError.transportError("the gateway's answer ended before its final chunk")
        }
        var events = OHTTPStreamEvents()
        events.end = true
        return events
    }
}

final class OHTTPStreamingTests: XCTestCase {
    private func keyResponse(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        (
            OHTTPTestSupport.stubEnvelope,
            OHTTPTestSupport.response(for: request.url, status: 200, headers: ["Content-Type": "application/json"])
        )
    }

    private func outer(status: Int, retryAfter: String? = nil, chunks: [Data]) -> OHTTPOuterStream {
        OHTTPOuterStream(
            status: status,
            contentType: "message/ohttp-chunked-res",
            retryAfter: retryAfter,
            body: AsyncThrowingStream { continuation in
                chunks.forEach { continuation.yield($0) }
                continuation.finish()
            }
        )
    }

    private func makeTransport(
        keyCache: OHTTPKeyCache = OHTTPKeyCache(),
        keyFetches: @escaping () -> Void = {},
        decoders: @escaping () -> OHTTPStreamDecoding = { PassThroughStreamDecoder() },
        streamSender: @escaping OHTTPTransport.StreamSender
    ) -> OHTTPTransport {
        OHTTPTransport(
            gatewayHost: "ohttp-gateway-testnet.example",
            relayURL: "https://testnet-operator-relay.example.invalid/relay",
            keyConfigURL: "https://testnet-operator-relay.example.invalid/ohttp-configs",
            testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(),
            keyCache: keyCache,
            streamSender: streamSender,
            streamDecoderFactory: { _ in decoders() },
            httpSender: { [self] request, _ in
                keyFetches()
                return keyResponse(request)
            }
        )
    }

    func testTheHeadComesOutBeforeTheBodyHasEnded() async throws {
        let (outerBody, outerContinuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        var posts: [URLRequest] = []
        let transport = makeTransport { request, _ in
            posts.append(request)
            return OHTTPOuterStream(status: 200, contentType: "message/ohttp-chunked-res", retryAfter: nil, body: outerBody)
        }

        outerContinuation.yield(Data("event: a\n\n".utf8))
        let streamed = try await transport.stream(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
        XCTAssertEqual(streamed.status, 200)
        XCTAssertEqual(streamed.headers.first?.0, "content-type")

        var iterator = streamed.body.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, Data("event: a\n\n".utf8), "the first event is out while the stream is still open")

        outerContinuation.yield(Data("event: b\n\n".utf8))
        outerContinuation.finish()
        let second = try await iterator.next()
        XCTAssertEqual(second, Data("event: b\n\n".utf8))
        let end = try await iterator.next()
        XCTAssertNil(end, "a stream that ends with its final chunk ends cleanly")

        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.httpMethod, "POST")
        XCTAssertEqual(posts.first?.value(forHTTPHeaderField: "Content-Type"), "message/ohttp-chunked-req")
        XCTAssertEqual(posts.first?.value(forHTTPHeaderField: "User-Agent"), "zodl-ohttp/1.0")
    }

    func testABodyThatBreaksOffFails() async throws {
        let transport = makeTransport(decoders: { PassThroughStreamDecoder(failOnFinish: true) }) { [self] _, _ in
            outer(status: 200, chunks: [Data("event: a\n\n".utf8)])
        }
        let streamed = try await transport.stream(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
        var received = Data()
        do {
            for try await chunk in streamed.body {
                received.append(chunk)
            }
            XCTFail("a truncated answer must fail the body")
        } catch {
            XCTAssertEqual(received, Data("event: a\n\n".utf8), "what came before the break is still delivered")
        }
    }

    func testAnAnswerWithoutAHeadFails() async throws {
        let transport = makeTransport { [self] _, _ in
            outer(status: 200, chunks: [])
        }
        do {
            _ = try await transport.stream(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
            XCTFail("an answer with no head must fail")
        } catch {}
    }

    func testAnOuter400FetchesTheKeyAgainAndSealsAfresh() async throws {
        var keyFetches = 0
        var posts: [Data] = []
        let transport = makeTransport(keyFetches: { keyFetches += 1 }) { [self] request, _ in
            posts.append(request.httpBody ?? Data())
            if posts.count == 1 {
                return outer(status: 400, chunks: [Data("unknown key".utf8)])
            }
            return outer(status: 200, chunks: [Data("ok".utf8)])
        }
        let streamed = try await transport.stream(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
        XCTAssertEqual(streamed.status, 200)
        XCTAssertEqual(keyFetches, 2)
        XCTAssertEqual(posts.count, 2)
        XCTAssertNotEqual(posts[0], posts[1], "every attempt is sealed afresh")
    }

    func testARefusalIsNotRetried() async throws {
        var posts = 0
        let transport = makeTransport { [self] _, _ in
            posts += 1
            return outer(status: 409, chunks: [Data("replay".utf8)])
        }
        do {
            _ = try await transport.stream(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
            XCTFail("a 409 must fail")
        } catch OHTTPError.httpStatusError(let status, _) {
            XCTAssertEqual(status, 409)
        }
        XCTAssertEqual(posts, 1)
    }

    func testARelay429SetsTheBackoffOfLaterPosts() async throws {
        let keyCache = OHTTPKeyCache()
        let transport = makeTransport(keyCache: keyCache) { [self] _, _ in
            outer(status: 429, retryAfter: "30", chunks: [Data("slow down".utf8)])
        }
        do {
            _ = try await transport.stream(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
            XCTFail("a 429 must fail")
        } catch OHTTPError.httpStatusError(let status, _) {
            XCTAssertEqual(status, 429)
        }
        let deadline = await keyCache.backoffDeadline(for: "https://testnet-operator-relay.example.invalid/relay|direct")
        let remaining = try XCTUnwrap(deadline).timeIntervalSinceNow
        XCTAssertGreaterThan(remaining, 20)
    }

    func testAFreshnessRefusalIsRetriedOnce() async throws {
        var posts = 0
        let refusal = [("ohttp-freshness", "rejected")]
        let transport = makeTransport(decoders: {
            posts == 1 ? PassThroughStreamDecoder(status: 400, headers: refusal) : PassThroughStreamDecoder()
        }) { [self] _, _ in
            posts += 1
            return outer(status: 200, chunks: [Data("x".utf8)])
        }
        let streamed = try await transport.stream(request: OHTTPTestSupport.simpleRequest, timeoutMS: 5000)
        XCTAssertEqual(streamed.status, 200)
        XCTAssertEqual(posts, 2)
    }

    func testOnlyA200IsReadAsASealedStream() throws {
        XCTAssertTrue(try OHTTPNative.answerIsSealed(status: 200, contentType: "message/ohttp-chunked-res", attempt: 0))
        XCTAssertTrue(try OHTTPNative.answerIsSealed(status: 200, contentType: nil, attempt: 1))
        for status in [204, 400, 409, 422, 429, 503] {
            XCTAssertFalse(try OHTTPNative.answerIsSealed(status: status, contentType: nil, attempt: 0), "status \(status)")
        }
    }

    func testTheNativeDecoderFailsAnAnswerThatEndsBeforeItsFinalChunk() throws {
        let key = try OHTTPTestSupport.makeKeyVerifier()(Data(), Date())
        let sealed = try OHTTPNative.encapsulate(key: key, request: OHTTPTestSupport.simpleRequest)
        let decoder = try sealed.pending.streamDecoder()
        let events = try decoder.push(Data(repeating: 0, count: 8))
        XCTAssertNil(events.head)
        XCTAssertTrue(events.body.isEmpty)
        XCTAssertThrowsError(try decoder.finish())
        XCTAssertThrowsError(try sealed.pending.streamDecoder(), "the response context is used once")
    }
}

final class OHTTPExternalHTTPTests: XCTestCase {
    func testFlexaMapsToItsGatewayAliasAndKeepsItsAuthorization() throws {
        let url = try XCTUnwrap(URL(string: "https://api.flexa.co/commerce_sessions/cs_1/approve"))
        XCTAssertEqual(OHTTPEndpoints.proxyURL(for: url)?.absoluteString, "https://flexa.zodl.com/commerce_sessions/cs_1/approve")
        XCTAssertTrue(OHTTPEndpoints.isGateway("flexa.zodl.com"))
        XCTAssertFalse(OHTTPEndpoints.needsHeaderStripping(host: "flexa.zodl.com"))
        XCTAssertTrue(OHTTPEndpoints.needsHeaderStripping(host: "cmc.zodl.com"))

        let route = try OHTTPEndpoints.proxyRoute(for: "flexa.zodl.com", network: .mainnet)
        XCTAssertEqual(route.gatewayHost, "ohttp-gateway.example")
        XCTAssertThrowsError(try OHTTPEndpoints.proxyRoute(for: "flexa.zodl.com", network: .testnet))
    }

    func testTheInnerRequestCarriesTheCallersFieldsButNotTheConnectionsOwn() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://flexa.zodl.com/events?type=a%2Cb")))
        request.httpMethod = "GET"
        request.setValue("Basic OnBsYWNlaG9sZGVy", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        let inner = try OHTTPExternalHTTP.innerRequest(for: request)
        XCTAssertEqual(inner.method, "GET")
        XCTAssertEqual(inner.authority, "flexa.zodl.com")
        XCTAssertEqual(inner.path, "/events?type=a%2Cb")
        let fields = Dictionary(inner.headers, uniquingKeysWith: { $1 })
        XCTAssertEqual(fields["authorization"], "Basic OnBsYWNlaG9sZGVy")
        XCTAssertEqual(fields["accept"], "text/event-stream")
        XCTAssertNil(fields["connection"])
        XCTAssertEqual(fields["accept-encoding"], "identity")
        XCTAssertEqual(inner.headers.filter { $0.0 == "accept-encoding" }.count, 1)
    }

    func testAliasCredentialsAreStrippedAndAStreamedBodyIsRead() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://cmc.zodl.com/v1/fiat/map")))
        request.httpMethod = "POST"
        request.setValue("secret", forHTTPHeaderField: "X-CMC_PRO_API_KEY")
        request.setValue("Bearer x", forHTTPHeaderField: "Authorization")
        request.httpBodyStream = InputStream(data: Data("{\"a\":1}".utf8))

        let inner = try OHTTPExternalHTTP.innerRequest(for: request)
        XCTAssertFalse(inner.headers.contains { $0.0 == "x-cmc_pro_api_key" || $0.0 == "authorization" })
        XCTAssertEqual(inner.body, Data("{\"a\":1}".utf8))
    }
}
