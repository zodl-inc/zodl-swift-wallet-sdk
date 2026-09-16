//
//  SaplingParameterDownloaderTests.swift
//  OfflineTests
//
//  Tests for Sapling parameter downloader.
//

import XCTest
@testable import ZcashLightClientKit

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
}
