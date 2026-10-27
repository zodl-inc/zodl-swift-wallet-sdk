//
//  ServerEvaluationHeightTests.swift
//  OfflineTests
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// Both synchronizers rank candidate servers by asking each for its `getInfo`. A server can put any `UInt64`
/// in the tip it reports, and the SDK can't use one above `Int32.max`: that server is ruled out like any other
/// that fails a check, and must not crash the app on the way. The servers are lightwalletd stand-ins on the
/// loopback interface.
final class ServerEvaluationHeightTests: ZcashTestCase {
    private let tipsTheSDKCannotUse = [UInt64(Int32.max) + 1, UInt64(UInt32.max), UInt64(Int64.max) + 1, UInt64.max]

    private func makeServer(tip: UInt64) throws -> HeightReportingLightwalletd {
        let server = try HeightReportingLightwalletd()
        server.info = HeightReportingLightwalletd.testnetInfo(blockHeight: tip)
        // The latest block is a sane height, so that the tip `getInfo` reports is what sets the server apart.
        server.latestBlockHeight = 3_000_000
        server.compactBlockHeights = [2_999_999, 3_000_000]
        addTeardownBlock { try? server.stop() }
        return server
    }

    private func makeInitializer() throws -> Initializer {
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.consensusBranchIdForHeightClosure = { _ in -1026109260 }
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackend }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in LightWalletServiceMock() }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in TransactionRepositoryMock() }

        return Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )
    }

    // MARK: - SDKSynchronizer

    func testClassicBenchmarkKeepsAServerWhoseTipIsUsable() async throws {
        let healthy = try makeServer(tip: 3_000_000)
        let synchronizer = SDKSynchronizer(initializer: try makeInitializer())

        let ranked = await synchronizer.evaluateBestOf(
            endpoints: [healthy.endpoint],
            fetchThresholdSeconds: 10,
            nBlocksToFetch: 2,
            network: .testnet
        )

        XCTAssertEqual(ranked, [healthy.endpoint])
    }

    func testClassicBenchmarkRulesOutAServerWhoseTipTheSDKCannotUse() async throws {
        for tip in tipsTheSDKCannotUse {
            let healthy = try makeServer(tip: 3_000_000)
            let hostile = try makeServer(tip: tip)
            let synchronizer = SDKSynchronizer(initializer: try makeInitializer())

            let ranked = await synchronizer.evaluateBestOf(
                endpoints: [hostile.endpoint, healthy.endpoint],
                fetchThresholdSeconds: 10,
                nBlocksToFetch: 2,
                network: .testnet
            )

            XCTAssertEqual(ranked, [healthy.endpoint], "tip \(tip)")
        }
    }

    // MARK: - SlipstreamSynchronizer

    /// The current server is the one with the unusable tip, so the only way for the switch to go to the healthy
    /// candidate is for the current server to be ruled out.
    func testSlipstreamBenchmarkRulesOutAServerWhoseTipTheSDKCannotUse() async throws {
        for tip in tipsTheSDKCannotUse {
            let healthy = try makeServer(tip: 3_000_000)
            let hostile = try makeServer(tip: tip)
            let synchronizer = SlipstreamSynchronizer(initializer: try makeInitializer())

            let switchTo = await synchronizer.evaluateServerSwitch(
                current: hostile.endpoint,
                candidates: [healthy.endpoint],
                fetchThresholdSeconds: 10,
                nBlocksToFetch: 2,
                network: .testnet
            )

            XCTAssertEqual(switchTo, healthy.endpoint, "tip \(tip)")
        }
    }
}
