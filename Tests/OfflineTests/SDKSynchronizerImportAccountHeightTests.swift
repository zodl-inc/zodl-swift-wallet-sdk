//
//  SDKSynchronizerImportAccountHeightTests.swift
//  OfflineTests
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

/// `importAccount` recovers the new account until the tip the server reports, and hands it to the rust
/// backend as a `UInt32`. A tip that doesn't fit is treated like a tip that could not be fetched.
final class SDKSynchronizerImportAccountHeightTests: ZcashTestCase {
    private func makeFixture() async throws -> ClassicProcessorCleanupFixture {
        let fixture = try await ClassicProcessorCleanupFixture.make(storageDirectory: testTempDirectory)
        addTeardownBlock {
            await fixture.synchronizer.blockProcessor.stopAndWait()
            try await fixture.cleanup()
        }
        // The import leaves a stopped synchronizer alone, whereas it would restart a running one afterwards.
        await fixture.synchronizer.updateStatus(.stopped)
        fixture.backend.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceReturnValue =
            TestsData.mockedAccountUUID
        return fixture
    }

    private func importAccount(into synchronizer: SDKSynchronizer) async throws -> AccountUUID {
        try await synchronizer.importAccount(
            ufvk: "ufvk",
            seedFingerprint: nil,
            zip32AccountIndex: nil,
            purpose: .viewOnly,
            name: "Imported",
            keySource: nil,
            birthday: nil
        )
    }

    func testImportAccountRecoversUntilTheTipTheServerReports() async throws {
        let fixture = try await makeFixture()
        fixture.service.latestBlockHeightModeReturnValue = 3_100_000

        _ = try await importAccount(into: fixture.synchronizer)

        let imported = fixture.backend.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceReceivedArguments
        XCTAssertEqual(imported?.recoverUntil, 3_100_000)
    }

    func testImportAccountWithATipThatDoesNotFitUInt32FailsLikeWithAnUnreachableServer() async throws {
        let fixture = try await makeFixture()
        fixture.service.latestBlockHeightModeReturnValue = BlockHeight(UInt32.max) + 1

        do {
            _ = try await importAccount(into: fixture.synchronizer)
            XCTFail("Expected the import to fail without a usable tip.")
        } catch ZcashError.synchronizerNotPrepared {
        } catch {
            XCTFail("Expected ZcashError.synchronizerNotPrepared but got \(error).")
        }

        XCTAssertEqual(
            fixture.backend.importAccountUfvkSeedFingerprintZip32AccountIndexTreeStateRecoverUntilPurposeNameKeySourceCallsCount,
            0,
            "Nothing may be imported with a tip that could not be used."
        )
    }

    func testImportAccountWithAnUnreachableServerFails() async throws {
        let fixture = try await makeFixture()
        fixture.service.latestBlockHeightModeThrowableError = LightWalletServiceError.timeOut

        do {
            _ = try await importAccount(into: fixture.synchronizer)
            XCTFail("Expected the import to fail without a tip.")
        } catch ZcashError.synchronizerNotPrepared {
        } catch {
            XCTFail("Expected ZcashError.synchronizerNotPrepared but got \(error).")
        }
    }
}
