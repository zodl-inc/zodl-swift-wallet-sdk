import Foundation
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class BlockDownloaderLifecycleTests: XCTestCase {
    func testCancelledStopDownloadWaitsForInFlightStorageWrite() async throws {
        let writerEntered = XCTestExpectation(description: "storage write entered")
        let writerCancelled = XCTestExpectation(description: "storage writer received cancellation")
        let stopReturned = XCTestExpectation(description: "stop returned before writer release")
        stopReturned.isInverted = true
        let trace = DownloadLifecycleTrace()
        let storage = GatedDownloadStorage(entered: writerEntered, cancelled: writerCancelled, trace: trace)
        defer { storage.release.open() }
        let downloader = try await makeDownloader(storage: storage, trace: trace)

        await downloader.startDownload(maxBlockBufferSize: 10)
        await fulfillment(of: [writerEntered], timeout: 5)
        let stop = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertTrue(Task.isCancelled, "the caller must already be cancelled before stop")
            await downloader.stopDownload()
            trace.append("stop:returned")
            stopReturned.fulfill()
        }
        await fulfillment(of: [writerCancelled], timeout: 5)
        // This interval asserts absence only, after cancellation has reached the real writer.
        await fulfillment(of: [stopReturned], timeout: 0.1)
        storage.release.open()
        await stop.value

        XCTAssertTrue(trace.writerExitedBeforeEveryStop, "stop must join the writer: \(trace.events)")
    }

    func testCancelledFinalWriteDoesNotStartExtendedRange() async throws {
        let writerEntered = XCTestExpectation(description: "final storage write entered")
        let writerCancelled = XCTestExpectation(description: "writer received cancellation")
        let trace = DownloadLifecycleTrace()
        let storage = GatedDownloadStorage(entered: writerEntered, cancelled: writerCancelled, trace: trace)
        defer { storage.release.open() }
        let downloader = try await makeDownloader(storage: storage, trace: trace)

        await downloader.startDownload(maxBlockBufferSize: 10)
        await fulfillment(of: [writerEntered], timeout: 5)
        await downloader.setDownloadLimit(5)
        let stop = Task { await downloader.stopDownload() }
        await fulfillment(of: [writerCancelled], timeout: 5)
        storage.release.open()
        await stop.value

        XCTAssertEqual(trace.events.filter { $0.hasPrefix("stream:") }, ["stream:1"])
        XCTAssertEqual(trace.events.filter { $0.hasPrefix("blocks:") }, ["blocks:1"])
    }

    func testConcurrentStopsAndStartDuringDrainRetainTheWriter() async throws {
        let writerEntered = XCTestExpectation(description: "first writer entered")
        let writerCancelled = XCTestExpectation(description: "writer received cancellation")
        let freshWriterEntered = XCTestExpectation(description: "explicit start after drain admitted a fresh writer")
        let secondStopCalled = XCTestExpectation(description: "second cancelled caller invoked stop")
        let earlyStops = XCTestExpectation(description: "stop returned while writer held")
        earlyStops.isInverted = true
        let trace = DownloadLifecycleTrace()
        let storage = GatedDownloadStorage(
            entered: writerEntered,
            cancelled: writerCancelled,
            trace: trace,
            freshEntered: freshWriterEntered
        )
        defer { storage.release.open() }
        let downloader = try await makeDownloader(storage: storage, trace: trace)

        await downloader.startDownload(maxBlockBufferSize: 10)
        await fulfillment(of: [writerEntered], timeout: 5)
        let firstStop = Task {
            await downloader.stopDownload()
            trace.append("stop:first")
            earlyStops.fulfill()
        }
        await fulfillment(of: [writerCancelled], timeout: 5)
        let secondStop = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertTrue(Task.isCancelled)
            secondStopCalled.fulfill()
            await downloader.stopDownload()
            trace.append("stop:second")
            earlyStops.fulfill()
        }
        await fulfillment(of: [secondStopCalled], timeout: 5)
        await downloader.startDownload(maxBlockBufferSize: 10)
        // A negative observation only: both callers must stay suspended while the gate is shut.
        await fulfillment(of: [earlyStops], timeout: 0.1)
        storage.release.open()
        await firstStop.value
        await secondStop.value

        XCTAssertTrue(trace.writerExitedBeforeEveryStop, "both stops join the same writer: \(trace.events)")
        XCTAssertEqual(trace.events.filter { $0.hasPrefix("stream:") }, ["stream:1"])
        XCTAssertEqual(trace.events.filter { $0.hasPrefix("blocks:") }, ["blocks:1"])

        await downloader.setDownloadLimit(2)
        await downloader.startDownload(maxBlockBufferSize: 10)
        await fulfillment(of: [freshWriterEntered], timeout: 5)
        await downloader.stopDownload()
        let downloadedHeight = await downloader.latestDownloadedBlockHeight()
        XCTAssertEqual(downloadedHeight, 2)
        XCTAssertEqual(trace.events.filter { $0.hasPrefix("stream:") }, ["stream:1", "stream:2"])
        XCTAssertEqual(trace.events.filter { $0.hasPrefix("blocks:") }, ["blocks:1", "blocks:2"])
    }

    func testExtendedRangeStillDownloadsWithoutAStop() async throws {
        let writerEntered = XCTestExpectation(description: "first range write entered")
        let extendedWriterEntered = XCTestExpectation(description: "extended range write entered")
        let trace = DownloadLifecycleTrace()
        let storage = GatedDownloadStorage(
            entered: writerEntered,
            cancelled: XCTestExpectation(description: "writer cancellation"),
            trace: trace,
            freshEntered: extendedWriterEntered
        )
        defer { storage.release.open() }
        let downloader = try await makeDownloader(storage: storage, trace: trace)

        await downloader.startDownload(maxBlockBufferSize: 10)
        await fulfillment(of: [writerEntered], timeout: 5)
        await downloader.setDownloadLimit(5)
        storage.release.open()
        await fulfillment(of: [extendedWriterEntered], timeout: 5)
        await downloader.stopDownload()

        let downloadedHeight = await downloader.latestDownloadedBlockHeight()
        XCTAssertEqual(downloadedHeight, 5)
        XCTAssertEqual(trace.events.filter { $0.hasPrefix("stream:") }, ["stream:1", "stream:2"])
        XCTAssertEqual(trace.events.filter { $0.hasPrefix("blocks:") }, ["blocks:1", "blocks:2"])
    }

    private func makeDownloader(storage: GatedDownloadStorage, trace: DownloadLifecycleTrace) async throws -> BlockDownloaderImpl {
        let service = LightWalletServiceMock()
        service.blockStreamStartHeightEndHeightModeClosure = { start, end, _ in
            trace.append("stream:\(start)")
            return AsyncThrowingStream<ZcashCompactBlock, Error> { continuation in
                for height in start...end {
                    continuation.yield(ZcashCompactBlock(
                        height: height,
                        data: Data(),
                        meta: ZcashCompactBlock.Meta(hash: Data(), time: 0, saplingOutputs: 0, orchardOutputs: 0)
                    ))
                }
                continuation.finish()
            }
        }
        let logger = LoggerMock()
        logger.debugFileFunctionLineClosure = { _, _, _, _ in }
        logger.errorFileFunctionLineClosure = { _, _, _, _ in }
        let downloader = BlockDownloaderImpl(
            service: service,
            downloaderService: BlockDownloaderServiceImpl(service: service, storage: storage),
            storage: storage,
            metrics: SDKMetricsImpl(),
            logger: logger
        )
        try await downloader.setSyncRange(1...5, batchSize: 1)
        await downloader.setDownloadLimit(1)
        return downloader
    }
}

private final class DownloadLifecycleTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var writerExitedBeforeEveryStop: Bool {
        let events = events
        guard let exit = events.firstIndex(of: "write:exited") else { return false }
        return events.enumerated().allSatisfy { index, event in
            !event.hasPrefix("stop:") || index > exit
        }
    }

    func append(_ event: String) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }
}

private final class GatedDownloadStorage: CompactBlockRepository {
    let release = Gate()
    private let entered: XCTestExpectation
    private let cancelled: XCTestExpectation
    private let trace: DownloadLifecycleTrace
    private let freshEntered: XCTestExpectation?
    private let lock = NSLock()
    private var writes = 0

    init(
        entered: XCTestExpectation,
        cancelled: XCTestExpectation,
        trace: DownloadLifecycleTrace,
        freshEntered: XCTestExpectation? = nil
    ) {
        self.entered = entered
        self.cancelled = cancelled
        self.trace = trace
        self.freshEntered = freshEntered
    }

    func write(blocks: [ZcashCompactBlock]) async throws {
        guard !blocks.isEmpty else { return }
        trace.append("write:entered")
        trace.append("blocks:\(blocks[0].height)")
        recordWriteEntry()
        await withTaskCancellationHandler {
            await release.wait()
        } onCancel: {
            self.trace.append("writer:cancelled")
            self.cancelled.fulfill()
        }
        trace.append("write:exited")
    }

    private func recordWriteEntry() {
        lock.lock()
        writes += 1
        let write = writes
        lock.unlock()
        if write == 1 {
            entered.fulfill()
        } else {
            freshEntered?.fulfill()
        }
    }

    func create() async throws {}
    func latestHeight() async throws -> BlockHeight { -1 }
    func rewind(to height: BlockHeight) async throws {}
    func clear(upTo height: BlockHeight) async throws {}
    func clear() async throws {}
}
