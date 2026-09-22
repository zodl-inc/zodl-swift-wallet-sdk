import Foundation
import libzcashlc
import XCTest
@testable import ZcashLightClientKit

final class TorHTTPGetTests: XCTestCase {
    func testInvalidRequestsAndZeroTimeoutDoNotCreateRuntime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = TorClient(torDir: directory)
        var missingURL = URLRequest(url: URL(string: "https://example.com")!)
        missingURL.url = nil
        var post = URLRequest(url: URL(string: "https://example.com")!)
        post.httpMethod = "POST"
        let invalidScheme = URLRequest(url: URL(string: "file:///tmp/example")!)
        for request in [missingURL, post, invalidScheme] {
            do {
                _ = try await client.httpGet(for: request, retryLimit: 0, timeoutMilliseconds: 100)
                XCTFail("Invalid GET accepted")
            } catch {
                XCTAssertTrue(error is ZcashError)
            }
        }
        do {
            _ = try await client.httpGet(for: URLRequest(url: URL(string: "https://example.com")!), retryLimit: 0, timeoutMilliseconds: 0)
            XCTFail("Zero timeout accepted")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testUnpreparedRuntimeFailsWithoutBootstrapping() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let directory = file.appendingPathComponent("must-not-bootstrap")
        let client = TorClient(torDir: directory)
        do {
            _ = try await client.httpGet(for: URLRequest(url: URL(string: "https://example.com")!), retryLimit: 0, timeoutMilliseconds: 100)
            XCTFail("Unprepared runtime accepted")
        } catch {
            guard case ZcashError.torClientUnavailable = error else { return XCTFail("Expected unavailable runtime") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCopiesResponseBeforeFreeingAndForwardsNativeArgumentsOnWorker() async throws {
        let queue = DispatchQueue(label: "test.tor.native", attributes: .concurrent)
        let key = DispatchSpecificKey<String>()
        queue.setSpecific(key: key, value: "native")
        let fixture = TorResponseFixture()
        let freed = expectation(description: "native response freed")
        let runtimeFreed = expectation(description: "runtime freed")
        let runtimes = TorTestRuntimes()
        let native = TorHTTPGetNative(
            get: { _, url, headers, count, retry, timeout in
                XCTAssertEqual(DispatchQueue.getSpecific(key: key), "native")
                XCTAssertEqual(String(cString: url!), "https://example.com/test")
                XCTAssertEqual(count, 1)
                XCTAssertEqual(String(cString: headers!.pointee.name), "X-Test")
                XCTAssertEqual(String(cString: headers!.pointee.value), "request")
                XCTAssertEqual(retry, 2)
                XCTAssertGreaterThan(timeout, 0)
                XCTAssertLessThanOrEqual(timeout, 10_000)
                return fixture.pointer
            },
            freeResponse: { pointer in
                XCTAssertEqual(DispatchQueue.getSpecific(key: key), "native")
                XCTAssertEqual(pointer, fixture.pointer)
                fixture.free()
                freed.fulfill()
            },
            isolateRuntime: { runtimes.clone($0) },
            freeRuntime: { runtime in
                if runtime != runtimes.parent {
                    XCTAssertEqual(DispatchQueue.getSpecific(key: key), "native")
                    runtimeFreed.fulfill()
                }
                runtimes.free(runtime)
            }
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = TorClient(runtimePtr: runtimes.parent, torDir: directory, httpGetNative: native, httpExecutor: TorHTTPRequestExecutor(workerQueue: queue))
        var request = URLRequest(url: URL(string: "https://example.com/test")!)
        request.setValue("request", forHTTPHeaderField: "X-Test")
        let result = try await client.httpGet(for: request, retryLimit: 2, timeoutMilliseconds: 10_000)
        await fulfillment(of: [freed, runtimeFreed], timeout: 3)
        XCTAssertEqual(result.data, Data([3, 1, 4]))
        XCTAssertEqual(result.response.statusCode, 201)
        XCTAssertEqual(result.response.value(forHTTPHeaderField: "X-Test"), "one, two")
        try await client.close()
    }

    func testNativeFailureReadsThreadLocalErrorBeforeWorkerExit() async throws {
        let runtimes = TorTestRuntimes()
        let native = TorHTTPGetNative(get: { runtime, url, headers, count, retry, _ in
            // The real FFI writes LAST_ERROR on this thread and rejects before any network I/O.
            zcashlc_tor_http_get_with_timeout(nil, url, headers, count, retry, 0)
        }, isolateRuntime: { runtimes.clone($0) }, freeRuntime: { runtimes.free($0) })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = TorClient(runtimePtr: runtimes.parent, torDir: directory, httpGetNative: native)
        do {
            _ = try await client.httpGet(for: URLRequest(url: URL(string: "https://example.com")!), retryLimit: 0, timeoutMilliseconds: 10_000)
            XCTFail("Native failure succeeded")
        } catch ZcashError.rustTorHttpRequest(let message) {
            XCTAssertTrue(message.contains("Tor HTTP timeout must be positive"))
        }
        try await client.close()
    }

    func testParentCloseDoesNotInvalidateOwnedActiveRuntime() async throws {
        let entered = expectation(description: "cloned runtime entered")
        let release = DispatchSemaphore(value: 0)
        let freed = expectation(description: "request runtime freed once")
        let runtimes = TorTestRuntimes()
        let native = TorHTTPGetNative(
            get: { runtime, url, headers, count, retry, _ in
                entered.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { return nil }
                XCTAssertFalse(runtimes.isAlive(runtimes.parent))
                XCTAssertTrue(runtimes.isAlive(runtime))
                return zcashlc_tor_http_get_with_timeout(nil, url, headers, count, retry, 0)
            },
            isolateRuntime: { runtimes.clone($0) },
            freeRuntime: { runtime in
                runtimes.free(runtime)
                if runtime != runtimes.parent { freed.fulfill() }
            }
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = TorClient(runtimePtr: runtimes.parent, torDir: directory, httpGetNative: native)
        let task = Task {
            try await client.httpGet(for: URLRequest(url: URL(string: "https://example.com")!), retryLimit: 0, timeoutMilliseconds: 10_000)
        }
        await fulfillment(of: [entered], timeout: 3)
        try await client.close()
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("Cancelled native call succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [freed], timeout: 3)
    }
    func testQueuedCancellationReleasesOwnedRuntimeOnceWithoutCallingNativeGET() async throws {
        let clock = TorTestClock()
        let executor = TorHTTPRequestExecutor(sleepUntil: { try await clock.sleepUntil($0) })
        let first = TorWorkerGate()
        let second = TorWorkerGate()
        let firstTask = Task { try await executor.execute(deadlineUptime: UInt64.max, operation: { try first.run($0) }) }
        let secondTask = Task { try await executor.execute(deadlineUptime: UInt64.max, operation: { try second.run($0) }) }
        await fulfillment(of: [first.entered, second.entered], timeout: 3)
        let freed = expectation(description: "queued owner freed once")
        let runtimes = TorTestRuntimes()
        let native = TorHTTPGetNative(
            get: { _, _, _, _, _, _ in
                XCTFail("Cancelled queued GET entered native code")
                return nil
            },
            isolateRuntime: { runtimes.clone($0) },
            freeRuntime: { pointer in
                runtimes.free(pointer)
                if pointer != runtimes.parent { freed.fulfill() }
            }
        )
        let client = TorClient(runtimePtr: runtimes.parent, torDir: FileManager.default.temporaryDirectory, httpGetNative: native, httpExecutor: executor)
        let task = Task {
            try await client.httpGet(for: URLRequest(url: URL(string: "https://example.com")!), retryLimit: 0, timeoutMilliseconds: 10_000)
        }
        await clock.waitForSleepers(1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled queued request succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [freed], timeout: 3)
        XCTAssertTrue(runtimes.isAlive(runtimes.parent))
        first.release()
        second.release()
        _ = try await firstTask.value
        _ = try await secondTask.value
        try await client.close()
    }

    func testInvalidNativeResponseStillFreesResponseAndOwnedRuntime() async throws {
        let fixture = TorResponseFixture(invalidHeader: true)
        let runtimes = TorTestRuntimes()
        let freedResponse = expectation(description: "invalid response freed")
        let freedRuntime = expectation(description: "failed request owner freed")
        let native = TorHTTPGetNative(
            get: { _, _, _, _, _, _ in fixture.pointer },
            freeResponse: { _ in
                fixture.free()
                freedResponse.fulfill()
            },
            isolateRuntime: { runtimes.clone($0) },
            freeRuntime: { pointer in
                runtimes.free(pointer)
                if pointer != runtimes.parent { freedRuntime.fulfill() }
            }
        )
        let client = TorClient(runtimePtr: runtimes.parent, torDir: FileManager.default.temporaryDirectory, httpGetNative: native)
        do {
            _ = try await client.httpGet(for: URLRequest(url: URL(string: "https://example.com")!), retryLimit: 0, timeoutMilliseconds: 10_000)
            XCTFail("Malformed response accepted")
        } catch {
            guard case ZcashError.rustTorHttpRequest = error else { return XCTFail("Expected malformed HTTP response") }
        }
        await fulfillment(of: [freedResponse, freedRuntime], timeout: 3)
        try await client.close()
    }

}

final class TorResponseFixture: @unchecked Sendable {
    let pointer = UnsafeMutablePointer<FfiHttpResponseBytes>.allocate(capacity: 1)
    private let headers = UnsafeMutablePointer<FfiHttpResponseHeader>.allocate(capacity: 2)
    private let body = UnsafeMutablePointer<UInt8>.allocate(capacity: 3)
    private let version = strdup("HTTP/1.1")!
    private let name1 = strdup("X-Test")!
    private let name2 = strdup("X-Test")!
    private let value1 = strdup("one")!
    private let value2 = strdup("two")!

    init(invalidHeader: Bool = false) {
        if invalidHeader { value1.pointee = -1 }
        body.initialize(from: [3, 1, 4], count: 3)
        headers.initialize(to: FfiHttpResponseHeader(name: name1, value: value1))
        headers.advanced(by: 1).initialize(to: FfiHttpResponseHeader(name: name2, value: value2))
        pointer.initialize(to: FfiHttpResponseBytes(status: 201, version: version, headers_ptr: headers, headers_len: 2, body_ptr: body, body_len: 3))
    }

    func free() {
        // Poison native bytes before releasing them to catch a non-owning Data conversion.
        body.update(repeating: 0, count: 3)
        body.deallocate()
        headers.deallocate()
        Darwin.free(version)
        Darwin.free(name1)
        Darwin.free(name2)
        Darwin.free(value1)
        Darwin.free(value2)
        pointer.deallocate()
    }
}

final class TorTestRuntimes: @unchecked Sendable {
    let parent = OpaquePointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))
    private let lock = NSLock()
    private var children: Set<OpaquePointer> = []
    private var parentAlive = true

    func clone(_ pointer: OpaquePointer?) -> OpaquePointer? {
        lock.withLock {
            guard pointer == parent && parentAlive else {
                XCTFail("Cloning a freed or unexpected runtime")
                return nil
            }
            let child = OpaquePointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))
            children.insert(child)
            return child
        }
    }

    func isAlive(_ pointer: OpaquePointer?) -> Bool {
        lock.withLock {
            guard let pointer else { return false }
            return pointer == parent ? parentAlive : children.contains(pointer)
        }
    }

    func free(_ pointer: OpaquePointer?) {
        lock.withLock {
            guard let pointer else { return }
            if pointer == parent {
                XCTAssertTrue(parentAlive, "Parent freed twice")
                parentAlive = false
            } else {
                XCTAssertNotNil(children.remove(pointer), "Child freed twice")
            }
            UnsafeMutablePointer<UInt8>(pointer).deallocate()
        }
    }
}
