//
//  GiftCardRedeemRoundsTests.swift
//  ZODLSwiftWalletSDK
//

import Combine
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class GiftCardRedeemRoundsTests: XCTestCase {
    private typealias Rounds = GiftCardRedeemRounds<String>

    /// Records what the redemption did, standing in for the card wallet.
    private actor Wallet {
        var proposals: [Rounds.Round]
        var proposeCalls: [Bool] = []
        var completed: [String] = []
        var awaitedMined: [[Data]] = []
        var failRound: Int?

        init(proposals: [Rounds.Round], failRound: Int? = nil) {
            self.proposals = proposals
            self.failRound = failRound
        }

        func propose(sendWhatFits: Bool) throws -> Rounds.Round {
            proposeCalls.append(sendWhatFits)
            guard !proposals.isEmpty else { throw ZcashError.giftCardNothingToRedeem }
            return proposals.removeFirst()
        }

        func complete(_ proposal: String) -> Rounds.Outcome {
            completed.append(proposal)
            let txId = Data(proposal.utf8)
            let result: TransactionSubmitResult = completed.count == failRound
                ? .submitFailure(txId: txId, code: -26, description: "bad")
                : .success(txId: txId)
            return .init(results: [result], recordedInDestination: true, fee: Zatoshi(10_000), amount: Zatoshi(100_000))
        }

        func mined(_ txIds: [Data]) {
            awaitedMined.append(txIds)
        }
    }

    private func rounds(_ wallet: Wallet, sendWhatFits: Bool, maxRounds: Int = 8) -> Rounds {
        Rounds(
            sendWhatFits: sendWhatFits,
            maxRounds: maxRounds,
            propose: { try await wallet.propose(sendWhatFits: $0) },
            complete: { await wallet.complete($0) },
            awaitMined: { await wallet.mined($0) }
        )
    }

    func testTheShippedRedeemerCannotSendPartOfACard() {
        XCTAssertFalse(GiftCardRedeemer.sendWhatFits, "librustzcash cannot yet propose a send-max within a size bound")
    }

    func testWithTheGateOffACardIsRedeemedInOneRound() async throws {
        // Even a proposal claiming to leave notes behind ends the redemption with the gate off.
        let wallet = Wallet(proposals: [.init(proposal: "all", remainingNotes: 3)])
        let rounds = rounds(wallet, sendWhatFits: false)

        let outcomes = try await rounds.run(startingWith: try await rounds.proposeFirst())

        XCTAssertEqual(outcomes.count, 1)
        let completed = await wallet.completed
        let proposeCalls = await wallet.proposeCalls
        let mined = await wallet.awaitedMined
        XCTAssertEqual(completed, ["all"])
        XCTAssertEqual(proposeCalls, [false])
        XCTAssertTrue(mined.isEmpty, "a single round never waits")
    }

    func testWithTheGateOffACardOverItsBoundFailsTypedAndNothingIsCreated() async {
        let wallet = Wallet(proposals: [])
        let rounds = Rounds(
            sendWhatFits: false,
            maxRounds: 8,
            propose: { _ in throw ZcashError.rustProposalTransactionTooLarge },
            complete: { await wallet.complete($0) },
            awaitMined: { await wallet.mined($0) }
        )

        do {
            _ = try await rounds.proposeFirst()
            XCTFail("A card over its bound must not be redeemed")
        } catch ZcashError.giftCardTooManyNotes {
        } catch {
            XCTFail("Expected giftCardTooManyNotes, got \(error)")
        }
        let completed = await wallet.completed
        XCTAssertTrue(completed.isEmpty, "nothing is created or broadcast")
    }

    func testOtherProposalFailuresPassThrough() async {
        let rounds = Rounds(
            sendWhatFits: false,
            maxRounds: 8,
            propose: { _ in throw ZcashError.giftCardNothingToRedeem },
            complete: { _ in XCTFail("unreachable"); throw ZcashError.giftCardRedemptionIncomplete },
            awaitMined: { _ in }
        )

        do {
            _ = try await rounds.proposeFirst()
            XCTFail("Expected a failure")
        } catch ZcashError.giftCardNothingToRedeem {
        } catch {
            XCTFail("Expected giftCardNothingToRedeem, got \(error)")
        }
    }

    func testWithTheGateOnACardIsRedeemedInRoundsUntilSwept() async throws {
        let wallet = Wallet(proposals: [
            .init(proposal: "r1", remainingNotes: 85),
            .init(proposal: "r2", remainingNotes: 10),
            .init(proposal: "r3", remainingNotes: 0)
        ])
        let rounds = rounds(wallet, sendWhatFits: true)

        let outcomes = try await rounds.run(startingWith: try await rounds.proposeFirst())

        XCTAssertEqual(outcomes.count, 3)
        let completed = await wallet.completed
        let proposeCalls = await wallet.proposeCalls
        let mined = await wallet.awaitedMined
        XCTAssertEqual(completed, ["r1", "r2", "r3"])
        XCTAssertEqual(proposeCalls, [true, true, true])
        XCTAssertEqual(mined, [[Data("r1".utf8)], [Data("r2".utf8)]], "each round waits for the previous to be mined")
    }

    func testARoundAServerDidNotAcceptEndsTheRedemption() async throws {
        let wallet = Wallet(
            proposals: [.init(proposal: "r1", remainingNotes: 50), .init(proposal: "r2", remainingNotes: 0)],
            failRound: 1
        )
        let rounds = rounds(wallet, sendWhatFits: true)

        let outcomes = try await rounds.run(startingWith: try await rounds.proposeFirst())

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(outcomes[0].allAccepted)
        let mined = await wallet.awaitedMined
        XCTAssertTrue(mined.isEmpty, "a failed round is not waited on")
    }

    func testRedemptionStopsAtMaxRounds() async throws {
        let wallet = Wallet(proposals: (1...5).map { .init(proposal: "r\($0)", remainingNotes: 100) })
        let rounds = rounds(wallet, sendWhatFits: true, maxRounds: 2)

        let outcomes = try await rounds.run(startingWith: try await rounds.proposeFirst())

        XCTAssertEqual(outcomes.count, 2)
    }

    func testADustRemainderEndsTheRedemption() async throws {
        let wallet = Wallet(proposals: [.init(proposal: "r1", remainingNotes: 1)])
        let rounds = rounds(wallet, sendWhatFits: true)

        let outcomes = try await rounds.run(startingWith: try await rounds.proposeFirst())

        XCTAssertEqual(outcomes.count, 1, "the note left over is not worth its fee")
    }

    func testOutcomesAddUpToOneRedemption() throws {
        let first = GiftCardRedeemRounds<Proposal>.Outcome(
            results: [.success(txId: Data([1]))],
            recordedInDestination: true,
            fee: Zatoshi(10_000),
            amount: Zatoshi(90_000)
        )
        let second = GiftCardRedeemRounds<Proposal>.Outcome(
            results: [.success(txId: Data([2]))],
            recordedInDestination: false,
            fee: Zatoshi(15_000),
            amount: Zatoshi(85_000)
        )

        let redemption = try GiftCardRedeemer.Redemption(rounds: [first, second])

        XCTAssertEqual(redemption.results, [.success(txId: Data([1])), .success(txId: Data([2]))])
        XCTAssertEqual(redemption.fee, Zatoshi(25_000))
        XCTAssertEqual(redemption.amount, Zatoshi(175_000))
        XCTAssertFalse(redemption.recordedInDestination, "recorded only when every round was")
        XCTAssertThrowsError(try GiftCardRedeemer.Redemption(rounds: []))
    }

    func testAwaitingMinedReturnsOnceEveryTransactionIsMined() async throws {
        let events = PassthroughSubject<SynchronizerEvent, Never>()
        let ids = [Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)]
        let waiting = Task {
            try await GiftCardRedeemer.awaitMined(ids, events: events.eraseToAnyPublisher())
        }
        // Give the waiter time to subscribe before the events arrive.
        try await Task.sleep(nanoseconds: 50_000_000)

        events.send(.minedTransaction(Self.overview(rawID: ids[0])))
        events.send(.minedTransaction(Self.overview(rawID: Data(repeating: 9, count: 32))))
        events.send(.minedTransaction(Self.overview(rawID: ids[1])))

        try await waiting.value
    }

    func testAwaitingMinedStopsOnCancellation() async throws {
        let events = PassthroughSubject<SynchronizerEvent, Never>()
        let waiting = Task {
            try await GiftCardRedeemer.awaitMined([Data(repeating: 1, count: 32)], events: events.eraseToAnyPublisher())
        }
        waiting.cancel()

        do {
            try await waiting.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    func testAwaitingNothingReturnsAtOnce() async throws {
        try await GiftCardRedeemer.awaitMined([], events: Empty().eraseToAnyPublisher())
    }

    private static func overview(rawID: Data) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
            accountUUID: TestsData.mockedAccountUUID,
            blockTime: nil,
            expiryHeight: nil,
            fee: nil,
            index: 0,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: 1,
            raw: nil,
            rawID: rawID,
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-1),
            isExpiredUmined: false,
            totalSpent: nil,
            totalReceived: nil,
            spentNoteCount: 0,
            poolCrossingValue: nil,
            isTrusted: false,
            zip318Kind: .notClassified
        )
    }
}
