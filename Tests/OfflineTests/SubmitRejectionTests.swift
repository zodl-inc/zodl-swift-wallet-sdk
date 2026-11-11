//
//  SubmitRejectionTests.swift
//  ZODLSwiftWalletSDK
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class SubmitRejectionTests: XCTestCase {
    private let zakuraTooLarge = "transaction is 260001 bytes, exceeding the configured mempool maximum of 250000"
    private let zebraTooLarge = "transaction has 90 actions, exceeding the next block's ZIP 218 limit of 75"

    // MARK: - Classifier (the same lists as the Android SDK)

    func testASizeLimitRefusalUnderAVerificationCodeIsTooLarge() {
        XCTAssertEqual(SubmitRejection(code: -25, message: zakuraTooLarge), .tooLarge)
        XCTAssertEqual(SubmitRejection(code: -25, message: zebraTooLarge), .tooLarge)
        XCTAssertEqual(SubmitRejection(code: -25, message: zakuraTooLarge.uppercased()), .tooLarge)
        XCTAssertEqual(SubmitRejection(code: -26, message: zebraTooLarge), .tooLarge)
        XCTAssertEqual(SubmitRejection(code: -26, message: "16: bad-txns-oversize"), .tooLarge, "too large before invalid")
    }

    func testASizeLimitTextUnderAnotherCodeIsInconclusive() {
        XCTAssertNil(SubmitRejection(code: -1, message: zakuraTooLarge))
        XCTAssertNil(SubmitRejection(code: -1, message: zebraTooLarge))
    }

    func testTextsOnNoNodesListAreInconclusive() {
        // Not a zcashd or Zebra message: dropped from the lists.
        XCTAssertNil(SubmitRejection(code: -26, message: "64: tx-size"))
        XCTAssertNil(SubmitRejection(code: -25, message: "transaction is too large"))
        XCTAssertNil(SubmitRejection(code: -26, message: "16: bad-txns-vin-empty"))
        XCTAssertNil(SubmitRejection(code: -26, message: "bad-txns-sapling-binding-signature-invalid"))
        XCTAssertNil(SubmitRejection(code: -26, message: "transaction is invalid"), "a bare \"invalid\" is not terminal")
    }

    func testAnExpiryRefusalUnderAVerificationCodeIsExpired() {
        XCTAssertEqual(SubmitRejection(code: -26, message: "16: tx-overwinter-expired"), .expired)
        XCTAssertEqual(SubmitRejection(code: -25, message: "tx-expiring-soon"), .expired)
        XCTAssertEqual(SubmitRejection(code: -25, message: "transaction has expired"), .expired)
        XCTAssertEqual(
            SubmitRejection(code: -25, message: "transaction must not be mined at a block Height(100) greater than its expiry Height(90)"),
            .expired
        )
    }

    func testAnExpiryTextUnderAnotherCodeIsInconclusive() {
        XCTAssertNil(SubmitRejection(code: -1, message: "tx-overwinter-expired"))
        XCTAssertNil(SubmitRejection(code: 0, message: "greater than its expiry"))
    }

    func testSignatureProofAndStructuralRefusalsAreInvalid() {
        let invalid = [
            "16: bad-txns-invalid-joinsplit-signature",
            "16: bad-txns-joinsplit-verification-failed",
            "16: bad-txns-sapling-bundle-invalid",
            "16: bad-sapling-bundle-authorization",
            "16: bad-orchard-bundle-authorization",
            "16: bad-txns-vout-negative",
            "16: bad-txns-vout-toolarge",
            "16: bad-txns-txouttotal-toolarge",
            "16: bad-txns-txintotal-toolarge",
            "16: mandatory-script-verify-flag-failed (Script evaluated without error but finished with a false/empty top stack element)",
            "16: bad-txns-no-source-of-funds",
            "16: bad-txns-no-sink-of-funds",
            "Sapling bindingSig MUST represent a valid signature under the transaction binding validating key bvk of SigHash: x",
            "Orchard bindingSig MUST represent a valid signature under the transaction binding validating key bvk of SigHash: x",
            "spend proof MUST be valid given a primary input formed from the other fields except spendAuthSig: x",
            "Groth16 proof is malformed: x",
            "Sapling proof or signature verification failed",
            "Orchard or Ironwood Halo2 proof verification failed",
            "Orchard proof has a non-canonical size"
        ]
        for message in invalid {
            XCTAssertEqual(SubmitRejection(code: -26, message: message), .invalid, message)
            XCTAssertEqual(SubmitRejection(code: -25, message: message), .invalid, "Zebra refuses under -25: \(message)")
            XCTAssertNil(SubmitRejection(code: -1, message: message), "only under a verification code: \(message)")
        }
    }

    /// The reproduced refusal: a server that has not reached the wallet's anchor yet can accept the
    /// same transaction once it catches up, so it never stops resubmission.
    func testAnUnknownAnchorRefusalIsInconclusive() {
        XCTAssertNil(SubmitRejection(code: -26, message: "16: bad-txns-orchard-unknown-anchor"))
        XCTAssertNil(SubmitRejection(code: -26, message: "16: bad-txns-sapling-unknown-anchor"))
        XCTAssertNil(SubmitRejection(code: -26, message: "16: bad-txns-sprout-unknown-anchor"))
        XCTAssertNil(SubmitRejection(code: -25, message: "bad-txns-orchard-unknown-anchor"))
        XCTAssertEqual(SubmitRefusal(code: -26, message: "16: bad-txns-orchard-unknown-anchor"), .inconclusive)
    }

    func testStateDependentRefusalsAreInconclusive() {
        let inconclusive = [
            "16: bad-tx-version-group-id",
            "16: bad-nu5-tx-version-group-id",
            "16: bad-tx-expiry-height-too-high",
            "16: bad-tx-too-many-orchard-actions",
            "16: bad-tx-consensus-branch-id-mismatch",
            "16: bad-tx-zip225-version-too-low",
            "18: bad-txns-orchard-duplicate-nullifier",
            "18: bad-txns-sapling-duplicate-nullifier",
            "18: bad-txns-inputs-spent",
            "16: bad-txns-inputs-missingorspent",
            "18: txn-mempool-conflict",
            "Missing inputs",
            "66: min relay fee not met",
            "66: insufficient fee",
            "66: mempool min fee not met",
            "mempool full",
            "64: too-long-mempool-chain",
            "64: non-final",
            "16: bad-txns-nonfinal",
            "16: bad-txns-fee-negative",
            "bad",
            "something new",
            ""
        ]
        for message in inconclusive {
            XCTAssertNil(SubmitRejection(code: -26, message: message), message)
            XCTAssertNil(SubmitRejection(code: -25, message: message), message)
            XCTAssertNotEqual(SubmitRefusal(code: -26, message: message), .accepted, message)
        }
    }

    func testARefusalSayingTheServerHoldsTheTransactionIsAnAcceptance() {
        let held = [
            (-26, "18: txn-already-in-mempool"),
            (-26, "txn-already-known"),
            (-27, "transaction already in block chain"),
            (-1, "transaction already exists in mempool"),
            (-25, "Transaction ALREADY EXISTS IN MEMPOOL")
        ]
        for (code, message) in held {
            XCTAssertEqual(SubmitRefusal(code: code, message: message), .accepted, message)
            XCTAssertTrue(SubmitRefusal.meansAccepted(code: code, message: message), message)
            XCTAssertNil(SubmitRejection(code: code, message: message), message)
            XCTAssertTrue(EndpointSubmission.refused(code: code, message: message).isAcceptance, message)
        }
    }

    func testOtherRefusalsAreInconclusive() {
        XCTAssertNil(SubmitRejection(code: -25, message: "Missing inputs"))
        XCTAssertNil(SubmitRejection(code: -1, message: "connection reset"))
        XCTAssertNil(SubmitRejection(code: 0, message: ""))
        XCTAssertEqual(SubmitRefusal(code: -1, message: "connection reset"), .inconclusive)
    }

    func testASubmitResultReportsItsRejection() {
        let txId = Data(repeating: 1, count: 32)
        XCTAssertEqual(TransactionSubmitResult.submitFailure(txId: txId, code: -25, description: zebraTooLarge).rejection, .tooLarge)
        XCTAssertNil(TransactionSubmitResult.submitFailure(txId: txId, code: -25, description: "Missing inputs").rejection)
        XCTAssertNil(TransactionSubmitResult.success(txId: txId).rejection)
        XCTAssertNil(TransactionSubmitResult.notAttempted(txId: txId).rejection)
    }

    func testASubmissionOutcomeReportsItsRejection() {
        XCTAssertEqual(TransactionSubmissionOutcome.rejected(code: -26, message: "bad-txns-vout-negative").rejection, .invalid)
        XCTAssertNil(TransactionSubmissionOutcome.unreachable.rejection)
        XCTAssertNil(TransactionSubmissionOutcome.timedOut.rejection)
    }

    func testARejectedPlanReportsItsKindAsTheSubmissionStatus() {
        XCTAssertEqual(StoredSubmitPlan.rejected(code: -25, reason: zakuraTooLarge).submissionStatus, .rejected(.tooLarge))
        XCTAssertEqual(StoredSubmitPlan.rejected(code: -26, reason: "bad-txns-vout-negative").submissionStatus, .rejected(.invalid))
        XCTAssertEqual(StoredSubmitPlan.rejected(code: 0, reason: "").submissionStatus, .rejected(.invalid))
    }

    // MARK: - Verdict against the stored plan

    private let endpointA = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
    private let endpointB = LightWalletEndpoint(address: "b.example.com", port: 9067, secure: true)
    private var terminal: EndpointSubmission { .refused(code: -26, message: "bad-txns-vout-negative") }
    private var transient: EndpointSubmission { .refused(code: -25, message: "Missing inputs") }

    func testEveryPlanEndpointRefusingTerminallyIsRejected() {
        let verdict = submitRejectionVerdict(
            planEndpoints: [endpointA, endpointB],
            outcomes: [endpointKey(endpointA): terminal, endpointKey(endpointB): .refused(code: -25, message: zakuraTooLarge)],
            previous: nil
        )
        XCTAssertEqual(verdict, StoredRejection(code: -26, reason: "bad-txns-vout-negative"), "the first refusal in plan order is recorded")
    }

    func testOneExplicitRejectionWithAnUnansweredEndpointStaysPending() {
        XCTAssertNil(
            submitRejectionVerdict(planEndpoints: [endpointA, endpointB], outcomes: [endpointKey(endpointA): terminal], previous: nil),
            "an endpoint that has not answered may still accept it"
        )
        let previous = StoredRejection(code: -25, reason: zakuraTooLarge)
        XCTAssertEqual(
            submitRejectionVerdict(planEndpoints: [endpointA, endpointB], outcomes: [endpointKey(endpointA): terminal], previous: previous),
            previous,
            "no new rejection is drawn; an earlier one merely stands"
        )
    }

    func testOneExplicitRejectionWithATransientRefusalStaysPending() {
        XCTAssertNil(
            submitRejectionVerdict(
                planEndpoints: [endpointA, endpointB],
                outcomes: [endpointKey(endpointA): transient, endpointKey(endpointB): terminal],
                previous: nil
            ),
            "a refusal that may be transient keeps it pending beside a terminal one"
        )
        let previous = StoredRejection(code: -25, reason: zakuraTooLarge)
        XCTAssertEqual(
            submitRejectionVerdict(
                planEndpoints: [endpointA, endpointB],
                outcomes: [endpointKey(endpointA): terminal, endpointKey(endpointB): transient],
                previous: previous
            ),
            previous,
            "no new rejection is drawn; an earlier one merely stands"
        )
    }

    /// A size refusal from one endpoint and a mempool-chain refusal from the other, in either plan
    /// order: the second may clear on a later attempt, so the transaction stays pending.
    func testATooLargeRefusalBesideAMempoolChainRefusalStaysPendingInEitherOrder() {
        let tooLarge = EndpointSubmission.refused(code: -25, message: "tx size exceeding the configured mempool maximum")
        let chain = EndpointSubmission.refused(code: -26, message: "too-long-mempool-chain")
        for plan in [[endpointA, endpointB], [endpointB, endpointA]] {
            XCTAssertNil(submitRejectionVerdict(
                planEndpoints: plan,
                outcomes: [endpointKey(endpointA): tooLarge, endpointKey(endpointB): chain],
                previous: nil
            ))
            XCTAssertNil(submitRejectionVerdict(
                planEndpoints: plan,
                outcomes: [endpointKey(endpointA): chain, endpointKey(endpointB): tooLarge],
                previous: nil
            ))
        }
    }

    func testALocalRefusalBesideATerminalOneStaysPending() {
        XCTAssertNil(submitRejectionVerdict(
            planEndpoints: [endpointA, endpointB],
            outcomes: [endpointKey(endpointA): terminal, endpointKey(endpointB): .refused(code: -9101, message: "not submittable")],
            previous: nil
        ))
    }

    func testARefusalOutsideThePlanThatMayBeTransientKeepsItPending() {
        XCTAssertNil(submitRejectionVerdict(
            planEndpoints: [endpointA],
            outcomes: [endpointKey(endpointA): terminal, endpointKey(endpointB): transient],
            previous: nil
        ))
    }

    func testAnExplicitRejectionBesideATransportFailureStaysPending() {
        XCTAssertNil(
            submitRejectionVerdict(
                planEndpoints: [endpointA, endpointB],
                outcomes: [endpointKey(endpointA): terminal, endpointKey(endpointB): .failed],
                previous: nil
            ),
            "a transport failure may hide an acceptance whose reply was lost"
        )
        let previous = StoredRejection(code: -25, reason: zakuraTooLarge)
        XCTAssertEqual(
            submitRejectionVerdict(
                planEndpoints: [endpointA, endpointB],
                outcomes: [endpointKey(endpointA): terminal, endpointKey(endpointB): .failed],
                previous: previous
            ),
            previous,
            "no new rejection is drawn; an earlier one merely stands"
        )
    }

    func testAnInconclusiveEndpointReconcilesOnItsNextExplicitAnswer() {
        XCTAssertNil(
            submitRejectionVerdict(
                planEndpoints: [endpointA, endpointB],
                outcomes: [endpointKey(endpointA): terminal, endpointKey(endpointB): .accepted],
                previous: nil
            ),
            "a later acceptance by the inconclusive endpoint clears it"
        )
        XCTAssertEqual(
            submitRejectionVerdict(
                planEndpoints: [endpointA, endpointB],
                outcomes: [endpointKey(endpointA): terminal, endpointKey(endpointB): .refused(code: -25, message: zakuraTooLarge)],
                previous: nil
            ),
            StoredRejection(code: -26, reason: "bad-txns-vout-negative"),
            "a later explicit refusal by the inconclusive endpoint completes the verdict"
        )
    }

    func testWithoutAnExplicitRejectionItStaysPending() {
        XCTAssertNil(submitRejectionVerdict(
            planEndpoints: [endpointA, endpointB],
            outcomes: [endpointKey(endpointA): transient, endpointKey(endpointB): .failed],
            previous: nil
        ))
        XCTAssertNil(submitRejectionVerdict(planEndpoints: [endpointA], outcomes: [:], previous: nil))
    }

    func testAnEndpointThatAlreadyHoldsTheTransactionIsAnAcceptance() {
        let held = EndpointSubmission.refused(code: -26, message: "18: txn-already-in-mempool")
        XCTAssertNil(
            submitRejectionVerdict(
                planEndpoints: [endpointA, endpointB],
                outcomes: [endpointKey(endpointA): held, endpointKey(endpointB): terminal],
                previous: StoredRejection(code: -26, reason: "bad-txns-vout-negative")
            ),
            "an endpoint holding the transaction clears any rejection"
        )
    }

    func testAnUnknownAnchorRefusalNeverRejects() {
        let anchor = EndpointSubmission.refused(code: -26, message: "16: bad-txns-orchard-unknown-anchor")
        XCTAssertNil(submitRejectionVerdict(planEndpoints: [endpointA], outcomes: [endpointKey(endpointA): anchor], previous: nil))
        XCTAssertNil(submitRejectionVerdict(
            planEndpoints: [endpointA, endpointB],
            outcomes: [endpointKey(endpointA): anchor, endpointKey(endpointB): .refused(code: -26, message: "16: bad-txns-sapling-unknown-anchor")],
            previous: nil
        ))
    }

    func testARejectionWithAnAcceptanceIsNeverRejected() {
        XCTAssertNil(submitRejectionVerdict(
            planEndpoints: [endpointA, endpointB],
            outcomes: [endpointKey(endpointA): terminal, endpointKey(endpointB): .accepted],
            previous: StoredRejection(code: -26, reason: "bad-txns-vout-negative")
        ))
    }

    func testAnEarlierRejectionStandsUntilAnAcceptance() {
        let previous = StoredRejection(code: -25, reason: zakuraTooLarge)
        XCTAssertEqual(submitRejectionVerdict(planEndpoints: [endpointA], outcomes: [endpointKey(endpointA): .failed], previous: previous), previous)
        XCTAssertEqual(
            submitRejectionVerdict(planEndpoints: [endpointA], outcomes: [endpointKey(endpointA): terminal], previous: previous),
            StoredRejection(code: -26, reason: "bad-txns-vout-negative"),
            "the latest explicit rejection is recorded"
        )
    }

    func testARefusalFromAnEndpointOutsideThePlanStillCounts() {
        XCTAssertEqual(
            submitRejectionVerdict(planEndpoints: [], outcomes: [endpointKey(endpointA): terminal], previous: nil),
            StoredRejection(code: -26, reason: "bad-txns-vout-negative")
        )
    }
}
