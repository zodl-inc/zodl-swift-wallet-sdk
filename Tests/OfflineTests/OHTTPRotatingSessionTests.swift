import Foundation
import os
import XCTest
@testable import ZODLSwiftWalletSDK

final class OHTTPRotatingSessionTests: XCTestCase {
    private let request = URLRequest(url: URL(string: "https://rotation.example.invalid/relay")!)
    private let expectedBody = Data("rotation survived".utf8)

    func testPausedSenderSurvivesTwoRotations() async throws {
        let fixture = SessionFixture()
        let sessions = fixture.makePool()
        let start = Date()
        let first = sessions.acquire(now: start)
        let firstRecord = fixture.record(0)
        sessions.acquire(now: start.addingTimeInterval(10)).release()
        sessions.acquire(now: start.addingTimeInterval(20)).release()
        // Fail safely before task registration if the old immediate-invalidation bug returns.
        guard firstRecord.retirementCount == 0 else {
            XCTFail("A paused sender must still be allowed to register after two rotations")
            return
        }
        let (body, _) = try await OHTTPTransport.boundedData(for: request, maxBytes: 100, session: first.session)
        XCTAssertEqual(body, expectedBody)
        first.release()
        XCTAssertEqual(firstRecord.retirementCount, 1)
        await fulfillment(of: [firstRecord.invalidated, fixture.record(1).invalidated], timeout: 5)
    }

    func testBufferedAndStreamingSendersSurviveRotation() async throws {
        // Cover the default lease path for direct reads, deadline reads and streaming reads.
        for sender in 0..<3 {
            let fixture = SessionFixture()
            let sessions = fixture.makePool()
            let entered = expectation(description: "Sender acquired its generation")
            let gate = SetupGate()
            let request = request
            let operation = Task {
                try await OHTTPTransport.$sessionBox.withValue(sessions) {
                    try await OHTTPTransport.$beforeSessionSetupForTesting.withValue({
                        entered.fulfill()
                        await gate.wait()
                        // A mutation must fail safely instead of registering on an invalidated URLSession.
                        guard fixture.record(0).retirementCount == 0 else { throw RotationFixtureError.prematureRetirement }
                    }) {
                        switch sender {
                        case 0:
                            return try await OHTTPTransport.boundedData(for: request, maxBytes: 100).0
                        case 1:
                            return try await OHTTPTransport.boundedDataWithDeadline(for: request, maxBytes: 100, deadlineSeconds: 5).0
                        default:
                            let outer = try await OHTTPTransport.streamedData(for: request, maxBytes: 100)
                            var body = Data()
                            for try await chunk in outer.body { body.append(chunk) }
                            return body
                        }
                    }
                }
            }
            await fulfillment(of: [entered], timeout: 5)
            let first = fixture.record(0)
            sessions.acquire(now: Date().addingTimeInterval(20)).release()
            sessions.acquire(now: Date().addingTimeInterval(40)).release()
            XCTAssertEqual(first.retirementCount, 0)
            gate.open()
            let body = try await operation.value
            XCTAssertEqual(body, expectedBody)
            XCTAssertEqual(first.retirementCount, 1, "Setup must release its lease without retaining retired sessions")
            await fulfillment(of: [first.invalidated, fixture.record(1).invalidated], timeout: 5)
        }
    }

    func testCancelledSetupReleasesLease() async throws {
        for streaming in [false, true] {
            let fixture = SessionFixture()
            let sessions = fixture.makePool()
            let entered = expectation(description: "Setup paused before task registration")
            let gate = SetupGate()
            let request = request
            let operation = Task {
                try await OHTTPTransport.$sessionBox.withValue(sessions) {
                    try await OHTTPTransport.$beforeSessionSetupForTesting.withValue({
                        entered.fulfill()
                        await gate.wait()
                    }) {
                        if streaming {
                            _ = try await OHTTPTransport.streamedData(for: request, maxBytes: 100)
                        } else {
                            _ = try await OHTTPTransport.boundedData(for: request, maxBytes: 100)
                        }
                    }
                }
            }
            await fulfillment(of: [entered], timeout: 5)
            let first = fixture.record(0)
            operation.cancel()
            sessions.acquire(now: Date().addingTimeInterval(20)).release()
            XCTAssertEqual(first.retirementCount, 0)
            gate.open()
            do {
                try await operation.value
                XCTFail("Cancelled setup must not register a request")
            } catch is CancellationError {
                // Cancellation is checked before asking Foundation to create a task.
            }
            XCTAssertEqual(first.retirementCount, 1, "Cancellation must release the final creation lease")
            await fulfillment(of: [first.invalidated], timeout: 5)
        }
    }

    func testDispatchedProbeDeadlineRemainsUnavailable() async throws {
        for streaming in [false, true] {
            let fixture = SessionFixture()
            let sessions = fixture.makePool()
            let clock = TorTestClock()
            let budget = OHTTPHealthProbeBudget(milliseconds: 60_000, now: { clock.now })
            let request = request
            let outcome = await budget.run {
                try budget.admit()
                return try await OHTTPHealthProbe.$budget.withValue(budget) {
                    try await OHTTPTransport.$sessionBox.withValue(sessions) {
                        if streaming {
                            let response = try await OHTTPTransport.streamedData(for: request, maxBytes: 100)
                            for try await _ in response.body { }
                        } else {
                            _ = try await OHTTPTransport.boundedData(for: request, maxBytes: 100)
                        }
                        clock.advance(to: budget.deadline)
                        throw URLError(.timedOut)
                    }
                }
            }
            XCTAssertEqual(outcome, .transportUnavailable)
        }
    }

    func testExpiredProbeSetupRetiresWithoutDispatching() async throws {
        for streaming in [false, true] {
            let fixture = SessionFixture()
            let sessions = fixture.makePool()
            let clock = TorTestClock()
            let budget = OHTTPHealthProbeBudget(milliseconds: 60_000, now: { clock.now })
            do {
                try await OHTTPHealthProbe.$budget.withValue(budget) {
                    try await OHTTPTransport.$sessionBox.withValue(sessions) {
                        try await OHTTPTransport.$beforeSessionSetupForTesting.withValue({
                            sessions.acquire(now: Date().addingTimeInterval(20)).release()
                            clock.advance(to: budget.deadline)
                        }) {
                            if streaming {
                                _ = try await OHTTPTransport.streamedData(for: request, maxBytes: 100)
                            } else {
                                _ = try await OHTTPTransport.boundedData(for: request, maxBytes: 100)
                            }
                        }
                    }
                }
                XCTFail("Expired probe must not dispatch after setup")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
            }
            let first = fixture.record(0)
            XCTAssertEqual(first.retirementCount, 1)
            await fulfillment(of: [first.invalidated], timeout: 5)
        }
    }

    func testRetiredSessionFinishesExistingTask() async throws {
        let fixture = SessionFixture()
        let sessions = fixture.makePool()
        let lease = sessions.acquire()
        let first = fixture.record(0)
        let finished = expectation(description: "Registered task completes after retirement")
        let expectedBody = expectedBody
        let task = lease.session.dataTask(with: request) { body, _, error in
            XCTAssertNil(error)
            XCTAssertEqual(body, expectedBody)
            finished.fulfill()
        }
        XCTAssertEqual(task.state, .suspended)
        sessions.acquire(now: Date().addingTimeInterval(20)).release()
        lease.release()
        XCTAssertEqual(first.retirementCount, 1)
        // Streaming releases its creation lease before reader.start resumes the registered task.
        task.resume()
        await fulfillment(of: [finished, first.invalidated], timeout: 5)
    }

    func testAllCreationLeasesMustReleaseAndReleaseIsIdempotent() async {
        let fixture = SessionFixture()
        let sessions = fixture.makePool()
        let first = sessions.acquire()
        var second: RotatingSession.Lease? = sessions.acquire()
        XCTAssertTrue(first.session === second?.session)
        let record = fixture.record(0)
        sessions.acquire(now: Date().addingTimeInterval(20)).release()
        first.release()
        first.release()
        XCTAssertEqual(record.retirementCount, 0, "One outstanding lease still protects setup")
        second = nil
        XCTAssertEqual(record.retirementCount, 1, "Deinit releases the final lease exactly once")
        await fulfillment(of: [record.invalidated], timeout: 5)
    }
}

private enum RotationFixtureError: Error {
    case prematureRetirement
}

private final class SessionFixture: @unchecked Sendable {
    private let records = OSAllocatedUnfairLock(initialState: [SessionRecord]())

    func makePool() -> RotatingSession {
        RotatingSession(lifetime: 10, makeSession: {
            let delegate = InvalidationObserver()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RotationURLProtocol.self]
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let record = SessionRecord(session: session, invalidated: delegate.invalidated)
            self.records.withLock { $0.append(record) }
            return session
        }, retireSession: { session in
            let record = self.records.withLock { $0.first { $0.session === session }! }
            record.retired.withLock { $0 += 1 }
            session.finishTasksAndInvalidate()
        })
    }

    func record(_ index: Int) -> SessionRecord {
        records.withLock { $0[index] }
    }
}

private final class SessionRecord: Sendable {
    let session: URLSession
    let invalidated: XCTestExpectation
    let retired = OSAllocatedUnfairLock(initialState: 0)
    var retirementCount: Int { retired.withLock { $0 } }

    init(session: URLSession, invalidated: XCTestExpectation) {
        self.session = session
        self.invalidated = invalidated
    }
}

private final class InvalidationObserver: NSObject, URLSessionDelegate, @unchecked Sendable {
    let invalidated = XCTestExpectation(description: "Retired session invalidated after its tasks finish")

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        XCTAssertNil(error)
        invalidated.fulfill()
    }
}

private class RotationURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("rotation survived".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SetupGate: Sendable {
    private struct State {
        var open = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state in
                if state.open { return true }
                state.waiter = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiter = state.withLock { state in
            state.open = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}
