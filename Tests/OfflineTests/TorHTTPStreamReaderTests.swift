import Foundation
import libzcashlc
import os
import XCTest
@testable import ZODLSwiftWalletSDK

final class TorHTTPStreamReaderTests: XCTestCase {
    func testAStalledBodyFailsWithTimedOutAfterTheIdleDeadline() async throws {
        let fake = FakeTorStream(script: [.data("a")], then: .pending)

        let outcome = await read(fake, idleTimeout: 1)

        XCTAssertEqual(outcome.chunks, ["a"])
        XCTAssertEqual((outcome.error as? URLError)?.code, .timedOut)
        // One second of waiting, 250 ms at a time: the deadline cannot come sooner.
        XCTAssertGreaterThanOrEqual(fake.served.filter { $0 == .pending }.count, 4)
        await assertTheStreamIsFreedOnce(fake)
    }

    func testATrickleShorterThanTheDeadlineNeverTimesOut() async throws {
        var script: [FakeTorStream.Step] = []
        for index in 0..<10 {
            script.append(.pending)
            script.append(.data("\(index)"))
        }
        script.append(.end)
        let fake = FakeTorStream(script: script)

        // Five seconds pass in all, five times the idle deadline, but never one second without bytes.
        let outcome = await read(fake, idleTimeout: 1)

        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.chunks, (0..<10).map { "\($0)" })
        await assertTheStreamIsFreedOnce(fake)
    }

    func testPendingWithoutBytesDoesNotResetTheDeadline() async throws {
        // Eight pending reads are scripted, twice what the deadline allows: were any of them to count as
        // progress, the reader would use up the script and the fake would fail the test.
        let fake = FakeTorStream(script: [.data("a")] + Array(repeating: .pending, count: 8))

        let outcome = await read(fake, idleTimeout: 1)

        XCTAssertEqual(outcome.chunks, ["a"])
        XCTAssertEqual((outcome.error as? URLError)?.code, .timedOut)
        XCTAssertEqual(fake.served.filter { $0 == .pending }.count, 4)
        await assertTheStreamIsFreedOnce(fake)
    }

    func testADataReadWithoutBytesDoesNotResetTheDeadline() async throws {
        let fake = FakeTorStream(script: [.data("a")] + Array(repeating: .emptyData, count: 8))

        let outcome = await read(fake, idleTimeout: 1)

        XCTAssertEqual(outcome.chunks, ["a"])
        XCTAssertEqual((outcome.error as? URLError)?.code, .timedOut)
        XCTAssertEqual(fake.served.filter { $0 == .emptyData }.count, 4)
        await assertTheStreamIsFreedOnce(fake)
    }

    func testAnIdleTimeoutThatIsNotPositiveAndFiniteIsOneSecond() async throws {
        for idleTimeout in [0, -3, TimeInterval.nan, .infinity, -.infinity] {
            let fake = FakeTorStream(script: [], then: .pending)

            let outcome = await read(fake, idleTimeout: idleTimeout)

            XCTAssertEqual((outcome.error as? URLError)?.code, .timedOut, "idle timeout \(idleTimeout)")
            XCTAssertEqual(fake.served.count, 4, "idle timeout \(idleTimeout)")
            await assertTheStreamIsFreedOnce(fake)
        }
    }

    func testAnIdleTimeoutTooLongToCountInNanosecondsSaturatesInsteadOfOverflowing() async throws {
        // An hour of pending reads: an overflow that wrapped to a short deadline would end the body in a second.
        let hour = Int(3600 * 1000 / TorHTTPStreamReader.waitMilliseconds)
        let fake = FakeTorStream(
            script: Array(repeating: .pending, count: hour) + [.data("z"), .end],
            maxReads: hour + 2
        )

        let outcome = await read(fake, idleTimeout: .greatestFiniteMagnitude)

        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.chunks, ["z"])
        await assertTheStreamIsFreedOnce(fake)
    }

    func testANativeFailureFinishesWithTheTorError() async throws {
        let fake = FakeTorStream(script: [.data("a"), .failure])

        let outcome = await read(fake, idleTimeout: 60)

        XCTAssertEqual(outcome.chunks, ["a"])
        guard case ZcashError.rustTorHttpRequest = try XCTUnwrap(outcome.error) else {
            return XCTFail("Expected the Tor HTTP request error")
        }
        XCTAssertEqual(fake.served.count, 2, "Nothing is read once a read has failed")
        await assertTheStreamIsFreedOnce(fake)
    }

    func testCancellingTheBodyStopsReadingAndFreesTheStreamOnce() async throws {
        let fake = FakeTorStream(script: [], then: .pending)
        let firstReadStarted = expectation(description: "the first native read started")
        let releaseFirstRead = DispatchSemaphore(value: 0)
        fake.onRead = { number in
            guard number == 1 else { return }
            firstReadStarted.fulfill()
            _ = releaseFirstRead.wait(timeout: .now() + 5)
        }
        let consumer = Task {
            let reader = TorHTTPStreamReader(
                stream: fake.stream,
                owner: nil,
                idleTimeout: 60,
                native: fake.native,
                now: fake.now
            )
            for try await _ in reader.body() {}
        }

        await fulfillment(of: [firstReadStarted], timeout: 3)
        consumer.cancel()
        // The body has terminated, and so told the reader to stop, by the time its consumer is through.
        try await consumer.value
        releaseFirstRead.signal()

        await assertTheStreamIsFreedOnce(fake)
        XCTAssertEqual(fake.reads, 1, "No native read starts once the body was cancelled")
    }

    // MARK: - Helpers

    /// Reads the body of a reader over `fake` to its end or its failure. The reader goes out of scope here:
    /// the read loop holds it for as long as it runs, and its release is what frees the native stream.
    private func read(
        _ fake: FakeTorStream,
        idleTimeout: TimeInterval
    ) async -> (chunks: [String], error: Error?) {
        var chunks: [String] = []
        do {
            let reader = TorHTTPStreamReader(
                stream: fake.stream,
                owner: nil,
                idleTimeout: idleTimeout,
                native: fake.native,
                now: fake.now
            )
            for try await chunk in reader.body() {
                chunks.append(String(data: chunk, encoding: .utf8) ?? "<not UTF-8>")
            }
            return (chunks, nil)
        } catch {
            return (chunks, error)
        }
    }

    /// Waits for the release of the reader, which frees the native stream, and checks that nothing is left
    /// freed twice or not at all.
    private func assertTheStreamIsFreedOnce(
        _ fake: FakeTorStream,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await fulfillment(of: [fake.streamFreed], timeout: 3)
        // A second free, were there one, would follow right behind the first.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fake.streamFrees, 1, "The native stream is freed exactly once", file: file, line: line)
        XCTAssertEqual(fake.liveSlices, 0, "Every slice the native stream handed out is freed", file: file, line: line)
    }
}

/// A native stream that replays a script, one step per read. Its clock moves only by the time each read was
/// asked to wait, as if every read waited all of it, so a test spends no real time on a stalled stream.
private final class FakeTorStream: @unchecked Sendable {
    enum Step: Equatable {
        case data(String)
        /// A read that reports data, with no bytes in it.
        case emptyData
        case pending
        case end
        /// A read that fails: the native stream returns null.
        case failure
    }

    private struct Record {
        var served: [Step] = []
        var reads = 0
        var uptime: UInt64 = 5_000_000_000
        var liveSlices: Set<UnsafeMutablePointer<FfiBoxedSlice>> = []
        var streamFrees = 0
    }

    let stream = OpaquePointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))
    /// Fulfilled when the native stream is freed.
    let streamFreed = XCTestExpectation(description: "the native stream was freed")
    /// Runs at the start of every read with its number (the first read is 1), before the read is served.
    var onRead: (@Sendable (Int) -> Void)?
    private let script: [Step]
    private let tail: Step?
    private let maxReads: Int
    private let record = OSAllocatedUnfairLock(uncheckedState: Record())

    /// - Parameters:
    ///   - script: What the reads give, in order.
    ///   - tail: What every read after the script gives; without one, a read past the script fails the test.
    ///   - maxReads: The read after which the fake fails the test and the read, so that a reader that never
    ///     stops fails it rather than hang it.
    init(script: [Step], then tail: Step? = nil, maxReads: Int = 1_000) {
        self.script = script
        self.tail = tail
        self.maxReads = maxReads
    }

    var native: TorHTTPStreamNative {
        TorHTTPStreamNative(
            next: { [self] pointer, wait, state in next(pointer, wait, state) },
            freeSlice: { [self] slice in freeSlice(slice) },
            freeStream: { [self] pointer in freeStream(pointer) }
        )
    }

    var now: @Sendable () -> UInt64 {
        { [self] in record.withLockUnchecked { $0.uptime } }
    }

    var served: [Step] { record.withLockUnchecked { $0.served } }
    var reads: Int { record.withLockUnchecked { $0.reads } }
    var liveSlices: Int { record.withLockUnchecked { $0.liveSlices.count } }
    var streamFrees: Int { record.withLockUnchecked { $0.streamFrees } }

    private func next(
        _ pointer: OpaquePointer,
        _ waitMilliseconds: UInt64,
        _ state: UnsafeMutablePointer<UInt8>
    ) -> UnsafeMutablePointer<FfiBoxedSlice>? {
        XCTAssertEqual(pointer, stream, "A read of a stream that is not the one under test")
        let (number, step) = record.withLockUnchecked { current -> (Int, Step?) in
            current.reads += 1
            let step = current.reads <= script.count ? script[current.reads - 1] : tail
            if let step { current.served.append(step) }
            return (current.reads, step)
        }
        onRead?(number)
        guard number <= maxReads else {
            XCTFail("The reader was still reading after \(maxReads) reads")
            return nil
        }
        guard let step else {
            XCTFail("The reader read past the end of the script")
            return nil
        }
        record.withLockUnchecked { $0.uptime += waitMilliseconds * 1_000_000 }
        switch step {
        case .data(let text):
            state.pointee = 0
            return makeSlice(Array(text.utf8))

        case .emptyData:
            state.pointee = 0
            return makeSlice([])

        case .pending:
            state.pointee = 1
            return makeSlice([])

        case .end:
            state.pointee = 2
            return makeSlice([])

        case .failure:
            return nil
        }
    }

    private func makeSlice(_ bytes: [UInt8]) -> UnsafeMutablePointer<FfiBoxedSlice> {
        let slice = UnsafeMutablePointer<FfiBoxedSlice>.allocate(capacity: 1)
        if bytes.isEmpty {
            slice.initialize(to: FfiBoxedSlice(ptr: nil, len: 0))
        } else {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            buffer.initialize(from: bytes, count: bytes.count)
            slice.initialize(to: FfiBoxedSlice(ptr: buffer, len: UInt(bytes.count)))
        }
        record.withLockUnchecked { _ = $0.liveSlices.insert(slice) }
        return slice
    }

    private func freeSlice(_ slice: UnsafeMutablePointer<FfiBoxedSlice>) {
        let wasLive = record.withLockUnchecked { $0.liveSlices.remove(slice) != nil }
        XCTAssertTrue(wasLive, "A slice was freed twice, or was never handed out")
        guard wasLive else { return }
        if let buffer = slice.pointee.ptr {
            // Poison the bytes before releasing them, to catch a reader that hands out a view of them.
            buffer.update(repeating: 0, count: Int(slice.pointee.len))
            buffer.deallocate()
        }
        slice.deallocate()
    }

    private func freeStream(_ pointer: OpaquePointer) {
        XCTAssertEqual(pointer, stream, "A free of a stream that is not the one under test")
        let frees = record.withLockUnchecked { current -> Int in
            current.streamFrees += 1
            return current.streamFrees
        }
        guard frees == 1 else { return }
        UnsafeMutablePointer<UInt8>(stream).deallocate()
        streamFreed.fulfill()
    }
}
