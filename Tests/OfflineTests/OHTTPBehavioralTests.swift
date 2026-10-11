//
//  OHTTPBehavioralTests.swift
//  OfflineTests
//
//  F-09: Behavioral tests replacing grep-based tests. Uses a protocol-injected sender to verify OHTTP
//  transport behavior without reading source files.
//
//  Tests:
//  - No retry of a 409 (replay cache) or of any status that is not a key problem
//  - 400 and 422 trigger a config refetch and exactly one retry, whatever the body says
//  - Every attempt is sealed afresh
//
//  The signed-config validation tests are in OHTTPSignedConfigTests, against the native verifier.
//

import XCTest
@testable import ZcashLightClientKit

final class OHTTPBehavioralTests: XCTestCase {

    /// Counts the key fetches and the relay posts a transport makes, answering each post from `answer`.
    private final class Counters: @unchecked Sendable {
        var keyFetches = 0
        var posts = 0
        var postBodies: [Data] = []
    }

    private func makeTransport(
        counters: Counters,
        answer: @escaping (_ attempt: Int, _ request: URLRequest) throws -> (Data, Int)
    ) -> OHTTPTransport {
        OHTTPTestSupport.makeTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/ohttp-configs/signed") {
                counters.keyFetches += 1
                return (OHTTPTestSupport.stubEnvelope, OHTTPTestSupport.response(for: request.url, status: 200))
            }
            counters.posts += 1
            counters.postBodies.append(request.httpBody ?? Data())
            let (body, status) = try answer(counters.posts, request)
            return (body, OHTTPTestSupport.response(for: request.url, status: status))
        }
    }

    private let testRequest = OHTTPRequest(
        method: "POST",
        scheme: "https",
        authority: "gateway.test.zodl.com",
        path: "/submit",
        headers: [],
        body: Data([0x01, 0x02, 0x03])
    )

    private func statusError(from transport: OHTTPTransport) async -> (code: Int, message: String)? {
        do {
            _ = try await transport.roundTrip(request: testRequest, timeoutMS: 5000)
            return nil
        } catch OHTTPError.httpStatusError(let code, let message) {
            return (code, message)
        } catch {
            return nil
        }
    }

    // MARK: - 409 Replay Cache (No Retry After Send)

    /// Tests that OHTTP transport does NOT retry when gateway returns 409 (duplicate nonce).
    /// Every attempt is sealed afresh, so a 409 is not a key problem: it is final, and the transport
    /// must fail immediately without retry.
    func testNoRetryOn409ReplayCache() async throws {
        let counters = Counters()
        let transport = makeTransport(counters: counters) { _, _ in (Data(), 409) }

        let failure = await statusError(from: transport)

        XCTAssertEqual(failure?.code, 409, "Expected 409 Conflict")
        XCTAssertEqual(counters.posts, 1, "409 should not trigger retry")
        XCTAssertEqual(counters.keyFetches, 1, "409 should not refetch the key configuration")
    }

    // MARK: - Freshness refusal (inner 400, one retry)

    private func inner(_ status: Int, _ headers: [(String, String)]) -> OHTTPResponse {
        OHTTPResponse(status: status, headers: headers, body: Data(), trailers: [])
    }

    private var freshnessRefusal: OHTTPResponse {
        inner(400, [("content-type", "text/plain"), ("Ohttp-Freshness", "rejected"), ("ohttp-server-time", "1800000000")])
    }

    func testTheFreshnessRefusalIsRecognised() {
        XCTAssertTrue(freshnessRefusal.isFreshnessRefusal)
        XCTAssertFalse(inner(400, [("content-type", "text/plain")]).isFreshnessRefusal)
        XCTAssertFalse(inner(200, [("ohttp-freshness", "rejected")]).isFreshnessRefusal)
    }

    func testAFreshnessRefusalIsSentOnceMoreAndOnlyOnce() async throws {
        let ok = inner(200, [("content-type", "application/grpc")])
        for (answers, expectedCalls, expectRefusal) in [
            ([ok], 1, false),
            ([freshnessRefusal, ok], 2, false),
            ([freshnessRefusal, freshnessRefusal, ok], 2, true)
        ] {
            var calls = 0
            let response = try await OHTTPTransport.withFreshnessRetry {
                defer { calls += 1 }
                return answers[calls]
            }
            XCTAssertEqual(calls, expectedCalls)
            XCTAssertEqual(response.isFreshnessRefusal, expectRefusal)
        }
    }

    // MARK: - 400 / 422 (Config Refetch + Single Retry)

    /// Tests that HTTP 422 triggers config refetch once and retries exactly once with the new config.
    func test422TriggersConfigRefetchAndSingleRetry() async throws {
        let counters = Counters()
        let transport = makeTransport(counters: counters) { attempt, _ in
            switch attempt {
            case 1:
                // First attempt: 422 (gateway doesn't recognize key)
                return (Data("{\"error\":\"ohttp-key\"}".utf8), 422)
            case 2:
                // Second attempt after key refresh: a 200 that does not open (there is no gateway here)
                return (OHTTPTestSupport.unopenableSealedResponse(), 200)
            default:
                XCTFail("Unexpected third attempt - should only retry once after 422")
                return (Data(), 500)
            }
        }

        do {
            _ = try await transport.roundTrip(request: testRequest, timeoutMS: 5000)
            XCTFail("The mock answer cannot open")
        } catch {
            // Allow the decryption error - we're testing retry logic, not end-to-end HPKE
        }

        XCTAssertEqual(counters.keyFetches, 2, "Config should be fetched twice (initial + refresh after 422)")
        XCTAssertEqual(counters.posts, 2, "Should attempt round trip exactly twice (initial + single retry after 422)")
    }

    /// Tests that 422 without successful retry propagates the error correctly.
    func test422RetryFailurePropagatesError() async throws {
        let counters = Counters()
        let transport = makeTransport(counters: counters) { _, _ in
            // Both attempts return 422 (key still not recognized after refresh)
            (Data("{\"error\":\"ohttp-key\"}".utf8), 422)
        }

        let failure = await statusError(from: transport)

        XCTAssertEqual(failure?.code, 422, "Expected 422 after retry failure")
        XCTAssertTrue(failure?.message.contains("ohttp-key") ?? false, "The relay's reason is quoted")
        XCTAssertEqual(counters.posts, 2, "Should attempt exactly twice before giving up")
    }

    /// A 400 or a 422 is a key problem whatever its body says: the body no longer has to mention the key.
    func testEvery400And422IsRetriedOnceWhateverTheBody() async throws {
        for status in [400, 422] {
            for body in ["", "Bad Request", "{\"error\":\"something else\"}"] {
                let counters = Counters()
                let transport = makeTransport(counters: counters) { _, _ in (Data(body.utf8), status) }

                let failure = await statusError(from: transport)

                XCTAssertEqual(failure?.code, status, "status \(status), body \(body)")
                XCTAssertEqual(counters.posts, 2, "status \(status), body \(body)")
                XCTAssertEqual(counters.keyFetches, 2, "status \(status), body \(body)")
            }
        }
    }

    /// The gateway remembers every nonce it opens, so the retry must not resend the first ciphertext.
    func testEveryAttemptIsSealedAfresh() async throws {
        let counters = Counters()
        let transport = makeTransport(counters: counters) { _, _ in (Data(), 400) }

        _ = await statusError(from: transport)

        XCTAssertEqual(counters.postBodies.count, 2)
        XCTAssertNotEqual(counters.postBodies[0], counters.postBodies[1], "The retry must be a new sealing")
        for body in counters.postBodies {
            // hdr(7) || enc(32) || the sealed request and its tag
            XCTAssertGreaterThan(body.count, 7 + 32 + 16)
            XCTAssertEqual(body.prefix(1), Data([0x01]), "The key id leads the sealed request")
            XCTAssertEqual(body.dropFirst().prefix(6), Data([0x00, 0x20, 0x00, 0x01, 0x00, 0x01]), "X25519, HKDF-SHA256, AES-128-GCM")
        }
    }

    /// Only the outer status decides: a server error that quotes "HTTP 400" in its body is not a key problem.
    func testOtherStatusesAreNotRetried() async throws {
        for status in [401, 403, 404, 413, 426, 429, 500, 502, 503] {
            let counters = Counters()
            let transport = makeTransport(counters: counters) { _, _ in (Data("HTTP 400 ohttp-key".utf8), status) }

            let failure = await statusError(from: transport)

            XCTAssertEqual(failure?.code, status)
            XCTAssertEqual(counters.posts, 1, "status \(status)")
            XCTAssertEqual(counters.keyFetches, 1, "status \(status)")
        }
    }

    /// Only a 200 carries a sealed response.
    func testA2xxOtherThan200IsRefused() async throws {
        let counters = Counters()
        let transport = makeTransport(counters: counters) { _, _ in (OHTTPTestSupport.unopenableSealedResponse(), 204) }

        let failure = await statusError(from: transport)

        XCTAssertEqual(failure?.code, 204)
        XCTAssertEqual(counters.posts, 1)
    }

    /// The cached key is used again for the next request: one fetch serves both round trips.
    func testTheKeyConfigurationIsCachedUntilItExpires() async throws {
        let counters = Counters()
        let transport = makeTransport(counters: counters) { _, _ in (Data(), 500) }

        _ = await statusError(from: transport)
        _ = await statusError(from: transport)

        XCTAssertEqual(counters.keyFetches, 1)
        XCTAssertEqual(counters.posts, 2)
    }

    /// A response that does not open is an error, never a response with made-up content.
    func testAnUnopenableAnswerIsAnError() async throws {
        let counters = Counters()
        let transport = makeTransport(counters: counters) { _, _ in (OHTTPTestSupport.unopenableSealedResponse(), 200) }

        do {
            _ = try await transport.roundTrip(request: testRequest, timeoutMS: 5000)
            XCTFail("A sealed response that does not open must fail")
        } catch OHTTPError.transportError(let message) {
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("Expected transportError, got \(error)")
        }
        XCTAssertEqual(counters.posts, 1)
    }

    /// Request text that is not ASCII (or ISO-8859-1 for a header value) is an error, where the Swift
    /// encoder trapped. Nothing is sent.
    func testNonAsciiRequestTextIsAnErrorNotACrash() async throws {
        let counters = Counters()
        let transport = makeTransport(counters: counters) { _, _ in (Data(), 200) }
        let request = OHTTPRequest(
            method: "GET",
            scheme: "https",
            authority: "gateway.test.zodl.com",
            path: "/caf\u{00e9}/\u{20ac}",
            headers: [],
            body: Data()
        )

        do {
            _ = try await transport.roundTrip(request: request, timeoutMS: 5000)
            XCTFail("A non-ASCII path must be refused")
        } catch OHTTPError.binaryHttpError {
            // expected
        } catch {
            XCTFail("Expected binaryHttpError, got \(error)")
        }
        XCTAssertEqual(counters.posts, 0)
    }
}
