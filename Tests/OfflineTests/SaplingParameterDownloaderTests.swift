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

    func httpGet(for request: URLRequest, retryLimit: UInt8, timeoutMilliseconds: UInt64) async throws -> (data: Data, response: HTTPURLResponse) {
        try await get(request, retryLimit, timeoutMilliseconds)
    }
}
