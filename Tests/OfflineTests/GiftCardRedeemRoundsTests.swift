//
//  GiftCardRedeemRoundsTests.swift
//  ZODLSwiftWalletSDK
//

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
        var polled: [[Data]] = []
        var progress: [RedeemProgress] = []
        let failRound: Int?
        /// The states each poll returns in turn; the last repeats.
        var states: [GiftCardRoundState]

        init(proposals: [Rounds.Round], failRound: Int? = nil, states: [GiftCardRoundState] = [.mined]) {
            self.proposals = proposals
            self.failRound = failRound
            self.states = states
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

        func state(_ txIds: [Data]) -> GiftCardRoundState {
            polled.append(txIds)
            return states.count > 1 ? states.removeFirst() : states[0]
        }

        func record(_ value: RedeemProgress) {
            progress.append(value)
        }
    }

    /// A clock the fake sleep advances, so timeouts are tested without waiting.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 0
        var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
        func advance(_ seconds: TimeInterval) { lock.lock(); time += seconds; lock.unlock() }
    }

    private func rounds(
        _ wallet: Wallet,
        sendWhatFits: Bool,
        maxRounds: Int = 8,
        clock: FakeClock = FakeClock(),
        roundTimeout: TimeInterval = 3_000
    ) -> Rounds {
        Rounds(
            sendWhatFits: sendWhatFits,
            maxRounds: maxRounds,
            timing: GiftCardRoundTiming(roundTimeout: roundTimeout, pollInterval: 15, now: { clock.now }, sleep: { clock.advance($0) }),
            propose: { try await wallet.propose(sendWhatFits: $0) },
            complete: { await wallet.complete($0) },
            roundState: { await wallet.state($0) },
            progress: { value in Task { await wallet.record(value) } }
        )
    }

    private func run(_ rounds: Rounds) async throws -> [Rounds.Outcome] {
        try await rounds.run(startingWith: try await rounds.proposeFirst())
    }

    private func expectError(_ expected: ZcashError, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("Expected \(expected)")
        } catch let error as ZcashError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Expected \(expected), got \(error)")
        }
    }

    func testTheShippedRedeemerCannotSendPartOfACard() {
        XCTAssertFalse(GiftCardRedeemer.sendWhatFits, "librustzcash cannot yet propose a send-max within a size bound")
    }

    func testWithTheGateOffACardIsRedeemedInOneRound() async throws {
        // Even a proposal claiming to leave notes behind ends the redemption with the gate off.
        let wallet = Wallet(proposals: [.init(proposal: "all", remainingNotes: 3)])

        let outcomes = try await run(rounds(wallet, sendWhatFits: false))

        XCTAssertEqual(outcomes.count, 1)
        let completed = await wallet.completed
        let proposeCalls = await wallet.proposeCalls
        let polled = await wallet.polled
        XCTAssertEqual(completed, ["all"])
        XCTAssertEqual(proposeCalls, [false])
        XCTAssertTrue(polled.isEmpty, "a single round never waits")
    }

    func testWithTheGateOffACardOverItsBoundFailsTypedAndNothingIsCreated() async {
        let wallet = Wallet(proposals: [])
        let rounds = Rounds(
            sendWhatFits: false,
            maxRounds: 8,
            timing: .live,
            propose: { _ in throw ZcashError.rustProposalTransactionTooLarge },
            complete: { await wallet.complete($0) },
            roundState: { _ in .mined },
            progress: { _ in }
        )

        await expectError(.giftCardTooManyNotes) { _ = try await rounds.proposeFirst() }
        let completed = await wallet.completed
        XCTAssertTrue(completed.isEmpty, "nothing is created or broadcast")
    }

    func testOtherProposalFailuresPassThrough() async {
        let rounds = Rounds(
            sendWhatFits: false,
            maxRounds: 8,
            timing: .live,
            propose: { _ in throw ZcashError.giftCardNothingToRedeem },
            complete: { _ in throw ZcashError.giftCardRedemptionIncomplete },
            roundState: { _ in .mined },
            progress: { _ in }
        )

        await expectError(.giftCardNothingToRedeem) { _ = try await rounds.proposeFirst() }
    }

    func testWithTheGateOnACardIsRedeemedInRoundsUntilSwept() async throws {
        let wallet = Wallet(
            proposals: [
                .init(proposal: "r1", remainingNotes: 85, remainingValue: Zatoshi(850_000)),
                .init(proposal: "r2", remainingNotes: 10, remainingValue: Zatoshi(100_000)),
                .init(proposal: "r3", remainingNotes: 0)
            ],
            states: [.pending, .mined]
        )

        let outcomes = try await run(rounds(wallet, sendWhatFits: true))

        XCTAssertEqual(outcomes.count, 3)
        let completed = await wallet.completed
        let proposeCalls = await wallet.proposeCalls
        let polled = await wallet.polled
        XCTAssertEqual(completed, ["r1", "r2", "r3"])
        XCTAssertEqual(proposeCalls, [true, true, true])
        XCTAssertEqual(polled, [[Data("r1".utf8)], [Data("r1".utf8)], [Data("r2".utf8)]], "a pending round is polled until mined")
    }

    func testEachRoundReportsItsProgressAndRemainder() async throws {
        let wallet = Wallet(proposals: [
            .init(proposal: "r1", remainingNotes: 5, remainingValue: Zatoshi(50_000)),
            .init(proposal: "r2", remainingNotes: 0)
        ])

        _ = try await run(rounds(wallet, sendWhatFits: true))
        // Progress is recorded on separate tasks; let them land.
        try await Task.sleep(nanoseconds: 50_000_000)

        let progress = await wallet.progress.sorted { ($0.round, $0.phase == .confirmed ? 1 : 0) < ($1.round, $1.phase == .confirmed ? 1 : 0) }
        XCTAssertEqual(progress, [
            RedeemProgress(round: 1, phase: .submitted, txIds: [Data("r1".utf8)], remainingNotes: 5, remainingValue: Zatoshi(50_000)),
            RedeemProgress(round: 1, phase: .confirmed, txIds: [Data("r1".utf8)], remainingNotes: 5, remainingValue: Zatoshi(50_000)),
            RedeemProgress(round: 2, phase: .submitted, txIds: [Data("r2".utf8)], remainingNotes: 0, remainingValue: .zero)
        ])
    }

    func testAFirstRoundAServerDidNotAcceptReturnsItsResults() async throws {
        let wallet = Wallet(proposals: [.init(proposal: "r1", remainingNotes: 50)], failRound: 1)

        let outcomes = try await run(rounds(wallet, sendWhatFits: true))

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(outcomes[0].allAccepted)
        let polled = await wallet.polled
        XCTAssertTrue(polled.isEmpty, "a failed round is not waited on")
    }

    func testALaterRoundAServerDidNotAcceptFailsTypedWithEveryTxId() async {
        let wallet = Wallet(
            proposals: [.init(proposal: "r1", remainingNotes: 50), .init(proposal: "r2", remainingNotes: 0)],
            failRound: 2
        )

        await expectError(.giftCardRoundFailed(2, [Data("r1".utf8), Data("r2".utf8)])) {
            _ = try await self.run(self.rounds(wallet, sendWhatFits: true))
        }
    }

    func testAnExpiredRoundFailsTypedWithEveryTxId() async {
        let wallet = Wallet(proposals: [.init(proposal: "r1", remainingNotes: 50)], states: [.pending, .expired])

        await expectError(.giftCardRoundExpired(1, [Data("r1".utf8)])) {
            _ = try await self.run(self.rounds(wallet, sendWhatFits: true))
        }
    }

    func testARoundStillPendingAtItsTimeoutFailsTyped() async {
        let wallet = Wallet(proposals: [.init(proposal: "r1", remainingNotes: 50)], states: [.pending])
        let clock = FakeClock()

        await expectError(.giftCardRoundExpired(1, [Data("r1".utf8)])) {
            _ = try await self.run(self.rounds(wallet, sendWhatFits: true, clock: clock, roundTimeout: 60))
        }
        let polls = await wallet.polled.count
        XCTAssertEqual(polls, 5, "polled every 15 s until the 60 s timeout")
    }

    func testRedemptionStopsAtMaxRounds() async throws {
        let wallet = Wallet(proposals: (1...5).map { .init(proposal: "r\($0)", remainingNotes: 100) })

        let outcomes = try await run(rounds(wallet, sendWhatFits: true, maxRounds: 2))

        XCTAssertEqual(outcomes.count, 2)
    }

    func testADustRemainderEndsTheRedemption() async throws {
        let wallet = Wallet(proposals: [.init(proposal: "r1", remainingNotes: 1)])

        let outcomes = try await run(rounds(wallet, sendWhatFits: true))

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

    // MARK: - Round state from the card wallet's transactions

    func testARoundIsMinedOnlyWhenEveryTransactionIs() {
        let ids = [Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)]
        let mined = ids.map { Self.overview(rawID: $0, minedHeight: 10) }
        XCTAssertEqual(GiftCardRedeemer.roundState(of: ids, in: mined), .mined)
        XCTAssertEqual(GiftCardRedeemer.roundState(of: ids, in: [mined[0]]), .pending, "an unlisted transaction is pending")
        XCTAssertEqual(
            GiftCardRedeemer.roundState(of: ids, in: [mined[0], Self.overview(rawID: ids[1], minedHeight: nil)]),
            .pending
        )
    }

    func testARoundWithAnExpiredTransactionIsExpired() {
        let ids = [Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)]
        let transactions = [
            Self.overview(rawID: ids[0], minedHeight: 10),
            Self.overview(rawID: ids[1], minedHeight: nil, expired: true)
        ]
        XCTAssertEqual(GiftCardRedeemer.roundState(of: ids, in: transactions), .expired)
    }

    func testProgressReachesEveryStreamUntilFinished() async {
        let broadcaster = GiftCardProgressBroadcaster()
        let first = broadcaster.stream()
        let second = broadcaster.stream()
        let value = RedeemProgress(round: 1, phase: .submitted, txIds: [], remainingNotes: 0, remainingValue: .zero)

        broadcaster.send(value)
        broadcaster.finish()

        var firstValues: [RedeemProgress] = []
        for await progress in first { firstValues.append(progress) }
        var secondValues: [RedeemProgress] = []
        for await progress in second { secondValues.append(progress) }
        XCTAssertEqual(firstValues, [value])
        XCTAssertEqual(secondValues, [value])
    }

    private static func overview(rawID: Data, minedHeight: BlockHeight?, expired: Bool = false) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
            accountUUID: TestsData.mockedAccountUUID,
            blockTime: nil,
            expiryHeight: nil,
            fee: nil,
            index: 0,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: minedHeight,
            raw: nil,
            rawID: rawID,
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-1),
            isExpiredUmined: expired,
            totalSpent: nil,
            totalReceived: nil,
            spentNoteCount: 0,
            poolCrossingValue: nil,
            isTrusted: false,
            zip318Kind: .notClassified
        )
    }
}
