//
//  InteractiveProvingQoSTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

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
}
