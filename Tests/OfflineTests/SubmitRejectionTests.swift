//
//  SubmitRejectionTests.swift
//  ZODLSwiftWalletSDK
//

import Combine
import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class SubmitRejectionTests: XCTestCase {
    private let tooLargeText = "transaction is 260001 bytes, exceeding the configured mempool maximum of 250000"

    func testAMempoolSizeRefusalIsTooLarge() {
        XCTAssertEqual(SubmitRejection(code: -25, message: tooLargeText), .tooLarge)
        XCTAssertEqual(SubmitRejection(code: -25, message: tooLargeText.uppercased()), .tooLarge)
    }

    func testTheMempoolTextUnderAnotherCodeIsNotTooLarge() {
        XCTAssertNil(SubmitRejection(code: -1, message: tooLargeText))
        XCTAssertEqual(SubmitRejection(code: -26, message: tooLargeText), .invalid)
    }

    func testAnExpiryRefusalIsExpired() {
        XCTAssertEqual(SubmitRejection(code: -26, message: "tx-overwinter-expired"), .expired)
        XCTAssertEqual(SubmitRejection(code: -25, message: "transaction is expiring soon"), .expired)
        XCTAssertEqual(SubmitRejection(code: -1, message: "Transaction Expired"), .expired)
    }

    func testAnyOtherVerificationRejectionIsInvalid() {
        XCTAssertEqual(SubmitRejection(code: -26, message: "bad-txns-sapling-binding-signature-invalid"), .invalid)
    }

    func testTransientRefusalsAreNotTerminal() {
        XCTAssertNil(SubmitRejection(code: -25, message: "Missing inputs"))
        XCTAssertNil(SubmitRejection(code: -1, message: "connection reset"))
        XCTAssertNil(SubmitRejection(code: 0, message: ""))
    }

    func testASubmitResultReportsItsRejection() {
        let txId = Data(repeating: 1, count: 32)
        XCTAssertEqual(TransactionSubmitResult.submitFailure(txId: txId, code: -25, description: tooLargeText).rejection, .tooLarge)
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
        XCTAssertEqual(StoredSubmitPlan.rejected(code: -25, reason: tooLargeText).submissionStatus, .rejected(.tooLarge))
        XCTAssertEqual(StoredSubmitPlan.rejected(code: -26, reason: "bad").submissionStatus, .rejected(.invalid))
        XCTAssertEqual(StoredSubmitPlan.rejected(code: 0, reason: "").submissionStatus, .rejected(.invalid))
    }

    func testASingleEndpointRefusalIsRecordedOnlyWhenTerminal() async {
        let store = SubmitPlanStoringMock()
        let terminal = Data(repeating: 2, count: 32)
        let transient = Data(repeating: 3, count: 32)
        let lifecycle = await store.currentLifecycle()

        await store.recordSingleEndpointRefusal(txId: terminal, code: -26, reason: "bad", lifecycle: lifecycle)
        await store.recordSingleEndpointRefusal(txId: transient, code: -25, reason: "Missing inputs", lifecycle: lifecycle)

        let terminalPlan = await store.plan(for: terminal)
        let transientPlan = await store.plan(for: transient)
        XCTAssertEqual(terminalPlan, .rejected(code: -26, reason: "bad"))
        XCTAssertNil(transientPlan)
    }
}
