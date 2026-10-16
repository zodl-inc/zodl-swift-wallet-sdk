//
//  GiftCardRedeemRounds.swift
//  ZODLSwiftWalletSDK
//

import Combine
import Foundation

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
    /// Proposes the next round; with `sendWhatFits`, the most of the card that fits the bound.
    let propose: (_ sendWhatFits: Bool) async throws -> Round
    /// Creates, submits and records a round's transactions.
    let complete: (RoundProposal) async throws -> Outcome
    /// Returns once every transaction in the given ids is mined.
    let awaitMined: ([Data]) async throws -> Void

    /// Proposes the first round. A card that needs more than one transaction, while rounds are
    /// unavailable, fails here with ``ZcashError/giftCardTooManyNotes``.
    func proposeFirst() async throws -> Round {
        try await proposeRound()
    }

    /// Runs the redemption from its first round, `first`, to the last, and returns every round's
    /// outcome in order.
    ///
    /// The redemption stops after a round any of whose transactions a server did not accept: the
    /// inputs of that round stay reserved until it expires, and the caller reports the round's
    /// results. It also stops once the card is swept or `maxRounds` have run.
    func run(startingWith first: Round) async throws -> [Outcome] {
        var outcomes: [Outcome] = []
        var round = first
        while true {
            let outcome = try await complete(round.proposal)
            outcomes.append(outcome)
            guard sendWhatFits, round.remainingNotes > 0, outcome.allAccepted, outcomes.count < maxRounds else {
                return outcomes
            }
            try await awaitMined(outcome.results.map(\.txId))
            do {
                round = try await proposeRound()
            } catch ZcashError.giftCardNothingToRedeem {
                // What remained was dust: the rounds so far are the whole redemption.
                return outcomes
            }
        }
    }

    private func proposeRound() async throws -> Round {
        do {
            return try await propose(sendWhatFits)
        } catch ZcashError.rustProposalTransactionTooLarge {
            throw ZcashError.giftCardTooManyNotes
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

    /// Returns once a `.minedTransaction` event has been seen for every id in `txIds`.
    static func awaitMined(_ txIds: [Data], events: AnyPublisher<SynchronizerEvent, Never>) async throws {
        guard !txIds.isEmpty else { return }
        let waiter = GiftCardMinedWaiter(txIds: Set(txIds))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiter.start(events: events, continuation: continuation)
            }
        } onCancel: {
            waiter.cancel()
        }
    }
}

/// Waits, without `AsyncSequence` (unavailable before iOS 15), for a set of transactions to be
/// reported mined, resuming its continuation exactly once.
private final class GiftCardMinedWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Set<Data>
    private var continuation: CheckedContinuation<Void, Error>?
    private var subscription: AnyCancellable?
    private var isFinished = false

    init(txIds: Set<Data>) {
        pending = txIds
    }

    func start(events: AnyPublisher<SynchronizerEvent, Never>, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
        let subscription = events.sink { [weak self] event in
            guard case let .minedTransaction(transaction) = event else { return }
            self?.mined(transaction.rawID)
        }
        lock.lock()
        if isFinished {
            lock.unlock()
            subscription.cancel()
        } else {
            self.subscription = subscription
            lock.unlock()
        }
    }

    func cancel() {
        finish(with: CancellationError())
    }

    private func mined(_ txId: Data) {
        lock.lock()
        pending.remove(txId)
        let done = pending.isEmpty
        lock.unlock()
        if done { finish(with: nil) }
    }

    private func finish(with error: Error?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        let subscription = self.subscription
        self.continuation = nil
        self.subscription = nil
        lock.unlock()
        subscription?.cancel()
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
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
