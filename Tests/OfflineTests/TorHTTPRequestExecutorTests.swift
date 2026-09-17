import Foundation
import XCTest
@testable import ZcashLightClientKit

final class TorHTTPRequestExecutorTests: XCTestCase {
    func testOnlyTwoWorkersEnterAndReleasingOneAdmitsOneWaiter() async throws {
        let clock = TorTestClock()
        let executor = TorHTTPRequestExecutor(now: { clock.now }, sleepUntil: { try await clock.sleepUntil($0) })
        let first = TorWorkerGate()
        let second = TorWorkerGate()
        let third = TorWorkerGate()
        let fourth = TorWorkerGate()
        let tasks = [first, second].map { gate in
            Task { try await executor.execute(deadlineUptime: 10_000_000, operation: { try gate.run($0) }) }
        }
        await fulfillment(of: [first.entered, second.entered], timeout: 3)
        let thirdTask = Task { try await executor.execute(deadlineUptime: 10_000_000, operation: { try third.run($0) }) }
        await clock.waitForSleepers(1)
        let fourthTask = Task { try await executor.execute(deadlineUptime: 10_000_000, operation: { try fourth.run($0) }) }
        await clock.waitForSleepers(2)
        XCTAssertEqual(third.entries, 0)
        XCTAssertEqual(fourth.entries, 0)
        first.release()
        await fulfillment(of: [third.entered], timeout: 3)
        XCTAssertEqual(fourth.entries, 0)
        second.release()
        third.release()
        fourth.release()
        for task in tasks { _ = try await task.value }
        _ = try await thirdTask.value
        _ = try await fourthTask.value
    }

    func testQueuedCancellationDisposesWithoutEnteringAndActiveCancellationDrains() async throws {
        let clock = TorTestClock()
        let executor = TorHTTPRequestExecutor(now: { clock.now }, sleepUntil: { try await clock.sleepUntil($0) })
        let first = TorWorkerGate()
        let second = TorWorkerGate()
        let queued = TorWorkerGate()
        let disposed = expectation(description: "queued lease disposed")
        let firstReturned = TorTestCounter()
        let firstTask = Task {
            defer { firstReturned.increment() }
            return try await executor.execute(deadlineUptime: 10_000_000, operation: { try first.run($0) })
        }
        let secondTask = Task { try await executor.execute(deadlineUptime: 10_000_000, operation: { try second.run($0) }) }
        await fulfillment(of: [first.entered, second.entered], timeout: 3)
        let queuedTask = Task {
            try await executor.execute(deadlineUptime: 10_000_000, operation: { try queued.run($0) }, dispose: { disposed.fulfill() })
        }
        await clock.waitForSleepers(1)
        queuedTask.cancel()
        await assertCancelled(queuedTask)
        await fulfillment(of: [disposed], timeout: 3)
        XCTAssertEqual(queued.entries, 0)
        firstTask.cancel()
        // A queued request observes that cancellation has not returned the active permit.
        let next = TorWorkerGate()
        let nextTask = Task { try await executor.execute(deadlineUptime: 10_000_000, operation: { try next.run($0) }) }
        await clock.waitForSleepers(2)
        XCTAssertEqual(firstReturned.value, 0)
        XCTAssertEqual(next.entries, 0)
        first.release()
        await assertCancelled(firstTask)
        await fulfillment(of: [next.entered], timeout: 3)
        second.release()
        next.release()
        _ = try await secondTask.value
        _ = try await nextTask.value
    }

    func testQueuedExpiryAndAdmissionUseRemainingWholeMilliseconds() async throws {
        let clock = TorTestClock()
        let executor = TorHTTPRequestExecutor(now: { clock.now }, sleepUntil: { try await clock.sleepUntil($0) })
        let first = TorWorkerGate()
        let second = TorWorkerGate()
        let firstTask = Task { try await executor.execute(deadlineUptime: 20_000_000, operation: { try first.run($0) }) }
        let secondTask = Task { try await executor.execute(deadlineUptime: 20_000_000, operation: { try second.run($0) }) }
        await fulfillment(of: [first.entered, second.entered], timeout: 3)
        let expired = TorWorkerGate()
        let expiredTask = Task { try await executor.execute(deadlineUptime: 5_000_000, operation: { try expired.run($0) }) }
        await clock.waitForSleepers(1)
        clock.advance(to: 5_000_000)
        do {
            _ = try await expiredTask.value
            XCTFail("Expired request succeeded")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(expired.entries, 0)
        let admitted = TorWorkerGate()
        let admittedTask = Task { try await executor.execute(deadlineUptime: 10_000_000, operation: { try admitted.run($0) }) }
        await clock.waitForSleepers(2)
        clock.advance(to: 7_100_000)
        first.release()
        await fulfillment(of: [admitted.entered], timeout: 3)
        XCTAssertEqual(admitted.timeout, 2)
        second.release()
        admitted.release()
        _ = try await firstTask.value
        _ = try await secondTask.value
        _ = try await admittedTask.value
    }

    func testCancellationBeforeEnqueueAndSubmillisecondBudgetNeverEnter() async {
        let executor = TorHTTPRequestExecutor(now: { 1_000_001 })
        let cancelled = TorWorkerGate()
        let start = TorAsyncGate()
        let task = Task {
            await start.wait()
            return try await executor.execute(deadlineUptime: 20_000_000, operation: { try cancelled.run($0) })
        }
        task.cancel()
        await start.release()
        await assertCancelled(task)
        XCTAssertEqual(cancelled.entries, 0)
        let expired = TorWorkerGate()
        do {
            _ = try await executor.execute(deadlineUptime: 2_000_000, operation: { try expired.run($0) })
            XCTFail("Submillisecond budget succeeded")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(expired.entries, 0)
    }

    func testOperationAndDisposalRunOnDedicatedWorkerAndDisposeOnce() async throws {
        let key = DispatchSpecificKey<String>()
        let queue = DispatchQueue(label: "test.tor.worker", attributes: .concurrent)
        queue.setSpecific(key: key, value: "worker")
        let executor = TorHTTPRequestExecutor(workerQueue: queue)
        let disposals = TorTestCounter()
        _ = try await executor.execute(deadlineUptime: UInt64.max, operation: { _ in
            XCTAssertEqual(DispatchQueue.getSpecific(key: key), "worker")
            return TorWorkerGate.response
        }, dispose: {
            XCTAssertEqual(DispatchQueue.getSpecific(key: key), "worker")
            disposals.increment()
        })
        XCTAssertEqual(disposals.value, 1)
    }

    func testDeadlineSaturatesAndRejectsZeroDuration() throws {
        XCTAssertEqual(try TorHTTPRequestExecutor.deadline(timeoutMilliseconds: 3, now: 10), 3_000_010)
        XCTAssertEqual(try TorHTTPRequestExecutor.deadline(timeoutMilliseconds: UInt64.max, now: 1), UInt64.max)
        XCTAssertEqual(try TorHTTPRequestExecutor.deadline(timeoutMilliseconds: 1, now: UInt64.max - 1), UInt64.max)
        XCTAssertThrowsError(try TorHTTPRequestExecutor.deadline(timeoutMilliseconds: 0, now: 0))
    }

    func testQueuedCancellationBeforeActorDeliveryCannotRaceAdmission() async throws {
        let clock = TorTestClock()
        let pausedRead = TorPausedClockRead()
        let executor = TorHTTPRequestExecutor(now: { pausedRead.read() }, sleepUntil: { try await clock.sleepUntil($0) })
        let first = TorWorkerGate()
        let second = TorWorkerGate()
        let firstTask = Task { try await executor.execute(deadlineUptime: 10_000_000, operation: { try first.run($0) }) }
        let secondTask = Task { try await executor.execute(deadlineUptime: 10_000_000, operation: { try second.run($0) }) }
        await fulfillment(of: [first.entered, second.entered], timeout: 3)
        let queued = TorWorkerGate()
        let queuedTask = Task { try await executor.execute(deadlineUptime: 10_000_000, operation: { try queued.run($0) }) }
        await clock.waitForSleepers(1)
        queued.release()
        pausedRead.arm()
        first.release()
        // The actor is inside admission with a newly free permit. Its cancellation
        // message cannot run until this synchronous clock read returns.
        await fulfillment(of: [pausedRead.entered], timeout: 3)
        queuedTask.cancel()
        pausedRead.release()
        await assertCancelled(queuedTask)
        XCTAssertEqual(queued.entries, 0)
        second.release()
        _ = try await firstTask.value
        _ = try await secondTask.value
    }

    func testSuccessfulOperationRacingCancellationKeepsLeaseUntilDisposalReturns() async throws {
        let disposalEntered = expectation(description: "disposal entered")
        let release = DispatchSemaphore(value: 0)
        let count = TorTestCounter()
        let returned = TorTestCounter()
        let executor = TorHTTPRequestExecutor()
        let task = Task {
            defer { returned.increment() }
            return try await executor.execute(deadlineUptime: UInt64.max, operation: { _ in TorWorkerGate.response }, dispose: {
                disposalEntered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                count.increment()
            })
        }
        await fulfillment(of: [disposalEntered], timeout: 3)
        task.cancel()
        task.cancel()
        XCTAssertEqual(returned.value, 0)
        XCTAssertEqual(count.value, 0)
        release.signal()
        await assertCancelled(task)
        task.cancel()
        XCTAssertEqual(returned.value, 1)
        XCTAssertEqual(count.value, 1)
    }

    func testDeadlineRecheckedAfterDispatchWaitBeforeNativeEntry() async throws {
        let clock = TorTestClock()
        let queue = DispatchQueue(label: "test.tor.delayed", attributes: .concurrent)
        let blocked = expectation(description: "worker queue blocked")
        let release = DispatchSemaphore(value: 0)
        queue.async(flags: .barrier) {
            blocked.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        await fulfillment(of: [blocked], timeout: 3)
        let read = expectation(description: "admission read")
        let executor = TorHTTPRequestExecutor(workerQueue: queue, now: {
            if clock.now == 0 { read.fulfill() }
            return clock.now
        })
        let work = TorWorkerGate()
        let task = Task { try await executor.execute(deadlineUptime: 2_000_000, operation: { try work.run($0) }) }
        await fulfillment(of: [read], timeout: 3)
        clock.advance(to: 1_000_001)
        release.signal()
        do {
            _ = try await task.value
            XCTFail("Expired native entry succeeded")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(work.entries, 0)
    }

    private func assertCancelled(_ task: Task<(data: Data, response: HTTPURLResponse), Error>) async {
        do {
            _ = try await task.value
            XCTFail("Cancelled request succeeded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

final class TorWorkerGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "worker entered")
    private let gate = DispatchSemaphore(value: 0)
    private let state = NSLock()
    private var count = 0
    private var receivedTimeout: UInt64?

    var entries: Int { state.withLock { count } }
    var timeout: UInt64? { state.withLock { receivedTimeout } }
    static var response: (data: Data, response: HTTPURLResponse) {
        (Data([1, 2]), HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }

    func run(_ timeout: UInt64) throws -> (data: Data, response: HTTPURLResponse) {
        state.withLock {
            count += 1
            receivedTimeout = timeout
        }
        entered.fulfill()
        guard gate.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
        return Self.response
    }

    func release() { gate.signal() }
}

private final class TorTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private actor TorAsyncGate {
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}

final class TorTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: UInt64 = 0
    private var sleepers: [UUID: (UInt64, CheckedContinuation<Void, Error>)] = [:]
    private var registrations = 0
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    var now: UInt64 { lock.withLock { instant } }

    func sleepUntil(_ deadline: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    registrations += 1
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if instant >= deadline {
                        continuation.resume()
                    } else {
                        sleepers[id] = (deadline, continuation)
                    }
                    let ready = observers.filter { $0.0 <= registrations }
                    observers.removeAll { $0.0 <= registrations }
                    for observer in ready { observer.1.resume() }
                }
            }
        } onCancel: {
            self.lock.withLock { self.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
        }
    }

    func waitForSleepers(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if registrations >= count { continuation.resume() } else { observers.append((count, continuation)) }
            }
        }
    }

    func advance(to instant: UInt64) {
        lock.withLock {
            self.instant = instant
            let ready = sleepers.filter { $0.value.0 <= instant }
            for (id, sleeper) in ready {
                sleepers.removeValue(forKey: id)
                sleeper.1.resume()
            }
        }
    }
}

private final class TorPausedClockRead: @unchecked Sendable {
    let entered = XCTestExpectation(description: "actor admission paused")
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func read() -> UInt64 {
        let pause = lock.withLock {
            let pause = armed
            armed = false
            return pause
        }
        if pause {
            entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
        }
        return 0
    }
    func release() { gate.signal() }
}
