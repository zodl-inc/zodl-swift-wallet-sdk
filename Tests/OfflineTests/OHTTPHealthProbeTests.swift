import XCTest
import libzcashlc
@testable import ZODLSwiftWalletSDK

final class OHTTPHealthProbeTests: XCTestCase {
    private func route(viaTor: Bool = false) -> OHTTPHealthRoute {
        OHTTPHealthRoute(network: .testnet, gatewayHost: "ohttp-gateway-testnet.example", relayURL: "https://\(UUID().uuidString.lowercased()).test/relay", viaTor: viaTor)
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
        XCTAssertEqual(expired.outcome, .transportUnavailable)
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

    func testBudgetDoesNotResetBetweenKeyAndPost() async throws {
        let budget = OHTTPHealthProbeBudget(milliseconds: 50)
        let first = try budget.remainingMilliseconds()
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = try budget.remainingMilliseconds()
        XCTAssertLessThan(second, first)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertThrowsError(try budget.remainingMilliseconds())
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
