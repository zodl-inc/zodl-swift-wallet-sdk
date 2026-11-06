import Foundation
import libzcashlc
import XCTest
import os
@testable import ZODLSwiftWalletSDK

final class OHTTPHealthTorTests: XCTestCase {
    func testSuccessfulKeyFetchDoesNotAuthorizeQueuedPostExpiry() async throws {
        try await assertPostTimeoutAfterSuccessfulKeys(queued: true)
    }

    func testSuccessfulKeyFetchPreservesDispatchedPostTimeout() async throws {
        try await assertPostTimeoutAfterSuccessfulKeys(queued: false)
    }

    private func assertPostTimeoutAfterSuccessfulKeys(queued: Bool) async throws {
        let clock = TorTestClock()
        clock.advance(to: DispatchTime.now().uptimeNanoseconds)
        let executor = TorHTTPRequestExecutor(now: { clock.now }, sleepUntil: { try await clock.sleepUntil($0) })
        let first = TorWorkerGate()
        let second = TorWorkerGate()
        defer {
            first.release()
            second.release()
        }
        let runtimes = TorTestRuntimes()
        let fixture = TorResponseFixture()
        fixture.pointer.pointee.status = 200
        let calls = OSAllocatedUnfairLock(initialState: [0, 0, 0])
        var native = TorHTTPGetNative(isolateRuntime: { runtimes.clone($0) }, freeRuntime: {
            calls.withLock { $0[2] += 1 }
            runtimes.free($0)
        })
        native.classifiedGet = { _, _, _, _, _, _, _, outcome in
            calls.withLock { $0[0] += 1 }
            outcome?.pointee = FfiTorHttpOutcome(kind: 0, http_status: 200, retry_not_before_ns: 0)
            return fixture.pointer
        }
        native.freeResponse = { _ in fixture.free() }
        native.postOnce = { _, _, _, _, _, _, _, _, outcome in
            calls.withLock { $0[1] += 1 }
            outcome?.pointee = FfiTorHttpOutcome(kind: 2, http_status: 0, retry_not_before_ns: 0)
            return nil
        }
        let client = TorClient(runtimePtr: runtimes.parent, torDir: FileManager.default.temporaryDirectory, httpGetNative: native, httpExecutor: executor)
        let route = OHTTPHealthRoute(network: .testnet, gatewayHost: OHTTPTestSupport.testnetHost, relayURL: "https://\(UUID().uuidString).test/relay", viaTor: true)
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let downloads = OSAllocatedUnfairLock(initialState: [Task<TorHTTPRequestExecutor.Response, Error>]())
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
            testKeyVerifier: OHTTPTestSupport.makeKeyVerifier(), viaTor: true, keyCache: OHTTPKeyCache(),
            httpSender: { request, maxBytes in
                if queued && request.httpMethod == "POST" {
                    let tasks = [first, second].map { gate in
                        Task { try await executor.execute(deadlineUptime: UInt64.max, operation: { try gate.run($0) }) }
                    }
                    downloads.withLock { $0 = tasks }
                    await self.fulfillment(of: [first.entered, second.entered], timeout: 3)
                }
                return try await client.httpRequestSentOnce(for: request, maxBytes: maxBytes, timeoutMilliseconds: 60_000)
            }
        )
        let probe = Task {
            await OHTTPHealthProbe.run(session: session, timeoutMilliseconds: 60_000) { budget in
                try budget.admit()
                _ = try await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 60_000)
                return .usable
            }
        }
        if queued {
            await clock.waitForSleepers(1)
            clock.advance(to: UInt64.max)
        }
        let result = await probe.value
        XCTAssertEqual(result.outcome, queued ? .inconclusive : .transportUnavailable)
        XCTAssertEqual(calls.withLock { Array($0.prefix(2)) }, queued ? [1, 0] : [1, 1])
        XCTAssertEqual(session.snapshot().observations.contains { $0.purpose == .diagnostic && $0.outcome == .transportUnavailable }, !queued)
        first.release()
        second.release()
        for task in downloads.withLock({ $0 }) { _ = try await task.value }
        try await client.close()
        XCTAssertEqual(calls.withLock { $0[2] }, 3, "Key, queued POST and parent each dispose once")
    }

    func testSuccessfulKeyFetchDoesNotAuthorizeLocalPostKeyExpiry() async throws {
        let clock = TorTestClock()
        let budget = OHTTPHealthProbeBudget(milliseconds: 60_000, nativeDeadline: true, now: { clock.now })
        let runtimes = TorTestRuntimes()
        let fixture = TorResponseFixture()
        fixture.pointer.pointee.status = 200
        let calls = OSAllocatedUnfairLock(initialState: [0, 0])
        var native = TorHTTPGetNative(isolateRuntime: { runtimes.clone($0) }, freeRuntime: { runtimes.free($0) })
        native.classifiedGet = { _, _, _, _, _, _, _, outcome in
            calls.withLock { $0[0] += 1 }
            outcome?.pointee = FfiTorHttpOutcome(kind: 0, http_status: 200, retry_not_before_ns: 0)
            return fixture.pointer
        }
        native.freeResponse = { _ in fixture.free() }
        native.postOnce = { _, _, _, _, _, _, _, _, _ in
            calls.withLock { $0[1] += 1 }
            return nil
        }
        let client = TorClient(runtimePtr: runtimes.parent, torDir: FileManager.default.temporaryDirectory, httpGetNative: native)
        let route = OHTTPHealthRoute(network: .testnet, gatewayHost: OHTTPTestSupport.testnetHost, relayURL: "https://\(UUID().uuidString).test/relay", viaTor: true)
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let verifier = OHTTPTestSupport.makeKeyVerifier()
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost, relayURL: route.relayURL, walletNetwork: .testnet,
            testKeyVerifier: { data, date in
                let key = try verifier(data, date)
                clock.advance(to: budget.deadline)
                return key
            }, viaTor: true, keyCache: OHTTPKeyCache(),
            httpSender: { request, maxBytes in
                try await client.httpRequestSentOnce(for: request, maxBytes: maxBytes, timeoutMilliseconds: 60_000)
            }
        )
        let outcome = await OHTTPHealthProbe.$recipient.withValue(session.diagnosticRecipient) {
            await budget.run {
                try budget.admit()
                return try await OHTTPHealthProbe.$budget.withValue(budget) {
                    _ = try await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 60_000)
                    return .usable
                }
            }
        }
        XCTAssertEqual(outcome, .inconclusive)
        XCTAssertEqual(calls.withLock { $0 }, [1, 0])
        XCTAssertFalse(session.snapshot().observations.contains { $0.purpose == .diagnostic && $0.outcome == .transportUnavailable })
        try await client.close()
    }

    func testPreparationExpiryBeforeNativeEntryIsInconclusive() async throws {
        let entered = expectation(description: "Final request preparation held")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let runtimes = TorTestRuntimes()
        let calls = OSAllocatedUnfairLock(initialState: [0, 0])
        var native = TorHTTPGetNative(isolateRuntime: { runtimes.clone($0) }, freeRuntime: {
            calls.withLock { $0[1] += 1 }
            runtimes.free($0)
        })
        native.now = {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            return UInt64.max
        }
        native.classifiedGet = { _, _, _, _, _, _, _, _ in
            calls.withLock { $0[0] += 1 }
            return nil
        }
        let client = TorClient(runtimePtr: runtimes.parent, torDir: FileManager.default.temporaryDirectory, httpGetNative: native)
        let route = OHTTPHealthRoute(network: .testnet, gatewayHost: OHTTPTestSupport.testnetHost, relayURL: "https://\(UUID().uuidString).test/relay", viaTor: true)
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let probe = Task {
            await OHTTPHealthProbe.run(session: session, timeoutMilliseconds: 60_000) { budget in
                try budget.admit()
                let health = OHTTPHealthTraffic(route: route, request: OHTTPTestSupport.simpleRequest)
                return try await OHTTPHealthTraffic.$current.withValue(health) {
                    do {
                        _ = try await client.httpRequestSentOnce(for: URLRequest(url: URL(string: route.relayURL)!), maxBytes: 100, timeoutMilliseconds: 60_000)
                        return .usable
                    } catch {
                        health.failed(error)
                        throw error
                    }
                }
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        release.signal()
        let result = await probe.value
        XCTAssertEqual(result.outcome, .inconclusive)
        XCTAssertEqual(calls.withLock { $0[0] }, 0)
        XCTAssertFalse(session.snapshot().observations.contains { $0.purpose == .diagnostic && $0.outcome == .transportUnavailable })
        try await client.close()
        XCTAssertEqual(calls.withLock { $0[1] }, 2, "Prepared child and parent each dispose once")
    }

    func testDoH403DoesNotReplaceRelayFailure() async throws {
        try await assertDNSFailureIsAuxiliary(status: 403)
    }

    func testDoH429DoesNotPauseRelay() async throws {
        try await assertDNSFailureIsAuxiliary(status: 429)
    }

    private func assertDNSFailureIsAuxiliary(status: UInt16) async throws {
        let runtimes = TorTestRuntimes()
        let nativeCalls = OSAllocatedUnfairLock(initialState: 0)
        let pause = OHTTPHealthClock.nowNanoseconds + 120_000_000_000
        var native = TorHTTPGetNative(isolateRuntime: { runtimes.clone($0) }, freeRuntime: { runtimes.free($0) })
        native.classifiedGet = { _, _, _, _, _, _, _, outcome in
            nativeCalls.withLock { $0 += 1 }
            outcome?.pointee = FfiTorHttpOutcome(kind: 1, http_status: status, retry_not_before_ns: pause)
            return nil
        }
        let client = TorClient(runtimePtr: runtimes.parent, torDir: FileManager.default.temporaryDirectory, httpGetNative: native)
        let route = OHTTPHealthRoute(
            network: .testnet,
            gatewayHost: OHTTPTestSupport.testnetHost,
            relayURL: "https://\(UUID().uuidString.lowercased()).test/relay",
            viaTor: true
        )
        let session = try OHTTPHealthSession(route: route, generation: UUID())
        defer { session.close() }
        let transport = OHTTPTransport(
            gatewayHost: route.gatewayHost,
            relayURL: route.relayURL,
            walletNetwork: .testnet,
            viaTor: true,
            keyCache: OHTTPKeyCache(),
            httpSender: { request, maxBytes in
                if request.url?.host == URL(string: route.relayURL)?.host {
                    try OHTTPHealthProbe.budget?.beginNetworkAttempt()
                    throw URLError(.cannotConnectToHost)
                }
                return try await client.httpRequestSentOnce(for: request, maxBytes: maxBytes, timeoutMilliseconds: 2000)
            }
        )
        let result = await OHTTPHealthProbe.run(session: session) { budget in
            try budget.admit()
            do {
                _ = try await transport.roundTrip(request: OHTTPTestSupport.simpleRequest, timeoutMS: 2000)
                XCTFail("The original relay error must remain")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
                throw error
            }
            return .usable
        }
        XCTAssertEqual(result.outcome, .transportUnavailable)
        XCTAssertEqual(nativeCalls.withLock { $0 }, 2)
        XCTAssertFalse(session.snapshot().observations.contains { $0.outcome == .policyRejected })
        XCTAssertFalse(session.snapshot().observations.contains {
            if case .rateLimited = $0.outcome { return true }
            return false
        })
        try await client.close()
    }

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
        XCTAssertTrue(session.snapshot().observations.contains {
            $0.scope == .route && $0.outcome == .rateLimited(retryNotBefore: 123)
        })
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
