//
//  SlipstreamImportAccountHeightTests.swift
//  OfflineTests
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// `importAccount` recovers the new account until the height of the restore anchor it resolves, and
/// imports it without a recovery height when it resolves none.
final class SlipstreamImportAccountHeightTests: ZcashTestCase {
    private func makeSynchronizer(
        anchor: SlipstreamRestoreAnchor?,
        welding: ZcashRustBackendWeldingMock
    ) throws -> SlipstreamSynchronizer {
        welding.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceReturnValue =
            TestsData.mockedAccountUUID
        return try makeSlipstreamSynchronizer(
            engine: GatedFakeSlipstreamEngine(),
            welding: welding,
            restoreAnchor: { _, _, _, _, _, _ in anchor }
        )
    }

    private func importAccount(into synchronizer: SlipstreamSynchronizer) async throws -> AccountUUID {
        try await synchronizer.importAccount(
            ufvk: "ufvk",
            seedFingerprint: nil,
            zip32AccountIndex: nil,
            purpose: .viewOnly,
            name: "Imported",
            keySource: nil,
            birthday: 2_000_000
        )
    }

    func testImportAccountRecoversUntilTheRestoreAnchorsHeight() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let synchronizer = try makeSynchronizer(
            anchor: SlipstreamRestoreAnchor(height: 3_123_456, treeState: nil),
            welding: welding
        )

        _ = try await importAccount(into: synchronizer)

        let imported = welding.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceReceivedArguments
        XCTAssertEqual(imported?.recoverUntil, 3_123_456)
    }

    func testImportAccountWithoutARestoreAnchorImportsWithoutARecoveryHeight() async throws {
        let welding = ZcashRustBackendWeldingMock()
        let synchronizer = try makeSynchronizer(anchor: nil, welding: welding)

        _ = try await importAccount(into: synchronizer)

        XCTAssertEqual(
            welding.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceCallsCount,
            1
        )
        let imported = welding.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceReceivedArguments
        XCTAssertNil(imported?.recoverUntil)
    }
}
