//
//  SlipstreamRestoreAnchorHeightTests.swift
//  OfflineTests
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// The engine resolves a restore's anchor from the tip its server reports. A tip the SDK can't use (above
/// `Int32.max`) can only come from a broken or hostile server, and resolves like an unreachable server, so the
/// restore still gets a recovery height. These tests run the real engine against a lightwalletd stand-in on the
/// loopback interface.
final class SlipstreamRestoreAnchorHeightTests: ZcashTestCase {
    private func makeServer(latestBlockHeight: UInt64) throws -> HeightReportingLightwalletd {
        let server = try HeightReportingLightwalletd()
        addTeardownBlock { try? server.stop() }
        server.latestBlockHeight = latestBlockHeight
        return server
    }

    private func restoreAnchor(from server: HeightReportingLightwalletd) async -> SlipstreamRestoreAnchor? {
        await SlipstreamEngine.restoreAnchor(
            isRestore: true,
            birthday: 2_000_000,
            fallbackCheckpointHeight: 2_500_000,
            server: server.endpoint,
            network: ZcashNetworkBuilder.network(for: .testnet),
            torDirPath: nil
        )
    }

    func testRestoreAnchorIsTheTipTheServerReports() async throws {
        let server = try makeServer(latestBlockHeight: 3_123_456)

        let anchor = await restoreAnchor(from: server)

        XCTAssertEqual(anchor?.height, 3_123_456)
        XCTAssertNil(anchor?.treeState)
    }

    func testRestoreAnchorForATipAboveInt32MaxIsTheOfflineFallback() async throws {
        for reported in [UInt64(Int32.max) + 1, UInt64(UInt32.max), UInt64.max] {
            let server = try makeServer(latestBlockHeight: reported)

            let anchor = await restoreAnchor(from: server)

            // max(fallbackCheckpointHeight, birthday + 1), as when the server cannot be reached.
            XCTAssertEqual(anchor?.height, 2_500_000, "\(reported)")
        }
    }
}
