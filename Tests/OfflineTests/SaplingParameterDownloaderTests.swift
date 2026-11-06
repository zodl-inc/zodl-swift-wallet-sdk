//
//  SaplingParameterDownloaderTests.swift
//  OfflineTests
//
//  Tests for Sapling parameter downloader.
//

import XCTest
@testable import ZODLSwiftWalletSDK

final class SaplingParameterDownloaderTests: XCTestCase {

    /// Test that the default Sapling parameter URLs point to GitHub
    func testSaplingParamURLsPointToGitHub() throws {
        let spendURL = ZcashSDK.spendParamFileURL
        let outputURL = ZcashSDK.outputParamFileURL

        // Verify URLs point to GitHub raw content
        XCTAssertTrue(spendURL.absoluteString.hasPrefix("https://raw.githubusercontent.com/zodl-inc/zcash-sapling-params/main/"))
        XCTAssertTrue(outputURL.absoluteString.hasPrefix("https://raw.githubusercontent.com/zodl-inc/zcash-sapling-params/main/"))

        // Verify filenames
        XCTAssertTrue(spendURL.absoluteString.hasSuffix("sapling-spend.params"))
        XCTAssertTrue(outputURL.absoluteString.hasSuffix("sapling-output.params"))
    }

    /// Test that SaplingParamsSourceURL.default uses the correct GitHub URLs
    func testSaplingParamsSourceURLDefault() throws {
        let sourceURL = SaplingParamsSourceURL.default

        XCTAssertEqual(sourceURL.spendParamFileURL, ZcashSDK.spendParamFileURL)
        XCTAssertEqual(sourceURL.outputParamFileURL, ZcashSDK.outputParamFileURL)

        // Verify GitHub base URL
        let spendString = sourceURL.spendParamFileURL.absoluteString
        let outputString = sourceURL.outputParamFileURL.absoluteString

        XCTAssertTrue(spendString.contains("raw.githubusercontent.com/zodl-inc/zcash-sapling-params"))
        XCTAssertTrue(outputString.contains("raw.githubusercontent.com/zodl-inc/zcash-sapling-params"))
    }

    func testColdTorClientBootstrapsBeforeProductionDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("params/test.params")
        let source = URL(string: "https://example.com/test.params")!
        let runtimes = TorTestRuntimes()
        defer { if runtimes.isAlive(runtimes.parent) { runtimes.free(runtimes.parent) } }
        let response = TorResponseFixture()
        response.pointer.pointee.status = 200
        defer { response.free() }
        let created = expectation(description: "cold Swift Tor runtime prepared")
        let fetched = expectation(description: "async GET after preparation")
        let native = TorHTTPGetNative(
            get: { runtime, url, _, _, retry, milliseconds in
                XCTAssertTrue(runtimes.isAlive(runtime))
                XCTAssertEqual(String(cString: url!), source.absoluteString)
                XCTAssertEqual(retry, 2)
                XCTAssertGreaterThan(milliseconds, 0)
                XCTAssertLessThan(milliseconds, 1_799_975, "preparation must consume the same per-file deadline")
                fetched.fulfill()
                return response.pointer
            },
            freeResponse: { XCTAssertEqual($0, response.pointer) },
            isolateRuntime: { runtimes.clone($0) },
            freeRuntime: { runtimes.free($0) },
            startup: TorRuntimeStartupNative.fixture { _, _ in
                Thread.sleep(forTimeInterval: 0.025)
                created.fulfill()
                return runtimes.parent
            }
        )
        let client = TorClient(torDir: directory.appendingPathComponent("tor"), httpGetNative: native)
        do {
            _ = try await SaplingParameterDownloader.downloadFileWithTor(
                source, at: destination, logger: NullLogger(), torClient: client,
                validator: { temporary in
                    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                    XCTAssertEqual(try Data(contentsOf: temporary), Data([3, 1, 4]))
                }
            )
            XCTAssertEqual(try Data(contentsOf: destination), Data([3, 1, 4]))
        } catch {
            XCTFail("A cold Tor-enabled Sapling download must prepare its runtime: \(error)")
        }
        await fulfillment(of: [created, fetched], timeout: 1)
        try await client.close()
    }

    func testColdTorPreparationFailureDoesNotInstallOrFallBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("params/test.params")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([9]).write(to: destination)
        let created = expectation(description: "preparation attempted")
        let native = TorHTTPGetNative(
            get: { _, _, _, _, _, _ in
                XCTFail("Failed preparation must not GET")
                return nil
            },
            isolateRuntime: { _ in
                XCTFail("Failed preparation must not isolate")
                return nil
            },
            startup: TorRuntimeStartupNative.fixture { _, _ in
                created.fulfill()
                return nil
            }
        )
        let client = TorClient(torDir: directory.appendingPathComponent("tor"), httpGetNative: native)
        do {
            _ = try await SaplingParameterDownloader.downloadFileWithTor(
                URL(string: "https://example.com/test.params")!, at: destination, logger: NullLogger(), torClient: client,
                validator: { _ in XCTFail("Failed preparation must not validate") }
            )
            XCTFail("Failed preparation must fail closed on Tor")
        } catch {
            if case ZcashError.rustTorClientInit = error {
                // Preparation fails closed without starting an HTTP operation.
            } else {
                XCTFail("Expected the preparation error, received \(error)")
            }
        }
        await fulfillment(of: [created], timeout: 1)
        XCTAssertEqual(try Data(contentsOf: destination), Data([9]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["test.params"])
    }

    func testColdTorPreparationCancellationFinishesBeforeNativeCreationReturns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("params/test.params")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([9]).write(to: destination)
        let entered = expectation(description: "native preparation entered")
        let cancelled = expectation(description: "caller cancellation before native preparation returns")
        let released = expectation(description: "late prepared runtime cleaned")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let runtimes = TorTestRuntimes()
        defer { if runtimes.isAlive(runtimes.parent) { runtimes.free(runtimes.parent) } }
        let native = TorHTTPGetNative(
            get: { _, _, _, _, _, _ in
                XCTFail("Cancelled preparation must not GET")
                return nil
            },
            isolateRuntime: { _ in
                XCTFail("Cancelled preparation must not isolate")
                return nil
            },
            freeRuntime: { runtime in
                runtimes.free(runtime)
                released.fulfill()
            },
            startup: TorRuntimeStartupNative.fixture { _, _ in
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return runtimes.parent
            }
        )
        let client = TorClient(torDir: directory.appendingPathComponent("tor"), httpGetNative: native)
        let task = Task {
            do {
                _ = try await SaplingParameterDownloader.downloadFileWithTor(
                    URL(string: "https://example.com/test.params")!, at: destination, logger: NullLogger(), torClient: client,
                    validator: { _ in XCTFail("Cancelled preparation must not validate") }
                )
                XCTFail("Cancelled preparation must not install")
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {
                XCTFail("Expected cancellation, received \(error)")
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertEqual(try Data(contentsOf: destination), Data([9]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["test.params"])
        release.signal()
        _ = await task.result
        try await client.close()
        await fulfillment(of: [released], timeout: 1)
    }

    // Break caught: selecting the legacy synchronous GET drops the explicit per-file budget.
    func testTorDownloadUsesOneThirtyMinuteGETAndValidatesBeforeInstall() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("missing/test.params")
        let source = URL(string: "https://example.com/test.params")!
        let client = SaplingHTTPFixture { request, retry, timeout in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url, source)
            XCTAssertEqual(retry, 2)
            XCTAssertEqual(timeout, 1_800_000)
            return (Data([4, 2]), HTTPURLResponse(url: source, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        var validated = false
        let result = try await SaplingParameterDownloader.downloadFileWithTor(
            source, at: destination, logger: NullLogger(), torClient: client,
            validator: { temporary in
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                XCTAssertEqual(try Data(contentsOf: temporary), Data([4, 2]))
                validated = true
            }
        )
        XCTAssertTrue(validated)
        XCTAssertEqual(result, destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data([4, 2]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["test.params"])
    }

    func testCancellationAfterHTTPCompletionDoesNotInstall() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("test.params")
        let source = URL(string: "https://example.com/test.params")!
        let client = SaplingHTTPFixture { _, _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return (Data([4, 2]), HTTPURLResponse(url: source, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let task = Task {
            try await SaplingParameterDownloader.downloadFileWithTor(
                source, at: destination, logger: NullLogger(), torClient: client,
                validator: { _ in XCTFail("Cancelled data must not reach the validator") }
            )
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled download must not install")
        } catch is CancellationError {
            // Expected cancellation propagates without creating a file.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCancellationDuringValidationRemovesTemporaryFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("test.params")
        let source = URL(string: "https://example.com/test.params")!
        let client = SaplingHTTPFixture { _, _, _ in
            (Data([4, 2]), HTTPURLResponse(url: source, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let task = Task {
            try await SaplingParameterDownloader.downloadFileWithTor(
                source, at: destination, logger: NullLogger(), torClient: client,
                validator: { temporary in
                    XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation during validation must prevent installation")
        } catch is CancellationError {
            // Cancellation stays recognizable after temporary-file cleanup.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testValidationFailurePreservesExistingFileAndRemovesTemporaryFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("test.params")
        try Data([9]).write(to: destination)
        let source = URL(string: "https://example.com/test.params")!
        let client = SaplingHTTPFixture { _, _, _ in
            (Data([4, 2]), HTTPURLResponse(url: source, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await SaplingParameterDownloader.downloadFileWithTor(
                source, at: destination, logger: NullLogger(), torClient: client,
                validator: { _ in throw ZcashError.saplingParamsInvalidSpendParams }
            )
            XCTFail("Invalid data must not install")
        } catch ZcashError.saplingParamsInvalidSpendParams {
            // The production validator's error is preserved.
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data([9]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["test.params"])
    }

    func testTransportAndHTTPFailuresDoNotCreateFiles() async throws {
        for status in [nil, 503] as [Int?] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = URL(string: "https://example.com/test.params")!
            let client = SaplingHTTPFixture { _, _, _ in
                guard let status else { throw URLError(.networkConnectionLost) }
                return (Data([4, 2]), HTTPURLResponse(url: source, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            do {
                _ = try await SaplingParameterDownloader.downloadFileWithTor(
                    source, at: directory.appendingPathComponent("test.params"), logger: NullLogger(), torClient: client,
                    validator: { _ in XCTFail("Failed responses must not reach validation") }
                )
                XCTFail("Failed responses must not install")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            }
        }
    }

}

private struct SaplingHTTPFixture: SaplingParameterHTTPClient {
    var get: (URLRequest, UInt8, UInt64) async throws -> (data: Data, response: HTTPURLResponse)

    func httpGetPreparingRuntime(
        for request: URLRequest,
        retryLimit: UInt8,
        timeoutMilliseconds: UInt64
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        try await get(request, retryLimit, timeoutMilliseconds)
    }
}
