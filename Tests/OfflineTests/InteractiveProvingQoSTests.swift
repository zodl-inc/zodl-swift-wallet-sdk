//
//  InteractiveProvingQoSTests.swift
//  ZODLSwiftWalletSDK
//

import XCTest
@testable import ZODLSwiftWalletSDK

final class InteractiveProvingQoSTests: XCTestCase {
    func testBoostSessionsAreRefcountedAndSaturateAtZero() {
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
        VotingRustBackend.beginInteractiveProvingBoost()
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 1)
        VotingRustBackend.beginInteractiveProvingBoost()
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 2)
        VotingRustBackend.endInteractiveProvingBoost()
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 1)
        VotingRustBackend.endInteractiveProvingBoost()
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
        VotingRustBackend.endInteractiveProvingBoost()
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
    }

    // Early validation throws happen before the boost is taken; the count must never move.
    func testCommitVoteDoesNotTakeBoostOnEarlyThrow() async {
        let backend = VotingRustBackend()
        let witness = VotingVanWitness(authPath: [], position: 0, anchorHeight: 0)
        do {
            _ = try await backend.commitVote(
                roundId: "00",
                bundleIndex: 0,
                hotkeyStoredSecret: [],
                proposalId: 1,
                choice: 0,
                numOptions: 2,
                voteCommitmentTreePosition: 0,
                vanWitness: witness,
                singleShare: false
            )
            XCTFail("commitVote without an open database must throw")
        } catch {
            XCTAssertEqual(error as? VotingRustBackendError, VotingRustBackendError.databaseNotOpen)
            XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
        }
    }

    func testBuildAndProveDelegationDoesNotTakeBoostOnEarlyThrow() async {
        let backend = VotingRustBackend()
        let keys = VotingDelegationKeyInputs(
            fvk: [],
            hotkeyStoredSecret: [],
            seedFingerprint: [],
            accountIndex: 0,
            roundName: "Round"
        )
        let params = VotingDelegationProofParams(
            roundId: "00",
            bundleIndex: 0,
            notes: [],
            keys: keys
        )
        do {
            _ = try await backend.buildAndProveDelegation(
                params,
                pirEndpoints: ["https://pir.invalid"],
                expectedSnapshotHeight: 1
            )
            XCTFail("buildAndProveDelegation without an open database must throw")
        } catch {
            XCTAssertEqual(error as? VotingRustBackendError, VotingRustBackendError.databaseNotOpen)
            XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
        }
    }

    func testWarmProvingCachesLeavesBoostCountAtZero() throws {
        try VotingRustBackend.warmProvingCaches()
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
    }

    func testCommitVoteReleasesBoostAfterRustRejectionInsideBoostedRegion() async throws {
        let backend = VotingRustBackend()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("qos-boost-\(UUID().uuidString).sqlite3").path
        try backend.open(path: path, networkId: 1)
        defer {
            backend.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        let witness = VotingVanWitness(authPath: [], position: 0, anchorHeight: 0)
        do {
            _ = try await backend.commitVote(
                roundId: "01" + String(repeating: "00", count: 31),
                bundleIndex: 0,
                hotkeyStoredSecret: [],
                proposalId: 1,
                choice: 0,
                numOptions: 2,
                voteCommitmentTreePosition: 0,
                vanWitness: witness,
                singleShare: false
            )
            XCTFail("commitVote for an uninitialized round must throw from the Rust layer")
        } catch {
            XCTAssertNotEqual(error as? VotingRustBackendError, VotingRustBackendError.databaseNotOpen)
            XCTAssertNotNil(error as? VotingRustBackendError)
            XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
        }
    }
}
