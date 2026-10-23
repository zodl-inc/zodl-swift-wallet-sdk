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

    // MARK: - Classifier (the same table as the Android SDK)

    func testAMempoolMaximumOrZip218RefusalOnMinus25IsTooLarge() {
        XCTAssertEqual(SubmitRejection(code: -25, message: zakuraTooLarge), .tooLarge)
        XCTAssertEqual(SubmitRejection(code: -25, message: zebraTooLarge), .tooLarge)
        XCTAssertEqual(SubmitRejection(code: -25, message: zakuraTooLarge.uppercased()), .tooLarge)
    }

    func testTheSizeTextsUnderAnotherCodeAreNotTooLarge() {
        XCTAssertNil(SubmitRejection(code: -1, message: zakuraTooLarge))
        XCTAssertNil(SubmitRejection(code: -1, message: zebraTooLarge))
        XCTAssertEqual(SubmitRejection(code: -26, message: zebraTooLarge), .invalid)
    }

    func testAnExpiryRefusalOnAVerificationCodeIsExpired() {
        XCTAssertEqual(SubmitRejection(code: -26, message: "tx-overwinter-expired"), .expired)
        XCTAssertEqual(SubmitRejection(code: -25, message: "tx-expiring-soon"), .expired)
        XCTAssertEqual(SubmitRejection(code: -25, message: "block height 100 is greater than its expiry height 90"), .expired)
    }

    func testAnExpiryTextUnderAnotherCodeIsTransient() {
        XCTAssertNil(SubmitRejection(code: -1, message: "tx-overwinter-expired"))
        XCTAssertNil(SubmitRejection(code: 0, message: "greater than its expiry"))
    }

    func testAnyOtherMinus26RefusalIsInvalid() {
        XCTAssertEqual(SubmitRejection(code: -26, message: "bad-txns-sapling-binding-signature-invalid"), .invalid)
        XCTAssertEqual(SubmitRejection(code: -26, message: ""), .invalid)
    }

    func testTransientMinus26RefusalsAreNotTerminal() {
        XCTAssertNil(SubmitRejection(code: -26, message: "mempool full"))
        XCTAssertNil(SubmitRejection(code: -26, message: "txn-already-in-mempool"))
        XCTAssertNil(SubmitRejection(code: -26, message: "transaction already in chain"))
    }

    func testOtherRefusalsAreTransient() {
        XCTAssertNil(SubmitRejection(code: -25, message: "Missing inputs"))
        XCTAssertNil(SubmitRejection(code: -1, message: "connection reset"))
        XCTAssertNil(SubmitRejection(code: 0, message: ""))
    }

    func testASubmitResultReportsItsRejection() {
        let txId = Data(repeating: 1, count: 32)
        XCTAssertEqual(TransactionSubmitResult.submitFailure(txId: txId, code: -25, description: zebraTooLarge).rejection, .tooLarge)
        XCTAssertNil(TransactionSubmitResult.submitFailure(txId: txId, code: -25, description: "Missing inputs").rejection)
        XCTAssertNil(TransactionSubmitResult.success(txId: txId).rejection)
        XCTAssertNil(TransactionSubmitResult.notAttempted(txId: txId).rejection)
    }

    func testASubmissionOutcomeReportsItsRejection() {
        XCTAssertEqual(TransactionSubmissionOutcome.rejected(code: -26, message: "bad").rejection, .invalid)
        XCTAssertNil(TransactionSubmissionOutcome.unreachable.rejection)
        XCTAssertNil(TransactionSubmissionOutcome.timedOut.rejection)
    }

    func testARejectedPlanReportsItsKindAsTheSubmissionStatus() {
        XCTAssertEqual(StoredSubmitPlan.rejected(code: -25, reason: zakuraTooLarge).submissionStatus, .rejected(.tooLarge))
        XCTAssertEqual(StoredSubmitPlan.rejected(code: -26, reason: "bad").submissionStatus, .rejected(.invalid))
        XCTAssertEqual(StoredSubmitPlan.rejected(code: 0, reason: "").submissionStatus, .rejected(.invalid))
    }

    // MARK: - Verdict against the stored plan

    private let endpointA = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
    private let endpointB = LightWalletEndpoint(address: "b.example.com", port: 9067, secure: true)
    private var terminal: EndpointSubmission { .refused(code: -26, message: "bad") }
    private var transient: EndpointSubmission { .refused(code: -25, message: "Missing inputs") }

    func testEveryPlanEndpointRefusingTerminallyIsRejected() {
        let verdict = submitRejectionVerdict(
            planEndpoints: [endpointA, endpointB],
            outcomes: [endpointKey(endpointA): terminal, endpointKey(endpointB): .refused(code: -25, message: zakuraTooLarge)],
            previous: nil
        )
        XCTAssertEqual(verdict, StoredRejection(code: -26, reason: "bad"), "the first refusal in plan order is recorded")
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

    func testOneExplicitRejectionWithATransientRefusalIsRejected() {
        XCTAssertEqual(
            submitRejectionVerdict(
                planEndpoints: [endpointA, endpointB],
                outcomes: [endpointKey(endpointA): transient, endpointKey(endpointB): terminal],
                previous: nil
            ),
            StoredRejection(code: -26, reason: "bad")
        )
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
            StoredRejection(code: -26, reason: "bad"),
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

    func testARejectionWithAnAcceptanceIsNeverRejected() {
        XCTAssertNil(submitRejectionVerdict(
            planEndpoints: [endpointA, endpointB],
            outcomes: [endpointKey(endpointA): terminal, endpointKey(endpointB): .accepted],
            previous: StoredRejection(code: -26, reason: "bad")
        ))
    }

    func testAnEarlierRejectionStandsUntilAnAcceptance() {
        let previous = StoredRejection(code: -25, reason: zakuraTooLarge)
        XCTAssertEqual(submitRejectionVerdict(planEndpoints: [endpointA], outcomes: [endpointKey(endpointA): .failed], previous: previous), previous)
        XCTAssertEqual(
            submitRejectionVerdict(planEndpoints: [endpointA], outcomes: [endpointKey(endpointA): terminal], previous: previous),
            StoredRejection(code: -26, reason: "bad"),
            "the latest explicit rejection is recorded"
        )
    }

    func testARefusalFromAnEndpointOutsideThePlanStillCounts() {
        XCTAssertEqual(
            submitRejectionVerdict(planEndpoints: [], outcomes: [endpointKey(endpointA): terminal], previous: nil),
            StoredRejection(code: -26, reason: "bad")
        )
    }
}
