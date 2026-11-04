import Foundation
import libzcashlc
import XCTest
@testable import ZODLSwiftWalletSDK

final class OHTTPHealthTorTests: XCTestCase {
    func testBoundedPostPassesRemainingBudgetAndRetainsTypedFailure() async throws {
        let runtimes = TorTestRuntimes()
        var native = TorHTTPGetNative(isolateRuntime: { runtimes.clone($0) }, freeRuntime: { runtimes.free($0) })
        native.postOnce = { _, _, _, _, body, count, maxBytes, timeout, outcome in
            XCTAssertEqual(Data(bytes: body!, count: Int(count)), Data([4, 2]))
            XCTAssertEqual(maxBytes, 123)
            XCTAssertGreaterThan(timeout, 0)
            XCTAssertLessThanOrEqual(timeout, 100)
            Thread.sleep(forTimeInterval: 0.03)
            outcome?.pointee = FfiTorHttpOutcome(kind: 1, http_status: 403, retry_not_before_ns: 0)
            return nil
        }
        let client = TorClient(runtimePtr: runtimes.parent, torDir: FileManager.default.temporaryDirectory, httpGetNative: native)
        var request = URLRequest(url: URL(string: "https://relay.test/relay")!)
        request.httpMethod = "POST"
        request.httpBody = Data([4, 2])
        do {
            _ = try await client.httpRequestSentOnce(for: request, maxBytes: 123, timeoutMilliseconds: 10)
            XCTFail("Native failure must remain a failure")
        } catch {
            XCTAssertEqual(OHTTPHealthTraffic.outcome(error), .policyRejected)
        }
        try await client.close()
    }


    func testProbeDeadlineCannotEraseNativeRejectionDuringCleanup() async throws {
        let runtimes = TorTestRuntimes()
        var native = TorHTTPGetNative(isolateRuntime: { runtimes.clone($0) }, freeRuntime: { runtimes.free($0) })
        native.postOnce = { _, _, _, _, _, _, _, _, outcome in
            Thread.sleep(forTimeInterval: 0.03)
            outcome?.pointee = FfiTorHttpOutcome(kind: 1, http_status: 403, retry_not_before_ns: 0)
            return nil
        }
        let client = TorClient(runtimePtr: runtimes.parent, torDir: FileManager.default.temporaryDirectory, httpGetNative: native)
        let session = try OHTTPHealthSession(route: OHTTPHealthRoute(network: .testnet, gatewayHost: "probe.test", relayURL: "https://relay.test/", viaTor: true), generation: UUID())
        defer { session.close() }
        var request = URLRequest(url: URL(string: "https://relay.test/relay")!)
        request.httpMethod = "POST"
        let post = request
        let result = await OHTTPHealthProbe.run(session: session, timeoutMilliseconds: 10) { budget in
            try budget.admit()
            _ = try await client.httpRequestSentOnce(for: post, maxBytes: 123, timeoutMilliseconds: budget.remainingMilliseconds())
            return .usable
        }
        XCTAssertEqual(result.outcome, .policyRejected)
        try await client.close()
    }

    func testBufferedKeyRateLimitUsesNativeHeadDeadlineAfterBodyAndCleanup() async throws {
        let runtimes = TorTestRuntimes()
        let response = TorResponseFixture()
        response.pointer.pointee.status = 429
        var native = TorHTTPGetNative(isolateRuntime: { runtimes.clone($0) }, freeRuntime: { runtimes.free($0) })
        native.classifiedGet = { _, _, _, _, _, _, _, outcome in
            Thread.sleep(forTimeInterval: 0.02)
            outcome?.pointee = FfiTorHttpOutcome(kind: 0, http_status: 429, retry_not_before_ns: 123)
            return response.pointer
        }
        native.freeResponse = { _ in response.free() }
        let client = TorClient(runtimePtr: runtimes.parent, torDir: FileManager.default.temporaryDirectory, httpGetNative: native)
        let route = OHTTPHealthRoute(network: .testnet, gatewayHost: OHTTPTestSupport.testnetHost, relayURL: "https://buffered-pause.test/relay", viaTor: true)
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
            viaTor: true, keyCache: OHTTPKeyCache(), httpSender: { request, maxBytes in
                try await client.httpRequestSentOnce(for: request, maxBytes: maxBytes, timeoutMilliseconds: 2000)
            }
        )
        let result = await OHTTPHealthProbe.run(session: session) { _ in
            _ = try await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 2000)
            return .usable
        }
        XCTAssertEqual(result.outcome, .rateLimited(retryNotBefore: 123))
        try await client.close()
    }

    func testExpiredPostNeverIsolatesOrDispatches() async throws {
        let client = TorClient(torDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var request = URLRequest(url: URL(string: "https://relay.test/relay")!)
        request.httpMethod = "POST"
        do {
            _ = try await client.httpRequestSentOnce(for: request, maxBytes: 123, timeoutMilliseconds: 0)
            XCTFail("Expired request must not prepare Tor")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }
    func testPostDeadlineIncludesBusyActorAdmission() async throws {
        let entered = expectation(description: "Tor actor held")
        let returned = expectation(description: "deadline returns before actor opens")
        let release = DispatchSemaphore(value: 0)
        let client = TorClient(torDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let blocker = Task { await client.holdForProbeTest(entered: entered, release: release) }
        await fulfillment(of: [entered], timeout: 2)
        var request = URLRequest(url: URL(string: "https://relay.test/relay")!)
        request.httpMethod = "POST"
        let task = Task {
            do {
                _ = try await client.httpRequestSentOnce(for: request, maxBytes: 100, timeoutMilliseconds: 10)
                XCTFail("Expired actor admission must not dispatch")
            } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 1)
        release.signal()
        await blocker.value
        await task.value
    }

}


private extension TorClient {
    func holdForProbeTest(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
    }
}
