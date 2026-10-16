//
//  GiftCardRedeemRounds.swift
//  ZODLSwiftWalletSDK
//

import Foundation

/// The progress of a gift card redemption, one value per round and phase, as
/// ``GiftCardRedeemer/redeemProgress()`` delivers it.
public struct RedeemProgress: Equatable {
    /// Where a round stands.
    public enum Phase: Equatable {
        /// The round's transactions were created and submitted.
        case submitted
        /// The round's transactions were mined; the next round, if any, starts now.
        case confirmed
    }

    /// The round, from 1.
    public let round: Int
    /// Where the round stands.
    public let phase: Phase
    /// The ids of the round's transactions.
    public let txIds: [Data]
    /// The spendable notes the card holds beyond this round; `0` once it is swept.
    public let remainingNotes: Int
    /// The value of ``remainingNotes``, before fees.
    public let remainingValue: Zatoshi
}

/// Whether a round's transactions are mined, expired, or neither yet.
enum GiftCardRoundState: Equatable {
    case pending
    case mined
    case expired
}

/// How a redemption waits for a round to be mined.
struct GiftCardRoundTiming {
    /// How long a round may stay unmined before the redemption gives up on it.
    let roundTimeout: TimeInterval
    /// How often a pending round's transactions are checked.
    let pollInterval: TimeInterval
    /// The current time, in seconds.
    let now: () -> TimeInterval
    /// Suspends for the given number of seconds.
    let sleep: (TimeInterval) async throws -> Void

    /// A round is given 50 minutes, the 40-block expiry delta with a margin, and checked every
    /// 15 seconds.
    static let live = GiftCardRoundTiming(
        roundTimeout: 50 * 60,
        pollInterval: 15,
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    )
}

/// Redeems a gift card in one or more rounds, each one claim transaction held to a size bound.
///
/// A card funded with many small notes can need more inputs than one transaction may spend within
/// the bound (or a block). Redeeming it then takes rounds: each sends the most that fits, waits
/// for that round's transactions to be mined, and proposes again over the notes left. The notes a
/// round leaves behind are never touched by it, so waiting is for detecting a rejection and
/// keeping the mempool clean, not for availability; and because librustzcash never selects the
/// inputs of an unmined, unexpired transaction again, an interrupted redemption can simply be
/// started over.
///
/// Sending only what fits needs librustzcash to propose a send-max within a size bound, which the
/// pinned version does not yet do, so `sendWhatFits` is off in the SDK (see
/// `GiftCardRedeemer.sendWhatFits`). With it off there is exactly one round: a card whose sweep
/// exceeds the bound fails with ``ZcashError/giftCardTooManyNotes`` before anything is created or
/// broadcast.
struct GiftCardRedeemRounds<RoundProposal> {
    /// One round's proposal and what it leaves on the card.
    struct Round {
        let proposal: RoundProposal
        /// The spendable notes the proposal leaves behind; `0` when it sweeps the card.
        let remainingNotes: Int
        /// The value of those notes, before fees.
        let remainingValue: Zatoshi

        init(proposal: RoundProposal, remainingNotes: Int, remainingValue: Zatoshi = .zero) {
            self.proposal = proposal
            self.remainingNotes = remainingNotes
            self.remainingValue = remainingValue
        }
    }

    /// What one round created, submitted and recorded.
    struct Outcome: Equatable {
        let results: [TransactionSubmitResult]
        let recordedInDestination: Bool
        let fee: Zatoshi
        let amount: Zatoshi

        /// Whether a server accepted every transaction of the round.
        var allAccepted: Bool {
            !results.isEmpty && results.allSatisfy {
                if case .success = $0 { return true }
                return false
            }
        }
    }

    /// Whether a round may send only part of the card and leave the rest to later rounds.
    let sendWhatFits: Bool
    /// The most rounds one redemption runs, however many notes remain.
    let maxRounds: Int
    let timing: GiftCardRoundTiming
    /// Proposes the next round; with `sendWhatFits`, the most of the card that fits the bound.
    let propose: (_ sendWhatFits: Bool) async throws -> Round
    /// Creates, submits and records a round's transactions.
    let complete: (RoundProposal) async throws -> Outcome
    /// Reads whether the given transactions are mined, expired, or neither yet.
    let roundState: ([Data]) async throws -> GiftCardRoundState
    /// Receives each round's progress.
    let progress: (RedeemProgress) -> Void

    /// Proposes the first round. A card that needs more than one transaction, while rounds are
    /// unavailable, fails here with ``ZcashError/giftCardTooManyNotes``.
    func proposeFirst() async throws -> Round {
        do {
            return try await propose(sendWhatFits)
        } catch ZcashError.rustProposalTransactionTooLarge {
            throw ZcashError.giftCardTooManyNotes
        }
    }

    /// Runs the redemption from its first round, `first`, to the last, and returns every round's
    /// outcome in order.
    ///
    /// A first round that a server did not accept ends the redemption with that round's results,
    /// as a single-transaction redemption always has. A later round that a server did not accept
    /// throws ``ZcashError/giftCardRoundFailed(_:_:)``, and a round not mined before it expires or
    /// times out throws ``ZcashError/giftCardRoundExpired(_:_:)``; both carry the ids of every
    /// transaction sent so far. The redemption also stops once the card is swept or `maxRounds`
    /// have run.
    func run(startingWith first: Round) async throws -> [Outcome] {
        var outcomes: [Outcome] = []
        var sent: [Data] = []
        var round = first
        while true {
            let number = outcomes.count + 1
            let outcome = try await complete(round.proposal)
            let txIds = outcome.results.map(\.txId)
            sent += txIds
            outcomes.append(outcome)
            guard outcome.allAccepted else {
                guard number == 1 else { throw ZcashError.giftCardRoundFailed(number, sent) }
                return outcomes
            }
            report(round, number: number, phase: .submitted, txIds: txIds)
            guard sendWhatFits, round.remainingNotes > 0, outcomes.count < maxRounds else {
                return outcomes
            }
            try await awaitMined(round: number, txIds: txIds, sent: sent)
            report(round, number: number, phase: .confirmed, txIds: txIds)
            do {
                round = try await propose(sendWhatFits)
            } catch ZcashError.giftCardNothingToRedeem {
                // What remained was dust: the rounds so far are the whole redemption.
                return outcomes
            }
        }
    }

    private func report(_ round: Round, number: Int, phase: RedeemProgress.Phase, txIds: [Data]) {
        progress(RedeemProgress(
            round: number,
            phase: phase,
            txIds: txIds,
            remainingNotes: round.remainingNotes,
            remainingValue: round.remainingValue
        ))
    }

    /// Polls the round's transactions until they are mined; an expiry or the round timeout throws.
    private func awaitMined(round: Int, txIds: [Data], sent: [Data]) async throws {
        let deadline = timing.now() + timing.roundTimeout
        while true {
            try Task.checkCancellation()
            switch try await roundState(txIds) {
            case .mined:
                return
            case .expired:
                throw ZcashError.giftCardRoundExpired(round, sent)
            case .pending:
                guard timing.now() < deadline else { throw ZcashError.giftCardRoundExpired(round, sent) }
                try await timing.sleep(timing.pollInterval)
            }
        }
    }
}

extension TransactionSubmitResult {
    /// The id of the transaction this result is about.
    var txId: Data {
        switch self {
        case let .success(txId),
            let .grpcFailure(txId, _),
            let .submitFailure(txId, _, _),
            let .notAttempted(txId):
            return txId
        }
    }
}

extension GiftCardRedeemer {
    /// Whether a redemption may claim only the part of a card that fits its size bound and finish
    /// in further rounds. Off until librustzcash can propose a send-max within a size bound; until
    /// then a card that needs more than one claim transaction fails with
    /// ``ZcashError/giftCardTooManyNotes`` and nothing is broadcast.
    static let sendWhatFits = false

    /// The most claim transactions one redemption sends. A card's issuer keeps cards well below
    /// what this many rounds can sweep.
    static let maxRounds = 8

    /// Whether every transaction in `txIds` is mined, any of them expired unmined, or neither yet,
    /// as the card wallet's `transactions` record them. A transaction the wallet does not list yet
    /// is pending.
    static func roundState(of txIds: [Data], in transactions: [ZcashTransaction.Overview]) -> GiftCardRoundState {
        let byId = Dictionary(transactions.map { ($0.rawID, $0) }, uniquingKeysWith: { first, _ in first })
        let round = txIds.map { byId[$0] }
        if round.contains(where: { $0?.minedHeight == nil && $0?.isExpiredUmined == true }) {
            return .expired
        }
        return round.allSatisfy { $0?.minedHeight != nil } ? .mined : .pending
    }
}

/// Delivers redemption progress to every current ``GiftCardRedeemer/redeemProgress()`` stream.
final class GiftCardProgressBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<RedeemProgress>.Continuation] = [:]

    func stream() -> AsyncStream<RedeemProgress> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    func send(_ progress: RedeemProgress) {
        lock.lock()
        let current = Array(continuations.values)
        lock.unlock()
        current.forEach { $0.yield(progress) }
    }

    func finish() {
        lock.lock()
        let current = Array(continuations.values)
        continuations = [:]
        lock.unlock()
        current.forEach { $0.finish() }
    }
}

extension GiftCardRedeemer.Redemption {
    /// The redemption the rounds of a claim add up to: every round's results in order, the fees
    /// and amounts summed, and recorded only when every round was.
    init(rounds: [GiftCardRedeemRounds<Proposal>.Outcome]) throws {
        guard let first = rounds.first else { throw ZcashError.giftCardRedemptionIncomplete }
        self.init(
            results: rounds.flatMap(\.results),
            recordedInDestination: rounds.allSatisfy(\.recordedInDestination),
            fee: rounds.dropFirst().reduce(first.fee) { $0 + $1.fee },
            amount: rounds.dropFirst().reduce(first.amount) { $0 + $1.amount }
        )
    }
}
