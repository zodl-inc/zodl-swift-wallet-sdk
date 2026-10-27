//
//  MigrationUpgradeGateBypassTests.swift
//  OfflineTests
//
//  The internal-build opt-out of the NU7 network-upgrade gate is ONE `MigrationUpgradeGateBypass`
//  holder per `OrchardMigrationHost`, handed to every per-account migration the host builds and
//  read by each migration's backend on every gated FFI call. Sharing one holder is what lets a
//  single switch reach migrations that already exist and the ones built later, without any gated
//  welding signature carrying the flag. Driven through the host's injecting initializer against
//  `ZcashRustBackendWeldingMock`; no network, no FFI.
//

import XCTest
import os
@testable import TestUtils
@_spi(Testing) @testable import ZODLSwiftWalletSDK

final class MigrationUpgradeGateBypassTests: ZcashTestCase {
    private let accountA = AccountUUID(id: [UInt8](repeating: 0x0A, count: 16))
    private let accountB = AccountUUID(id: [UInt8](repeating: 0x0B, count: 16))
    private let accountC = AccountUUID(id: [UInt8](repeating: 0x0C, count: 16))

    // MARK: - The holder

    /// A holder is off until it is set, and reads back whatever was last set.
    func testTheHolderIsOffUntilSetAndFollowsEverySet() {
        let bypass = MigrationUpgradeGateBypass()
        XCTAssertFalse(bypass.isBypassed, "the gate is closed by default: production builds never set the bypass")

        bypass.setBypassed(true)
        XCTAssertTrue(bypass.isBypassed)
        bypass.setBypassed(true)
        XCTAssertTrue(bypass.isBypassed, "setting it again changes nothing")

        bypass.setBypassed(false)
        XCTAssertFalse(bypass.isBypassed)
    }

    // MARK: - The host

    /// The host hands the SAME holder to every migration it builds, so one `setUpgradeGateBypass`
    /// reaches the migrations that already exist and those built afterwards, and switching it off
    /// again reaches all of them too.
    func testHostSharesOneBypassWithEveryMigrationItBuilds() async throws {
        let recorder = BypassRecorder()
        let host = makeHost(recorder: recorder)

        _ = await host.migration(for: accountA)
        _ = await host.migration(for: accountB)
        let first = recorder.holders
        XCTAssertEqual(first.count, 2, "one holder is handed over per migration built")
        XCTAssertTrue(first[0] === first[1], "every migration receives the host's one holder")
        XCTAssertTrue(first.allSatisfy { !$0.isBypassed }, "the bypass is off by default")

        await host.setUpgradeGateBypass(true)
        XCTAssertTrue(first.allSatisfy(\.isBypassed), "migrations that already exist see the switch")

        _ = await host.migration(for: accountC)
        let all = recorder.holders
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all.allSatisfy { $0 === first[0] }, "a migration built later receives the same holder")
        XCTAssertTrue(all.allSatisfy(\.isBypassed), "and finds the bypass already on")

        await host.setUpgradeGateBypass(false)
        XCTAssertTrue(all.allSatisfy { !$0.isBypassed }, "switching it off reaches them all as well")
    }

    /// Each host owns its own holder: a bypass set on one synchronizer's host does not open the gate
    /// for another's.
    func testTwoHostsDoNotShareABypass() async throws {
        let firstRecorder = BypassRecorder()
        let secondRecorder = BypassRecorder()
        let first = makeHost(recorder: firstRecorder)
        let second = makeHost(recorder: secondRecorder)

        _ = await first.migration(for: accountA)
        _ = await second.migration(for: accountA)
        await first.setUpgradeGateBypass(true)

        XCTAssertEqual(firstRecorder.holders.map(\.isBypassed), [true])
        XCTAssertEqual(secondRecorder.holders.map(\.isBypassed), [false])
    }

    // MARK: - Helpers

    private func makeHost(recorder: BypassRecorder) -> OrchardMigrationHost {
        let welding = ZcashRustBackendWeldingMock()
        // `isSyncBlocked()`'s wallet-scope predicate reads the block-rate samples; default them to
        // "none" so the ticker's first evaluation does not trap on the mock's un-stubbed value.
        welding.migrationBlockRateSamplesWindowReturnValue = []
        let storage = testGeneralStorageDirectory!
        return OrchardMigrationHost(
            welding: welding,
            sharedBroadcaster: ScriptedBroadcaster(script: .throwing(ZcashError.migrationTorUnavailable)),
            generalStorageURL: storage,
            tickInterval: 3600,
            now: { Date() },
            logger: logger,
            spacing: TargetBlockSpacing(networkType: .testnet),
            actorFactory: { accountUUID, broadcaster, upgradeGateBypass in
                recorder.record(upgradeGateBypass)
                return OrchardMigration(
                    welding: welding,
                    accountUUID: accountUUID,
                    broadcaster: broadcaster,
                    syncGate: MigrationSyncGate(
                        directory: storage,
                        accountUUID: accountUUID,
                        tickInterval: 3600,
                        now: { Date() },
                        logger: logger
                    ),
                    logger: logger,
                    spacing: TargetBlockSpacing(networkType: .testnet)
                )
            }
        )
    }
}

/// Records the bypass holder each `OrchardMigrationHost` `actorFactory` call received, in build
/// order. The factory runs inside the host actor, so the list is guarded by a lock.
private final class BypassRecorder: Sendable {
    private let recorded = OSAllocatedUnfairLock<[MigrationUpgradeGateBypass]>(initialState: [])

    var holders: [MigrationUpgradeGateBypass] {
        recorded.withLock { $0 }
    }

    func record(_ holder: MigrationUpgradeGateBypass) {
        recorded.withLock { $0.append(holder) }
    }
}
