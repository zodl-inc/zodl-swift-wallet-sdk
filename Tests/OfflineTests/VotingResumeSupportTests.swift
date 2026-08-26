//
//  VotingResumeSupportTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

/// Builds a round identifier that satisfies the Rust round-parameter validation,
/// which requires 64 lowercase hex characters encoding a canonical Pallas field
/// element. `tag` occupies the low byte so each caller gets a distinct round.
private func resumeHexRoundId(_ tag: UInt8) -> String {
    String(format: "%02x", tag) + String(repeating: "00", count: 31)
}

private let resumeWalletId = "test-wallet"
private let resumeNetworkId: UInt32 = 1
/// A well-formed round identifier that is never initialized, so the crate has
/// no stored session state or signing request to answer with.
private let resumeMissingRoundId = resumeHexRoundId(0xfb)
/// Orchard FVK length. The value is never used as a key here: the crate reads
/// only the account index, seed fingerprint and network out of the delegation
/// keys when loading a signing request.
private let resumeFvk = [UInt8](repeating: 0, count: 96)
private let resumeSeedFingerprint = [UInt8](repeating: 7, count: 32)
private let resumeRoundName = "chp-offline"

final class VotingResumeSupportTests: XCTestCase {
    private var dbPath: String?

    override func tearDown() {
        if let dbPath {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        dbPath = nil
        super.tearDown()
    }

    func test_resetSessionState_onUnknownRound_succeeds() throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }

        XCTAssertNoThrow(try backend.resetSessionState(roundId: resumeMissingRoundId))
    }

    func test_resetSessionState_emptyRoundId_throwsInvalidData() throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }

        XCTAssertThrowsError(try backend.resetSessionState(roundId: "")) { error in
            guard case VotingRustBackendError.invalidData(let message) = error else {
                XCTFail("expected .invalidData, got \(error.localizedDescription)")
                return
            }
            XCTAssertTrue(
                message.contains("roundId"),
                "unexpected message: \(message)"
            )
        }
    }

    func test_getDelegationSigningSighash_missingRound_throwsRustError() throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }

        XCTAssertThrowsError(
            try backend.getDelegationSigningSighash(
                roundId: resumeMissingRoundId,
                bundleIndex: 0,
                keys: try makeKeys()
            )
        ) { error in
            guard case VotingRustBackendError.rustError(let message) = error else {
                XCTFail("expected .rustError, got \(error.localizedDescription)")
                return
            }
            XCTAssertTrue(
                message.contains("signing_request failed"),
                "unexpected message: \(message)"
            )
        }
    }

    func test_getDelegationSigningSighash_badSeedFingerprint_throwsInvalidData() throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }

        XCTAssertThrowsError(
            try backend.getDelegationSigningSighash(
                roundId: resumeMissingRoundId,
                bundleIndex: 0,
                keys: try makeKeys(seedFingerprint: [UInt8](repeating: 7, count: 31))
            )
        ) { error in
            guard case VotingRustBackendError.invalidData(let message) = error else {
                XCTFail("expected .invalidData, got \(error.localizedDescription)")
                return
            }
            XCTAssertTrue(
                message.contains("seedFingerprint"),
                "unexpected message: \(message)"
            )
        }
    }

    // MARK: - Helpers

    /// A hotkey secret has to be real: the FFI reconstructs a `VotingHotkey`
    /// from it before it can build the delegation keys the signing request is
    /// loaded through. `generateHotkey` is static and needs no database.
    private func makeKeys(seedFingerprint: [UInt8] = resumeSeedFingerprint) throws -> VotingDelegationKeyInputs {
        let hotkey = try VotingRustBackend.generateHotkey(networkId: resumeNetworkId)
        return VotingDelegationKeyInputs(
            fvk: resumeFvk,
            hotkeyStoredSecret: hotkey.storedSecret,
            seedFingerprint: seedFingerprint,
            accountIndex: 0,
            roundName: resumeRoundName
        )
    }

    private func makeTempDbPath() -> String {
        let unique = ProcessInfo.processInfo.globallyUniqueString
        let path = "\(NSTemporaryDirectory())VotingResumeSupportTests-\(unique).sqlite"
        dbPath = path
        return path
    }

    private func makeOpenBackend() throws -> VotingRustBackend {
        let backend = VotingRustBackend()
        try backend.open(path: makeTempDbPath(), networkId: resumeNetworkId)
        try backend.setWalletId(resumeWalletId)
        return backend
    }
}
