//
//  SendMaxProposalErrorTests.swift
//  OfflineTests
//

import XCTest
@testable import ZODLSwiftWalletSDK

/// The mapping from a classified rust failure to the `ZcashError` a send-max, or any other
/// proposal or transaction-creation call, throws.
final class SendMaxProposalErrorTests: XCTestCase {
    private func report(_ kind: RustErrorKind, available: Zatoshi? = nil, required: Zatoshi? = nil) -> RedactedRustError {
        RedactedRustError(kind: kind, message: "redacted", available: available, required: required)
    }

    // MARK: - Send-max categories

    func testSendMaxScanRequired() {
        XCTAssertEqual(sendMaxProposalError(for: report(.scanRequired)), .rustProposalScanRequired)
    }

    func testSendMaxInsufficientFundsCarriesItsAmounts() {
        let error = sendMaxProposalError(
            for: report(.insufficientFunds, available: Zatoshi(9_000), required: Zatoshi(10_001))
        )

        XCTAssertEqual(error, .rustProposalInsufficientFunds(Zatoshi(9_000), Zatoshi(10_001)))
    }

    func testSendMaxTransactionTooLarge() {
        XCTAssertEqual(sendMaxProposalError(for: report(.transactionTooLarge)), .rustProposalTransactionTooLarge)
    }

    func testSendMaxTransparentMemo() {
        XCTAssertEqual(sendMaxProposalError(for: report(.transparentMemo)), .rustProposalTransparentMemo)
    }

    func testSendMaxUnsupportedAddress() {
        XCTAssertEqual(sendMaxProposalError(for: report(.noSupportedReceivers)), .rustProposalUnsupportedAddress)
    }

    func testSendMaxOtherFailuresKeepTheRedactedReport() {
        for kind in [RustErrorKind.unclassified, .dataSourceFailed, .proposalInvalid, .invalidRecipient] {
            let failure = report(kind)

            XCTAssertEqual(sendMaxProposalError(for: failure), .rustProposeSendMaxTransfer(failure), "\(kind)")
        }
    }

    /// An insufficient-funds report that lost its amounts cannot become the amount-carrying case.
    func testSendMaxInsufficientFundsWithoutAmountsIsNotTyped() {
        let failure = report(.insufficientFunds)

        XCTAssertEqual(sendMaxProposalError(for: failure), .rustProposeSendMaxTransfer(failure))
    }

    // MARK: - Every proposal and creation call

    /// A transaction too large for a block is typed when a transfer is proposed, too. Building
    /// transactions never reports this kind: the rust layer classifies build failures as it always has.
    func testTransactionTooLargeIsTypedWhenProposingATransfer() {
        let error = proposalError(for: report(.transactionTooLarge)) { .rustProposeTransfer($0) }

        XCTAssertEqual(error, .rustProposalTransactionTooLarge)
    }

    /// Building transactions reports an oversized proposal as an invalid proposal, so it keeps the
    /// call site's own case, as it always has.
    func testAnInvalidProposalAtBuildTimeKeepsItsCase() {
        let failure = report(.proposalInvalid)

        XCTAssertEqual(proposalError(for: failure) { .rustCreateToAddress($0) }, .rustCreateToAddress(failure))
    }

    /// The send-max-only categories stay with their call site's case elsewhere.
    func testSendMaxOnlyCategoriesAreNotTypedOnOtherPaths() {
        for kind in [RustErrorKind.transparentMemo, .noSupportedReceivers] {
            let failure = report(kind)

            XCTAssertEqual(proposalError(for: failure) { .rustProposeTransfer($0) }, .rustProposeTransfer(failure), "\(kind)")
        }
    }

    // MARK: - Codes and messages

    func testNewCasesHaveTheirOwnCodesAndNoDetail() {
        let cases: [(ZcashError, String)] = [
            (.rustProposalTransactionTooLarge, "ZRUST0159"),
            (.rustProposalTransparentMemo, "ZRUST0160"),
            (.rustProposalUnsupportedAddress, "ZRUST0161")
        ]

        for (error, code) in cases {
            XCTAssertEqual(error.code.rawValue, code)
            XCTAssertNil(error.detail)
            XCTAssertTrue(error.localizedDescription.hasPrefix("\(code): "))
        }
    }

    func testRustErrorKindDecodesTheNewDiscriminants() {
        XCTAssertEqual(RustErrorKind(ffiValue: 21), .anchorNotFound)
        XCTAssertEqual(RustErrorKind(ffiValue: 22), .transactionTooLarge)
        XCTAssertEqual(RustErrorKind(ffiValue: 23), .transparentMemo)
        XCTAssertEqual(RustErrorKind(ffiValue: 24), .unclassified)
    }
}
