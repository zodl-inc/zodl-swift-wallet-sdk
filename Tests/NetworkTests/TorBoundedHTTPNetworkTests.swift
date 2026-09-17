import Foundation
import XCTest
import libzcashlc

@testable import TestUtils
@testable import ZcashLightClientKit

/// Select independently from TorClientTests.testApis, which submits a transaction.
/// TOR_HTTP_TEST_BASE_URL must provide HTTPBin-compatible /get, /post and /delay/3.
/// All requests contain synthetic data. A process watchdog reports hung native calls;
/// it never attempts to free a handle that is still inside native code.
final class TorBoundedHTTPNetworkTests: XCTestCase {
    private static let bootstrapFailure = TorNetworkPrerequisite()

    // Break caught: bounded GET stops copying the native response or legacy POST loses its body.
    func testBoundedSuccessAndLegacyGETAndPOSTRetryThree() async throws {
        try await withFixture { fixture in
            let request = fixture.request("get")
            let bounded = try await fixture.client.httpGet(for: request, retryLimit: 0, timeoutMilliseconds: 30_000)
            try self.assertGet(bounded)
            let legacy = try await fixture.client.httpRequest(for: request, retryLimit: 3)
            try self.assertGet(legacy)
            var post = fixture.request("post")
            post.httpMethod = "POST"
            post.httpBody = Data("bounded-tor-compatibility".utf8)
            let result = try await fixture.client.httpRequest(for: post, retryLimit: 3)
            XCTAssertEqual(result.response.statusCode, 200)
            XCTAssertEqual(try JSONDecoder().decode(HTTPBinPost.self, from: result.data).data, "bounded-tor-compatibility")
            print("TOR EVIDENCE: bounded GET and legacy GET/POST retryLimit=3 decoded successfully")
        }
    }

    // Break caught: timeout removed/extended, or cleanup leaves the shared runtime unusable.
    func testThreePositiveTimeoutAndRecoveryCycles() async throws {
        try await withFixture { fixture in
            for cycle in 1...3 {
                fixture.observer.reset()
                let start = DispatchTime.now().uptimeNanoseconds
                do {
                    _ = try await fixture.client.httpGet(
                        for: fixture.request("delay/3"), retryLimit: 0, timeoutMilliseconds: 750
                    )
                    XCTFail("A /delay/3 response must not complete inside the positive 750ms budget")
                } catch {
                    self.assertTimeout(error)
                }
                let elapsed = Self.elapsed(start)
                XCTAssertLessThan(elapsed, 15, "Generous test guard includes request-owned runtime disposal")
                let events = fixture.observer.events
                XCTAssertTrue(events.contains("native-enter"), "Must reach the real FFI boundary")
                XCTAssertTrue(events.contains("native-return-error"), "Native positive timeout must report an error")
                XCTAssertEqual(events.filter { $0 == "clone-free-end" }.count, 1)
                try self.assertGet(try await fixture.client.httpGet(
                    for: fixture.request("get"), retryLimit: 0, timeoutMilliseconds: 30_000
                ))
                print("TOR EVIDENCE: timeout/recovery cycle \(cycle)/3, including disposal: \(elapsed)s")
            }
        }
    }

    // Break caught: parent close invalidates the request-owned clone, or completion precedes cleanup.
    func testFinalOwnerCompletesAfterParentCloseAndDisposesExactlyOnce() async throws {
        try await withFixture { fixture in
            // Exercise the public isolation path, then remove that extra owner before the request.
            let isolated = try await fixture.client.isolatedClient()
            try await isolated.close()
            fixture.observer.reset()
            let entered = self.expectation(description: "real request-owned clone entered")
            fixture.observer.arm(entered)
            let start = DispatchTime.now().uptimeNanoseconds
            let request = Task {
                try await fixture.client.httpGet(for: fixture.request("get"), retryLimit: 0, timeoutMilliseconds: 30_000)
            }
            await self.fulfillment(of: [entered], timeout: 5)
            try await fixture.client.close()
            fixture.observer.release()
            try self.assertGet(try await request.value)
            fixture.observer.record("caller-completed")
            let events = fixture.observer.events
            XCTAssertEqual(events.filter { $0 == "parent-free-end" }.count, 1)
            XCTAssertEqual(events.filter { $0 == "clone-free-end" }.count, 1)
            XCTAssertEqual(events.filter { $0 == "response-free" }.count, 1)
            self.assertOrdered("native-enter", "parent-free-end", in: events)
            self.assertOrdered("parent-free-end", "native-return-response", in: events)
            self.assertOrdered("response-free", "clone-free-end", in: events)
            self.assertOrdered("clone-free-end", "caller-completed", in: events)
            print("TOR EVIDENCE: last request owner completed/disposed in \(Self.elapsed(start))s; \(events)")
        }
    }

    // Break caught: cancellation returns while the real native request still owns its clone.
    func testEnteredCancellationWaitsForRealNativeCleanup() async throws {
        try await withFixture { fixture in
            fixture.observer.reset()
            let entered = self.expectation(description: "request entered real native wrapper before cancellation")
            fixture.observer.arm(entered)
            let start = DispatchTime.now().uptimeNanoseconds
            let request = Task {
                try await fixture.client.httpGet(for: fixture.request("delay/3"), retryLimit: 0, timeoutMilliseconds: 1_000)
            }
            await self.fulfillment(of: [entered], timeout: 5)
            request.cancel()
            fixture.observer.release()
            do {
                _ = try await request.value
                XCTFail("Entered cancellation must throw after native cleanup")
            } catch {
                XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error.localizedDescription)")
            }
            fixture.observer.record("caller-completed")
            let events = fixture.observer.events
            XCTAssertTrue(events.contains("native-return-error"), "The wrapper must actually call bounded native GET")
            XCTAssertEqual(events.filter { $0 == "clone-free-end" }.count, 1)
            self.assertOrdered("native-return-error", "clone-free-end", in: events)
            self.assertOrdered("clone-free-end", "caller-completed", in: events)
            XCTAssertLessThan(Self.elapsed(start), 15)
            print("TOR EVIDENCE: entered cancellation and disposal \(Self.elapsed(start))s; \(events)")
        }
    }

    // Break caught: isolated HTTP disrupts an existing shared-runtime gRPC consumer.
    func testReadOnlyLightwalletdCoexistsWithBoundedHTTP() async throws {
        try await withFixture { fixture in
            let connection: TorLwdConn
            do {
                connection = try await fixture.client.connectToLightwalletd(endpoint: LightWalletEndpointBuilder.publicTestnet.urlString)
            } catch {
                throw XCTSkip("lightwalletd connection prerequisite failed separately from HTTP warmup: \(error.localizedDescription)")
            }
            fixture.observer.reset()
            let entered = self.expectation(description: "HTTP entered before read-only gRPC")
            fixture.observer.arm(entered)
            let http = Task {
                try await fixture.client.httpGet(for: fixture.request("get"), retryLimit: 0, timeoutMilliseconds: 30_000)
            }
            await self.fulfillment(of: [entered], timeout: 5)
            fixture.observer.release()
            // This known mined transaction is read only. Never call submit here.
            let txID = "9e309d29a99f06e6dcc7aee91dca23c0efc2cf5083cc483463ddbee19c1fadf1".toTxIdString().hexadecimal!
            let readResult = Result { try connection.fetchTransaction(txId: txID) }
            try self.assertGet(try await http.value)
            // A service failure after connection is a failed read assertion, not HTTP success evidence.
            let transaction = try readResult.get()
            XCTAssertEqual(transaction.status, .mined(1_234_567))
            XCTAssertFalse(try XCTUnwrap(transaction.tx).raw.isEmpty)
            print("TOR EVIDENCE: decoded known mined transaction concurrently with bounded HTTP")
        }
    }

    private func withFixture(_ operation: (TorNetworkFixture) async throws -> Void) async throws {
        if let reason = Self.bootstrapFailure.reason { throw XCTSkip(reason) }
        let watchdog = TorNetworkWatchdog(seconds: 330)
        defer { watchdog.cancel() }
        let fixture = TorNetworkFixture()
        // prepare() itself bootstraps synchronously. HTTP budgets do not cover construction.
        let gate = TorBootstrapGate()
        do {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                Task.detached {
                    do {
                        try await fixture.client.prepare()
                        if !gate.finish(.success(())) { await fixture.close() }
                    } catch {
                        await fixture.close()
                        _ = gate.finish(.failure(TorBootstrapError(reason: "Tor bootstrap prerequisite failed: \(error.localizedDescription)")))
                    }
                }
                Task.detached {
                    try? await Task.sleep(nanoseconds: 150_000_000_000)
                    let reason = "Tor bootstrap exceeded 150s; in-flight constructor retains resources until return"
                    _ = gate.finish(.failure(TorBootstrapError(reason: reason)))
                }
            }
        } catch {
            Self.bootstrapFailure.set(error.localizedDescription)
            throw XCTSkip(error.localizedDescription)
        }
        do {
            do {
                let warm = try await fixture.client.httpGet(for: fixture.request("get"), retryLimit: 0, timeoutMilliseconds: 30_000)
                guard warm.response.statusCode == 200 else {
                    throw XCTSkip("HTTP fixture warmup returned status \(warm.response.statusCode)")
                }
                _ = try JSONDecoder().decode(HTTPBinGet.self, from: warm.data)
            } catch let skip as XCTSkip {
                throw skip
            } catch {
                throw XCTSkip("HTTP fixture warmup prerequisite failed: \(error.localizedDescription)")
            }
            print("TOR STAGE: bootstrap and HTTPBin warmup reached")
            try await operation(fixture)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private func assertGet(_ result: (data: Data, response: HTTPURLResponse)) throws {
        XCTAssertEqual(result.response.statusCode, 200)
        let decoded = try JSONDecoder().decode(HTTPBinGet.self, from: result.data)
        XCTAssertEqual(decoded.headers["X-Test-Header"], "bounded-tor-synthetic")
        XCTAssertEqual(decoded.args, [:])
    }

    private func assertTimeout(_ error: Error) {
        if let urlError = error as? URLError {
            XCTAssertEqual(urlError.code, .timedOut)
        } else if case ZcashError.rustTorHttpRequest(let message) = error {
            // Production reads the thread-local native error; the observer must not consume it.
            XCTAssertTrue(message.lowercased().contains("timed out"), "Expected native timeout, got \(message)")
        } else {
            XCTFail("Expected timeout, got \(error.localizedDescription)")
        }
    }

    private func assertOrdered(_ first: String, _ second: String, in events: [String]) {
        guard let firstIndex = events.firstIndex(of: first), let secondIndex = events.firstIndex(of: second) else {
            XCTFail("Missing lifecycle events \(first), \(second): \(events)")
            return
        }
        XCTAssertLessThan(firstIndex, secondIndex)
    }

    private static func elapsed(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }
}

private final class TorNetworkFixture: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-tor-\(UUID().uuidString)")
    let observer = TorNativeObserver()
    let base = URL(string: ProcessInfo.processInfo.environment["TOR_HTTP_TEST_BASE_URL"] ?? "https://httpbin.org")!
    lazy var client = TorClient(torDir: directory, httpGetNative: observer.native)

    func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.setValue("bounded-tor-synthetic", forHTTPHeaderField: "X-Test-Header")
        return request
    }

    func close() async {
        try? await client.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// NSLock supports the SDK's macOS 12 / iOS 13 deployment floors.
/// Only records real native outcomes. In particular, get never calls lastErrorMessage.
private final class TorNativeObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var parent: OpaquePointer?
    private var entered: XCTestExpectation?
    private let proceed = DispatchSemaphore(value: 0)

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ event: String) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    func arm(_ expectation: XCTestExpectation) {
        lock.lock()
        entered = expectation
        lock.unlock()
    }

    func release() { proceed.signal() }

    var native: TorHTTPGetNative {
        TorHTTPGetNative(
            get: { [self] runtime, url, headers, count, retries, timeout in
                record("native-enter")
                lock.lock()
                let expectation = entered
                entered = nil
                lock.unlock()
                if let expectation {
                    expectation.fulfill()
                    guard proceed.wait(timeout: .now() + 10) == .success else {
                        fatalError("TOR RUN GUARD: test did not release entered native wrapper")
                    }
                }
                let response = zcashlc_tor_http_get_with_timeout(runtime, url, headers, count, retries, timeout)
                record(response == nil ? "native-return-error" : "native-return-response")
                return response
            },
            freeResponse: { [self] pointer in
                zcashlc_free_http_response_bytes(pointer)
                record("response-free")
            },
            isolateRuntime: { zcashlc_tor_isolated_client($0) },
            freeRuntime: { [self] pointer in
                lock.lock()
                let isParent = pointer == parent
                lock.unlock()
                record(isParent ? "parent-free-start" : "clone-free-start")
                zcashlc_free_tor_runtime(pointer)
                record(isParent ? "parent-free-end" : "clone-free-end")
            },
            createRuntime: { [self] path, length in
                let runtime = zcashlc_create_tor_runtime(path, length)
                lock.lock()
                parent = runtime
                lock.unlock()
                return runtime
            }
        )
    }
}

private final class TorBootstrapGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }
    func finish(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}

private final class TorNetworkPrerequisite: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String?
    var reason: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
    func set(_ reason: String) {
        lock.lock()
        failure = reason
        lock.unlock()
    }
}

private final class TorNetworkWatchdog {
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    init(seconds: Int) {
        timer.schedule(deadline: .now() + .seconds(seconds))
        timer.setEventHandler {
            fputs("TOR RUN GUARD EXPIRED: native operation/cleanup did not finish; run is incomplete, not passing.\n", stderr)
            fflush(stderr)
            _exit(124)
        }
        timer.resume()
    }
    func cancel() { timer.cancel() }
}

private struct TorBootstrapError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}
