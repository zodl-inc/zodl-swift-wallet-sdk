import XCTest
@testable import ZODLSwiftWalletSDK

final class ServerSyncCheckTests: XCTestCase {
    private let nu7: UInt64 = 4_465_026
    private let mainnet = TargetBlockSpacing(networkType: .mainnet)
    private let testnet = TargetBlockSpacing(networkType: .testnet)

    func testA75SecondChainMayTrailBy288Blocks() {
        XCTAssertTrue(ServerSyncCheck.isSynced(blockHeight: 3_000_000, estimatedHeight: 3_000_288, spacing: mainnet))
        XCTAssertFalse(ServerSyncCheck.isSynced(blockHeight: 3_000_000, estimatedHeight: 3_000_289, spacing: mainnet))
    }

    func testA25SecondChainMayTrailBy864Blocks() {
        XCTAssertTrue(ServerSyncCheck.isSynced(blockHeight: nu7 + 1_000, estimatedHeight: nu7 + 1_864, spacing: testnet))
        XCTAssertFalse(ServerSyncCheck.isSynced(blockHeight: nu7 + 1_000, estimatedHeight: nu7 + 1_865, spacing: testnet))
    }

    /// 99 blocks of 75 s and 567 of 25 s fill the six hours exactly.
    func testALagAcrossNU7CountsEachBlockAtItsOwnSpacing() {
        XCTAssertTrue(ServerSyncCheck.isSynced(blockHeight: nu7 - 100, estimatedHeight: nu7 + 566, spacing: testnet))
        XCTAssertFalse(ServerSyncCheck.isSynced(blockHeight: nu7 - 100, estimatedHeight: nu7 + 567, spacing: testnet))
    }

    func testAServerAtOrAheadOfItsEstimateIsSyncedAndExtremesDoNotTrap() {
        XCTAssertTrue(ServerSyncCheck.isSynced(blockHeight: 3_000_000, estimatedHeight: 3_000_000, spacing: mainnet))
        XCTAssertTrue(ServerSyncCheck.isSynced(blockHeight: 3_000_000, estimatedHeight: 2_000_000, spacing: mainnet))
        XCTAssertTrue(ServerSyncCheck.isSynced(blockHeight: .max, estimatedHeight: 0, spacing: mainnet))
        XCTAssertFalse(ServerSyncCheck.isSynced(blockHeight: 0, estimatedHeight: .max, spacing: mainnet))
    }
}
