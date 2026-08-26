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

    func test_getStoredPcztSighash_missingRound_throwsRustError() throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }

        XCTAssertThrowsError(
            try backend.getStoredPcztSighash(roundId: resumeMissingRoundId, bundleIndex: 0)
        ) { error in
            guard case VotingRustBackendError.rustError(let message) = error else {
                XCTFail("expected .rustError, got \(error.localizedDescription)")
                return
            }
            XCTAssertTrue(
                message.contains("load_pczt_sighash failed"),
                "unexpected message: \(message)"
            )
        }
    }

    // MARK: - Helpers

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
