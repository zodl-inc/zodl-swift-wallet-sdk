//
//  VotingRoundTypes.swift
//  ZcashLightClientKit
//

import Foundation

// The round plan and run report a session answers with, mirroring the
// `zcash_voting::wire` views field for field. Every enum decodes an
// unrecognised value as `unknown` rather than failing: the crate's own views
// are open, and a host that cannot name a new kind must still read the rest of
// the payload.

// MARK: - Steps

/// Cross-stage workflow phase of a delegation, vote, or share record.
public enum VotingWorkflowPhase: String, Equatable, Sendable, Decodable {
    case prepared
    case signed
    case submittedDelegation = "submitted_delegation"
    case submittedVote = "submitted_vote"
    case submittedShare = "submitted_share"
    case submissionManaged = "submission_managed"
    case submissionRejected = "submission_rejected"
    case confirmed
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingWorkflowPhase(rawValue: raw) ?? .unknown
    }
}

/// High-level work area a wallet should show or resume for a round.
public enum VotingRoundPlanAction: String, Equatable, Sendable, Decodable {
    case idle
    case delegate
    case vote
    case submitShares = "submit_shares"
    case done
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingRoundPlanAction(rawValue: raw) ?? .unknown
    }
}

/// What one planned step does.
public enum VotingNextStepKind: String, Equatable, Sendable, Decodable {
    case delegate
    case advanceDelegation = "advance_delegation"
    case advanceImportedDelegation = "advance_imported_delegation"
    case castVote = "cast_vote"
    case advanceVote = "advance_vote"
    case advanceVoteBatch = "advance_vote_batch"
    case submitShares = "submit_shares"
    case confirmShare = "confirm_share"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingNextStepKind(rawValue: raw) ?? .unknown
    }
}

/// One step the driver selected, with the identity it applies to.
///
/// Only the fields a `kind` names are meaningful; the rest are zero.
public struct VotingNextStep: Equatable, Sendable, Decodable {
    public let kind: VotingNextStepKind
    public let bundleIndex: UInt32
    public let proposalId: UInt32
    public let choice: UInt32
    public let shareIndex: UInt32

    private enum CodingKeys: String, CodingKey {
        case kind
        case bundleIndex = "bundle_index"
        case proposalId = "proposal_id"
        case choice
        case shareIndex = "share_index"
    }
}

/// Durable identity of one helper share.
public struct VotingShareKey: Equatable, Sendable, Decodable {
    public let bundleIndex: UInt32
    public let proposalId: UInt32
    public let shareIndex: UInt32

    public init(bundleIndex: UInt32, proposalId: UInt32, shareIndex: UInt32) {
        self.bundleIndex = bundleIndex
        self.proposalId = proposalId
        self.shareIndex = shareIndex
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIndex = "bundle_index"
        case proposalId = "proposal_id"
        case shareIndex = "share_index"
    }
}

/// Durable identity of one committed vote.
public struct VotingVoteKey: Equatable, Sendable, Decodable {
    public let bundleIndex: UInt32
    public let proposalId: UInt32

    public init(bundleIndex: UInt32, proposalId: UInt32) {
        self.bundleIndex = bundleIndex
        self.proposalId = proposalId
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIndex = "bundle_index"
        case proposalId = "proposal_id"
    }
}

// MARK: - Chain submission

/// How one chain submission ended.
public enum VotingChainOutcomeKind: String, Equatable, Sendable, Decodable {
    case confirmed
    case tracking
    case recovering
    case submittedWithoutHash = "submitted_without_hash"
    case rejected
    case cancelled
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingChainOutcomeKind(rawValue: raw) ?? .unknown
    }
}

/// Category of a chain submission diagnostic.
///
/// A host branches on this kind; `VotingChainSubmissionOutcome.diagnosticMessage`
/// is bounded, redacted text meant for display only and must never be parsed
/// or pattern-matched to decide what happened.
public enum VotingChainDiagnosticKind: String, Equatable, Sendable, Decodable {
    case ambiguousDispatch = "ambiguous_dispatch"
    case ambiguousAttemptsExhausted = "ambiguous_attempts_exhausted"
    case nullifierAlreadySpent = "nullifier_already_spent"
    case trackingWindowExpired = "tracking_window_expired"
    case chainRejected = "chain_rejected"
    case reconciliationPending = "reconciliation_pending"
    case invalidProtocolResponse = "invalid_protocol_response"
    case storageFailure = "storage_failure"
    case endpointUnsupported = "endpoint_unsupported"
    case routeAnswerReplaced = "route_answer_replaced"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingChainDiagnosticKind(rawValue: raw) ?? .unknown
    }
}

/// Flat view of one chain submission result.
///
/// `diagnosticMessage` is the bounded, redacted text of the crate's nested
/// diagnostic: it is what a host shows for the terminal outcomes
/// (``VotingChainOutcomeKind/submittedWithoutHash`` and
/// ``VotingChainOutcomeKind/rejected``), which schedule no further work.
/// `diagnosticKind` is present alongside it for the same outcomes: branch on
/// the kind, never on the message text.
public struct VotingChainSubmissionOutcome: Equatable, Sendable, Decodable {
    public let kind: VotingChainOutcomeKind
    /// How a confirmation was established: `hash` or `tree`.
    public let confirmationSource: String?
    public let transactionHash: String?
    public let candidateTransactionHash: String?
    public let finalVanPosition: UInt64?
    public let voteCommitmentPositions: [UInt64]
    public let diagnosticKind: VotingChainDiagnosticKind?
    public let diagnosticMessage: String?

    private enum CodingKeys: String, CodingKey {
        case kind
        case confirmationSource = "confirmation_source"
        case transactionHash = "transaction_hash"
        case candidateTransactionHash = "candidate_transaction_hash"
        case finalVanPosition = "final_van_position"
        case voteCommitmentPositions = "vote_commitment_positions"
        case diagnostic
    }

    /// The nested diagnostic: both its kind and its message cross into Swift.
    private struct Diagnostic: Decodable {
        let kind: VotingChainDiagnosticKind
        let message: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(VotingChainOutcomeKind.self, forKey: .kind)
        confirmationSource = try container.decodeIfPresent(String.self, forKey: .confirmationSource)
        transactionHash = try container.decodeIfPresent(String.self, forKey: .transactionHash)
        candidateTransactionHash = try container.decodeIfPresent(String.self, forKey: .candidateTransactionHash)
        finalVanPosition = try container.decodeIfPresent(UInt64.self, forKey: .finalVanPosition)
        voteCommitmentPositions = try container.decodeIfPresent([UInt64].self, forKey: .voteCommitmentPositions) ?? []
        let diagnostic = try container.decodeIfPresent(Diagnostic.self, forKey: .diagnostic)
        diagnosticKind = diagnostic?.kind
        diagnosticMessage = diagnostic?.message
    }
}

// MARK: - Plan

/// One proposal's recorded choice, absent when the voter skipped it.
public struct VotingCompletedVoteChoice: Equatable, Sendable, Decodable {
    public let proposalId: UInt32
    public let choice: UInt32?

    public init(proposalId: UInt32, choice: UInt32?) {
        self.proposalId = proposalId
        self.choice = choice
    }

    private enum CodingKeys: String, CodingKey {
        case proposalId = "proposal_id"
        case choice
    }
}

/// What a finished round shows the voter.
public struct VotingCompletedVoteDisplay: Equatable, Sendable, Decodable {
    public let choices: [VotingCompletedVoteChoice]
    public let votedAt: UInt64?

    private enum CodingKeys: String, CodingKey {
        case choices
        case votedAt = "voted_at"
    }
}

/// Durable state of one bundle's delegation.
public struct VotingDelegationStatus: Equatable, Sendable, Decodable {
    public let bundleIndex: UInt32
    public let phase: VotingWorkflowPhase
    public let txHash: String?
    /// True when this bundle's delegation ended without a confirmation and no
    /// further delegation step will be planned for it. Read this rather than
    /// inferring from `phase`: a dispatch that reached the chain without a
    /// usable transaction hash reports the same phase as a healthy submission,
    /// and retrying it would resubmit.
    public let terminal: Bool

    private enum CodingKeys: String, CodingKey {
        case bundleIndex = "bundle_index"
        case phase
        case txHash = "tx_hash"
        case terminal
    }

    // `terminal` is `#[serde(default)]` upstream: a payload that predates the
    // field must still decode, and its absence means "not terminal".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIndex = try container.decode(UInt32.self, forKey: .bundleIndex)
        phase = try container.decode(VotingWorkflowPhase.self, forKey: .phase)
        txHash = try container.decodeIfPresent(String.self, forKey: .txHash)
        terminal = try container.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
    }
}

/// What a round owes and what a host should show for it.
///
/// The derived flags are the crate's own: read them instead of matching step
/// kinds, because the planner computes them from an exhaustive match and a new
/// step kind cannot silently read as "no work".
public struct VotingRoundPlan: Equatable, Sendable, Decodable {
    public let roundId: String
    public let pendingRecovery: Bool
    public let blockingRecovery: Bool
    public let blockingShareWork: Bool
    /// True while any helper-share row is unconfirmed. Schedule background
    /// share tracking from this rather than from held share rows.
    public let hasUnconfirmedShares: Bool
    public let hotkeyBound: Bool
    public let completedForDisplay: Bool
    public let completedVoteDisplay: VotingCompletedVoteDisplay?
    public let needsDraftSetup: Bool
    /// True when the round holds a ballot choice but no bundle rows yet, so
    /// the bundle plan must be persisted before any vote work is planned.
    public let needsBundleSetup: Bool
    /// True when delegation work needs fresh or restored signing material.
    public let needsDelegationSigning: Bool
    /// True when a delegation is in flight. `needsDelegationSigning` says
    /// whether the next pass also needs signing material.
    public let hasInFlightDelegation: Bool
    /// Bundles this plan owes any delegation step for, ascending.
    public let delegationBundlesNeedingWork: [UInt32]
    /// Bundles whose delegation still needs the voter's signing material,
    /// ascending: a subset of `delegationBundlesNeedingWork`.
    public let delegationBundlesNeedingSigning: [UInt32]
    public let needsVotePolling: Bool
    /// True when vote or share work remains, counting share confirmation only
    /// when it is blocking.
    public let hasRemainingVoteOrShareWork: Bool
    /// True when vote or share work remains, counting share confirmation
    /// unconditionally.
    public let hasRecoverableVoteOrShareWork: Bool
    public let primaryAction: VotingRoundPlanAction
    public let delegationStatuses: [VotingDelegationStatus]
    /// Proposals with no terminal decision yet.
    public let openProposals: [UInt32]
    /// Durable intents for proposals outside the authenticated roster; casting
    /// is withheld until the host clears them.
    public let unrosteredIntents: [UInt32]
    public let immediateShareConfirmed: Bool
    public let allDecided: Bool
    /// True when the round holds a delegation or a vote this wallet built that
    /// an older SDK dispatched and never saw confirmed.
    ///
    /// Upgrading a wallet migrates its voting database in place and keeps
    /// every row, but it does not hand such a transaction to the chain
    /// lifecycle this SDK drives, which owns only the submissions it reserved
    /// itself. Running the round anyway plans an advance step and re-dispatches
    /// the same transaction — rebuilt from its persisted inputs and re-signed
    /// over the stored sighash, so the bytes need not be identical — and
    /// nothing is promised about how that ends, so treat the round as
    /// display-only: show what it recorded and do not drive it. Share tracking
    /// is unaffected.
    ///
    /// A delegation imported from a capability package is deliberately not
    /// covered. Its transaction was broadcast elsewhere and this wallet holds
    /// no key that could re-sign it, so the lifecycle adopts the hash and
    /// never dispatches anything again: such a round reports `false` and is
    /// driven normally.
    ///
    /// Reported by ``VotingRoundSession/plan()``,
    /// ``VotingRoundSession/setBallotIntents(_:)`` and
    /// ``VotingRustBackend/roundPlan(roundId:proposalIds:)``. The plans
    /// embedded in run reports and in the event stream do not carry it and
    /// decode as `false`, so gate on a plan read from one of those three.
    public let hasLegacyInFlightSubmission: Bool

    private enum CodingKeys: String, CodingKey {
        case roundId = "round_id"
        case pendingRecovery = "pending_recovery"
        case blockingRecovery = "blocking_recovery"
        case blockingShareWork = "blocking_share_work"
        case hasUnconfirmedShares = "has_unconfirmed_shares"
        case hotkeyBound = "hotkey_bound"
        case completedForDisplay = "completed_for_display"
        case completedVoteDisplay = "completed_vote_display"
        case needsDraftSetup = "needs_draft_setup"
        case needsBundleSetup = "needs_bundle_setup"
        case needsDelegationSigning = "needs_delegation_signing"
        case hasInFlightDelegation = "has_in_flight_delegation"
        case delegationBundlesNeedingWork = "delegation_bundles_needing_work"
        case delegationBundlesNeedingSigning = "delegation_bundles_needing_signing"
        case needsVotePolling = "needs_vote_polling"
        case hasRemainingVoteOrShareWork = "has_remaining_vote_or_share_work"
        case hasRecoverableVoteOrShareWork = "has_recoverable_vote_or_share_work"
        case primaryAction = "primary_action"
        case delegationStatuses = "delegation_statuses"
        case openProposals = "open_proposals"
        case unrosteredIntents = "unrostered_intents"
        case immediateShareConfirmed = "immediate_share_confirmed"
        case allDecided = "all_decided"
        case hasLegacyInFlightSubmission = "has_legacy_in_flight_submission"
    }

    // The three per-bundle lists and `unrosteredIntents` are
    // `#[serde(default)]` upstream: a payload that omits one must still yield a
    // plan, because losing the whole plan over a missing list is the worse
    // failure. Everything else the planner always writes.
    //
    // `hasLegacyInFlightSubmission` is absent for the same reason and defaults
    // the same way: only the three calls its documentation names add it to the
    // plan, and a plan that arrives without it says nothing about a legacy
    // submission rather than failing to decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roundId = try container.decode(String.self, forKey: .roundId)
        pendingRecovery = try container.decode(Bool.self, forKey: .pendingRecovery)
        blockingRecovery = try container.decode(Bool.self, forKey: .blockingRecovery)
        blockingShareWork = try container.decode(Bool.self, forKey: .blockingShareWork)
        hasUnconfirmedShares = try container.decode(Bool.self, forKey: .hasUnconfirmedShares)
        hotkeyBound = try container.decode(Bool.self, forKey: .hotkeyBound)
        completedForDisplay = try container.decode(Bool.self, forKey: .completedForDisplay)
        completedVoteDisplay = try container.decodeIfPresent(VotingCompletedVoteDisplay.self, forKey: .completedVoteDisplay)
        needsDraftSetup = try container.decode(Bool.self, forKey: .needsDraftSetup)
        needsBundleSetup = try container.decode(Bool.self, forKey: .needsBundleSetup)
        needsDelegationSigning = try container.decode(Bool.self, forKey: .needsDelegationSigning)
        hasInFlightDelegation = try container.decode(Bool.self, forKey: .hasInFlightDelegation)
        delegationBundlesNeedingWork = try container.decodeIfPresent([UInt32].self, forKey: .delegationBundlesNeedingWork) ?? []
        delegationBundlesNeedingSigning = try container.decodeIfPresent([UInt32].self, forKey: .delegationBundlesNeedingSigning) ?? []
        needsVotePolling = try container.decode(Bool.self, forKey: .needsVotePolling)
        hasRemainingVoteOrShareWork = try container.decode(Bool.self, forKey: .hasRemainingVoteOrShareWork)
        hasRecoverableVoteOrShareWork = try container.decode(Bool.self, forKey: .hasRecoverableVoteOrShareWork)
        primaryAction = try container.decode(VotingRoundPlanAction.self, forKey: .primaryAction)
        delegationStatuses = try container.decode([VotingDelegationStatus].self, forKey: .delegationStatuses)
        openProposals = try container.decode([UInt32].self, forKey: .openProposals)
        unrosteredIntents = try container.decodeIfPresent([UInt32].self, forKey: .unrosteredIntents) ?? []
        immediateShareConfirmed = try container.decode(Bool.self, forKey: .immediateShareConfirmed)
        allDecided = try container.decode(Bool.self, forKey: .allDecided)
        hasLegacyInFlightSubmission = try container.decodeIfPresent(Bool.self, forKey: .hasLegacyInFlightSubmission) ?? false
    }
}

// MARK: - Share delivery and delegation evidence

/// Delivery result for one share of a helper-share batch.
public struct VotingShareDeliveryOutcome: Equatable, Sendable, Decodable {
    public let shareIndex: UInt32
    /// Helper URLs that accepted this share.
    public let acceptedUrls: [String]
    /// Helper URLs whose acceptance is unconfirmed: the request may or may
    /// not have reached them.
    public let ambiguousUrls: [String]
    /// How many helpers this share targeted.
    public let targetCount: UInt32

    private enum CodingKeys: String, CodingKey {
        case shareIndex = "share_index"
        case acceptedUrls = "accepted_urls"
        case ambiguousUrls = "ambiguous_urls"
        case targetCount = "target_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shareIndex = try container.decode(UInt32.self, forKey: .shareIndex)
        acceptedUrls = try container.decodeIfPresent([String].self, forKey: .acceptedUrls) ?? []
        ambiguousUrls = try container.decodeIfPresent([String].self, forKey: .ambiguousUrls) ?? []
        targetCount = try container.decode(UInt32.self, forKey: .targetCount)
    }
}

/// Result of one initial helper delivery for a confirmed vote.
///
/// Durable evidence a round produced: the shares were delivered even if the
/// step that produced this report went on to fail or the round stopped.
public struct VotingShareBatchDeliveryReport: Equatable, Sendable, Decodable {
    /// The vote this batch of shares belongs to.
    public let vote: VotingVoteKey
    public let deliveries: [VotingShareDeliveryOutcome]
    /// Shares still awaiting a delivery outcome.
    public let pendingShareIndices: [UInt32]
    public let cancelled: Bool
    /// True when the persisted plan predates complete-plan persistence.
    public let legacyBestEffort: Bool

    private enum CodingKeys: String, CodingKey {
        case vote
        case deliveries
        case pendingShareIndices = "pending_share_indices"
        case cancelled
        case legacyBestEffort = "legacy_best_effort"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vote = try container.decode(VotingVoteKey.self, forKey: .vote)
        deliveries = try container.decodeIfPresent([VotingShareDeliveryOutcome].self, forKey: .deliveries) ?? []
        pendingShareIndices = try container.decodeIfPresent([UInt32].self, forKey: .pendingShareIndices) ?? []
        cancelled = try container.decode(Bool.self, forKey: .cancelled)
        legacyBestEffort = try container.decode(Bool.self, forKey: .legacyBestEffort)
    }
}

/// One delegation bundle a round run signed.
///
/// Signed, not submitted: the payload's own `status` is always
/// `ready_for_submission`, which is not a submission state. A signed bundle
/// is not proof that its transaction was ever submitted or confirmed — read
/// `VotingRoundPlan.delegationStatuses` for the durable submission phase, the
/// transaction hash, and whether it is terminal. This type deliberately does
/// not model the raw PCZT bytes or the chain submission payload: a
/// round-session host never submits them itself.
public struct VotingSignedDelegation: Equatable, Sendable, Decodable {
    public let status: String
    public let message: String?
    public let eligibleWeightZatoshi: UInt64
    public let delegatedWeightZatoshi: UInt64
    public let bundleCount: UInt32
    public let bundleIndex: UInt32

    private enum CodingKeys: String, CodingKey {
        case status
        case message
        case eligibleWeightZatoshi = "eligible_weight_zatoshi"
        case delegatedWeightZatoshi = "delegated_weight_zatoshi"
        case bundleCount = "bundle_count"
        case bundleIndex = "bundle_index"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        eligibleWeightZatoshi = try container.decode(UInt64.self, forKey: .eligibleWeightZatoshi)
        delegatedWeightZatoshi = try container.decode(UInt64.self, forKey: .delegatedWeightZatoshi)
        bundleCount = try container.decode(UInt32.self, forKey: .bundleCount)
        bundleIndex = try container.decode(UInt32.self, forKey: .bundleIndex)
    }
}

// MARK: - Run report

/// Why one round run stopped.
public enum VotingRoundQuiescenceKind: String, Equatable, Sendable, Decodable {
    case noWorkLeft = "no_work_left"
    case needsBundleSetup = "needs_bundle_setup"
    case persistedChainTerminal = "persisted_chain_terminal"
    case needsBallot = "needs_ballot"
    case needsDelegationSignatures = "needs_delegation_signatures"
    case backgroundShareWorkOnly = "background_share_work_only"
    case cancelled
    case chainTerminal = "chain_terminal"
    case chainRecoveryStalled = "chain_recovery_stalled"
    case failures
    case passBudgetExhausted = "pass_budget_exhausted"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingRoundQuiescenceKind(rawValue: raw) ?? .unknown
    }
}

/// Why one round run stopped, with the work each reason names.
///
/// Each field is populated only for the kinds that carry it: switch on `kind`
/// and read what that kind names.
public struct VotingRoundQuiescence: Equatable, Sendable, Decodable {
    public let kind: VotingRoundQuiescenceKind
    /// `needsBallot`: proposals with no terminal decision yet.
    public let openProposals: [UInt32]
    /// `needsBallot`: durable intents outside the roster the host must clear.
    public let unrosteredIntents: [UInt32]
    /// `needsDelegationSignatures`: every bundle still awaiting a signature.
    public let bundles: [UInt32]
    /// `backgroundShareWorkOnly`: shares requiring the host's tracking timer.
    public let shares: [VotingShareKey]
    /// `chainTerminal` and `chainRecoveryStalled`: the step and its outcome.
    public let step: VotingNextStep?
    public let chainOutcome: VotingChainSubmissionOutcome?
    /// `passBudgetExhausted`: the work the run left behind.
    public let remaining: [VotingNextStep]

    private enum CodingKeys: String, CodingKey {
        case kind
        case openProposals = "open_proposals"
        case unrosteredIntents = "unrostered_intents"
        case bundles
        case shares
        case step
        case chainOutcome = "chain_outcome"
        case remaining
    }

    // Every list here is `#[serde(default)]` upstream, and each is populated
    // only for the kinds that carry it — so a payload for one kind legitimately
    // omits the others' lists.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(VotingRoundQuiescenceKind.self, forKey: .kind)
        openProposals = try container.decodeIfPresent([UInt32].self, forKey: .openProposals) ?? []
        unrosteredIntents = try container.decodeIfPresent([UInt32].self, forKey: .unrosteredIntents) ?? []
        bundles = try container.decodeIfPresent([UInt32].self, forKey: .bundles) ?? []
        shares = try container.decodeIfPresent([VotingShareKey].self, forKey: .shares) ?? []
        step = try container.decodeIfPresent(VotingNextStep.self, forKey: .step)
        chainOutcome = try container.decodeIfPresent(VotingChainSubmissionOutcome.self, forKey: .chainOutcome)
        remaining = try container.decodeIfPresent([VotingNextStep].self, forKey: .remaining) ?? []
    }
}

/// Ballot progress of one run, measured against what it started owing.
public struct VotingRoundWorkTally: Equatable, Sendable, Decodable {
    public let completedProposals: UInt32
    public let totalProposals: UInt32
    public let remainingObligations: UInt32

    private enum CodingKeys: String, CodingKey {
        case completedProposals = "completed_proposals"
        case totalProposals = "total_proposals"
        case remainingObligations = "remaining_obligations"
    }
}

/// Stable category of a round step failure.
public enum VotingRoundStepFailureKind: String, Equatable, Sendable, Decodable {
    case invalidInput = "invalid_input"
    case insufficientEligibility = "insufficient_eligibility"
    case noSpendableNotes = "no_spendable_notes"
    case busy
    case storage
    case invariantViolation = "invariant_violation"
    case transport
    case `protocol`
    case proofFailed = "proof_failed"
    case signing
    case helperDeliveryIncomplete = "helper_delivery_incomplete"
    case voteEnded = "vote_ended"
    case delegationTargetMismatch = "delegation_target_mismatch"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingRoundStepFailureKind(rawValue: raw) ?? .unknown
    }
}

/// Durable chain submission state, as known when a step failed.
public enum VotingChainSubmissionState: String, Equatable, Sendable, Decodable {
    case submitting
    case tracking
    case recovering
    case submittedWithoutHash = "submitted_without_hash"
    case confirmed
    case rejected
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingChainSubmissionState(rawValue: raw) ?? .unknown
    }
}

/// How strongly a step failure's chain state is known.
public enum VotingChainSubmissionStateEvidence: String, Equatable, Sendable, Decodable {
    /// Read from durable storage: the state is authoritative.
    case durable
    /// Known from an in-flight dispatch that may or may not have reached the
    /// chain; the state is a best guess, not a durable read.
    case knownPossiblyDispatched = "known_possibly_dispatched"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingChainSubmissionStateEvidence(rawValue: raw) ?? .unknown
    }
}

/// The strongest chain state known for a step when it failed, with how
/// strongly that state is known.
public struct VotingChainSubmissionFailureState: Equatable, Sendable, Decodable {
    public let state: VotingChainSubmissionState
    public let evidence: VotingChainSubmissionStateEvidence
}

/// One step failure, with the step it belongs to when the run knows it.
public struct VotingRoundStepFailure: Equatable, Sendable, Decodable {
    public let kind: VotingRoundStepFailureKind
    public let step: VotingNextStep?
    /// The strongest known chain state when this step failed, present only
    /// when the failure followed a chain submission attempt.
    public let strongestChainState: VotingChainSubmissionFailureState?
    public let chainOutcome: VotingChainSubmissionOutcome?
    public let message: String
    /// The plan the run re-read after the failure, when it could read one.
    public let plan: VotingRoundPlan?
    /// Helper delivery reports accumulated before the failure. Durable
    /// evidence: the shares were delivered even though the step went on to
    /// fail.
    public let shareDeliveries: [VotingShareBatchDeliveryReport]
    /// The delegation signed before the failure, for the same reason as
    /// `shareDeliveries`: the bundle is durable and the step produced it.
    public let delegation: VotingSignedDelegation?

    private enum CodingKeys: String, CodingKey {
        case kind
        case step
        case strongestChainState = "strongest_chain_state"
        case chainOutcome = "chain_outcome"
        case message
        case plan
        case shareDeliveries = "share_deliveries"
        case delegation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(VotingRoundStepFailureKind.self, forKey: .kind)
        step = try container.decodeIfPresent(VotingNextStep.self, forKey: .step)
        strongestChainState = try container.decodeIfPresent(
            VotingChainSubmissionFailureState.self,
            forKey: .strongestChainState
        )
        chainOutcome = try container.decodeIfPresent(VotingChainSubmissionOutcome.self, forKey: .chainOutcome)
        message = try container.decode(String.self, forKey: .message)
        plan = try container.decodeIfPresent(VotingRoundPlan.self, forKey: .plan)
        shareDeliveries = try container.decodeIfPresent(
            [VotingShareBatchDeliveryReport].self,
            forKey: .shareDeliveries
        ) ?? []
        delegation = try container.decodeIfPresent(VotingSignedDelegation.self, forKey: .delegation)
    }
}

/// One failure a run isolated, with the bundle it is attributed to.
///
/// Attribution, not isolation: ``VotingFailureIsolation/stopRound`` ends a run
/// without suppressing anything, so ``VotingRoundRunReport/skippedBundles`` is
/// the authoritative list of what was skipped.
public struct VotingRoundStepFailureRecord: Equatable, Sendable, Decodable {
    public let step: VotingNextStep?
    public let bundleIndex: UInt32?
    public let failure: VotingRoundStepFailure

    private enum CodingKeys: String, CodingKey {
        case step
        case bundleIndex = "bundle_index"
        case failure
    }
}

/// One chain outcome the run observed, bound to the step that produced it.
///
/// Not only terminal ones: a submission still tracking appears here too.
public struct VotingRoundChainOutcome: Equatable, Sendable, Decodable {
    public let step: VotingNextStep
    public let outcome: VotingChainSubmissionOutcome
}

/// Everything one round run did.
///
/// This is the authoritative answer for a run; the live event stream is a
/// best-effort narration of the same work and may drop events.
public struct VotingRoundRunReport: Equatable, Sendable, Decodable {
    public let quiescence: VotingRoundQuiescence
    /// The last plan the run read, absent only when it stopped before one.
    public let plan: VotingRoundPlan?
    public let tally: VotingRoundWorkTally
    /// Failures in dispatch order. A non-empty list does not imply a
    /// ``VotingRoundQuiescenceKind/failures`` quiescence: a run can isolate one
    /// bundle and finish the rest.
    public let failures: [VotingRoundStepFailureRecord]
    /// Bundles a failure isolated for the rest of the run.
    public let skippedBundles: [UInt32]
    /// Every chain outcome the run observed, terminal or not.
    public let chainOutcomes: [VotingRoundChainOutcome]
    /// Every helper delivery the run made for a confirmed vote, in dispatch
    /// order. Durable evidence: the shares were delivered even if the round
    /// later hit a failure or stopped.
    public let shareDeliveries: [VotingShareBatchDeliveryReport]
    /// Delegation bundles the run signed, in the order it produced them.
    /// Signed, not necessarily submitted — read `plan.delegationStatuses` for
    /// the durable submission phase, transaction hash, and whether it is
    /// terminal.
    public let delegations: [VotingSignedDelegation]

    private enum CodingKeys: String, CodingKey {
        case quiescence
        case plan
        case tally
        case failures
        case skippedBundles = "skipped_bundles"
        case chainOutcomes = "chain_outcomes"
        case shareDeliveries = "share_deliveries"
        case delegations
    }

    // `failures`, `skippedBundles`, `chainOutcomes`, `shareDeliveries` and
    // `delegations` are `#[serde(default)]` upstream: a clean run may omit
    // all five, and the report is what a host acts on, so it must survive
    // their absence.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quiescence = try container.decode(VotingRoundQuiescence.self, forKey: .quiescence)
        plan = try container.decodeIfPresent(VotingRoundPlan.self, forKey: .plan)
        tally = try container.decode(VotingRoundWorkTally.self, forKey: .tally)
        failures = try container.decodeIfPresent([VotingRoundStepFailureRecord].self, forKey: .failures) ?? []
        skippedBundles = try container.decodeIfPresent([UInt32].self, forKey: .skippedBundles) ?? []
        chainOutcomes = try container.decodeIfPresent([VotingRoundChainOutcome].self, forKey: .chainOutcomes) ?? []
        shareDeliveries = try container.decodeIfPresent(
            [VotingShareBatchDeliveryReport].self,
            forKey: .shareDeliveries
        ) ?? []
        delegations = try container.decodeIfPresent([VotingSignedDelegation].self, forKey: .delegations) ?? []
    }
}
