import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class GiftCardRecipientTests: ZcashTestCase {
    // Published mainnet vectors are validated by Rust rather than relabelled as testnet.
    private func noOrchardRecipient() throws -> UnifiedAddress {
        let address = try UnifiedAddress(
            encoding: """
            u1l9f0l4348negsncgr9pxd9d3qaxagmqv3lnexcplmufpq7muffvfaue6ksevfvd7wrz7xrvn95rc5zjtn7ugkmgh5rnxswmcj30y0pw52pn0zjvy38rn2esfgve64rj5pcmazxg\
            pyuj
            """,
            network: .mainnet
        )
        XCTAssertEqual(Set(try address.availableReceiverTypecodes()), Set([.sapling, .p2pkh]))
        return address
    }

    private func multiReceiverRecipient() throws -> UnifiedAddress {
        let vector = try XCTUnwrap(TestVector.testVectors?.first)
        let address = try UnifiedAddress(encoding: XCTUnwrap(vector.unified_addr), network: .mainnet)
        XCTAssertEqual(Set(try address.availableReceiverTypecodes()), Set([.orchard, .sapling, .p2pkh]))
        return address
    }

    private func withFixture(
        cardLink: String = GiftCardTests.legacyV3Link,
        spendableValue: Zatoshi = Zatoshi(50_000),
        _ body: (GiftCardCancellationFixture) async throws -> Void
    ) async throws {
        let fixture = try await GiftCardCancellationFixture.make(
            storageDirectory: testTempDirectory,
            cardLink: cardLink,
            spendableValue: spendableValue
        )
        do {
            try await body(fixture)
        } catch {
            try await fixture.redeemer.cleanup()
            throw error
        }
        try await fixture.redeemer.cleanup()
    }

    private func assertErrorCode(
        _ code: String,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected error \(code)", file: file, line: line)
        } catch let error as ZcashError {
            XCTAssertEqual(error.code.rawValue, code, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error.localizedDescription)", file: file, line: line)
        }
    }

    // Removing the shared receiver guard would construct and submit both of these claims.
    func testBothRedeemOverloadsRejectRecipientWithoutOrchardBeforeProposal() async throws {
        let recipient = try noOrchardRecipient()
        try await withFixture { fixture in
            _ = try await fixture.redeemer.check()
            let callsBeforeRedemption = fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeCallsCount
            let destination = SynchronizerMock()
            await assertErrorCode("ZGIFT0013") {
                _ = try await fixture.redeemer.redeem(to: recipient, memo: nil)
            }
            await assertErrorCode("ZGIFT0013") {
                _ = try await fixture.redeemer.redeem(to: recipient, memo: nil, recordIn: destination)
            }
            XCTAssertEqual(fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeCallsCount, callsBeforeRedemption)
            XCTAssertTrue(fixture.backend.createProposedTransactionsProposalUskOvkPolicyCallsCount == 0)
            XCTAssertTrue(fixture.service.submitSpendTransactionModeCallsCount == 0)
        }
    }

    // Synthetic orchestration fixture: fees are injected, not calculated by the native backend.
    // Without receiver validation, a ready Orchard preview could precede an unaffordable claim.
    func testUnsupportedRecipientCannotConsumeAnOrchardPreviewWithDifferentFee() async throws {
        let recipient = try noOrchardRecipient()
        try await withFixture(spendableValue: Zatoshi(15_000)) { fixture in
            fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeClosure = { _, _, _, _ in
                FfiProposalFixtures.makeProposal(steps: [FfiProposalFixtures.Step(inputValues: [15_000], changeValues: [], fee: 10_000)]).inner
            }
            let status = try await fixture.redeemer.check()
            XCTAssertEqual(status.state, .ready)
            XCTAssertEqual(status.spendable, Zatoshi(15_000))
            XCTAssertEqual(status.fee, Zatoshi(10_000))
            XCTAssertEqual(status.redeemable, Zatoshi(5_000))
            XCTAssertEqual(
                fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeReceivedArguments?.address,
                fixture.card.fundingAddress.stringEncoded
            )

            fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeClosure = { _, _, _, _ in
                throw ZcashError.rustProposalInsufficientFunds(Zatoshi(15_000), Zatoshi(20_000))
            }
            await assertErrorCode("ZGIFT0013") {
                _ = try await fixture.redeemer.redeem(to: recipient, memo: nil, recordIn: nil)
            }
            XCTAssertEqual(
                fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeCallsCount,
                1,
                "the unsupported recipient must never reach its actual proposal"
            )
            XCTAssertTrue(fixture.backend.createProposedTransactionsProposalUskOvkPolicyCallsCount == 0)
            XCTAssertTrue(fixture.service.submitSpendTransactionModeCallsCount == 0)
        }
    }

    // Rejecting all UAs, rewriting the recipient or dropping the memo would fail this test.
    func testOrchardOnlyRecipientIsForwardedWithMemo() async throws {
        try await withFixture { fixture in
            XCTAssertEqual(try fixture.card.fundingAddress.availableReceiverTypecodes(), [.orchard])
            _ = try await fixture.redeemer.check()
            let results = try await fixture.redeemer.redeem(to: fixture.card.fundingAddress, memo: Memo(string: "Gift card"))
            XCTAssertEqual(results, [.success(txId: Data(repeating: 0xA1, count: 32))])
            let call = try XCTUnwrap(fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeReceivedArguments)
            XCTAssertEqual(call.address, fixture.card.fundingAddress.stringEncoded)
            XCTAssertEqual(try call.memo?.intoMemo(), try Memo(string: "Gift card"))
            XCTAssertEqual(fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeCallsCount, 2)
            XCTAssertEqual(fixture.backend.createProposedTransactionsProposalUskOvkPolicyCallsCount, 1)
            XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 1)
        }
    }

    // A singleton-equality guard would reject this valid Orchard + Sapling + transparent UA.
    func testMultiReceiverOrchardRecipientIsAcceptedUnchanged() async throws {
        let recipient = try multiReceiverRecipient()
        try await withFixture { fixture in
            _ = try await fixture.redeemer.check()
            let result = try await fixture.redeemer.redeem(to: recipient, memo: Memo(string: "Multiple receivers"), recordIn: nil)
            XCTAssertEqual(result.results, [.success(txId: Data(repeating: 0xA1, count: 32))])
            XCTAssertEqual(result.fee, Zatoshi(10_000))
            XCTAssertEqual(result.amount, Zatoshi(40_000))
            let call = try XCTUnwrap(fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeReceivedArguments)
            XCTAssertEqual(call.address, recipient.stringEncoded)
            XCTAssertEqual(try call.memo?.intoMemo(), try Memo(string: "Multiple receivers"))
            XCTAssertEqual(fixture.backend.createProposedTransactionsProposalUskOvkPolicyCallsCount, 1)
            XCTAssertEqual(fixture.service.submitSpendTransactionModeCallsCount, 1)
        }
    }

    // Moving receiver validation ahead of lifecycle or network guards changes these errors.
    func testRecipientValidationPreservesNetworkNotReadyAndCleanedErrorPrecedence() async throws {
        let recipient = try noOrchardRecipient()
        try await withFixture(cardLink: GiftCardTests.zodlTestnetLink) { fixture in
            await assertErrorCode("ZGIFT0003") {
                _ = try await fixture.redeemer.redeem(to: recipient, memo: nil, recordIn: nil)
            }
            _ = try await fixture.redeemer.check()
            await assertErrorCode("ZGIFT0001") {
                _ = try await fixture.redeemer.redeem(to: recipient, memo: nil)
            }
            try await fixture.redeemer.cleanup()
            await assertErrorCode("ZGIFT0005") {
                _ = try await fixture.redeemer.redeem(to: recipient, memo: nil, recordIn: nil)
            }
            XCTAssertEqual(fixture.backend.proposeSendMaxTransferAccountUUIDToMemoModeCallsCount, 1)
            XCTAssertTrue(fixture.backend.createProposedTransactionsProposalUskOvkPolicyCallsCount == 0)
            XCTAssertTrue(fixture.service.submitSpendTransactionModeCallsCount == 0)
        }
    }

    // A payload carrying caller input would expose the address through reflection or reports.
    func testRecipientRequiresOrchardErrorDoesNotExposeInput() async throws {
        let recipient = try noOrchardRecipient()
        try await withFixture { fixture in
            _ = try await fixture.redeemer.check()
            do {
                _ = try await fixture.redeemer.redeem(to: recipient, memo: nil)
                XCTFail("Expected recipient rejection")
            } catch let error as ZcashError {
                XCTAssertEqual(error.code.rawValue, "ZGIFT0013")
                XCTAssertTrue(Mirror(reflecting: error).children.isEmpty, "the error must not carry caller input")
                XCTAssertNil(error.detail)
                XCTAssertFalse(error.message.contains(recipient.stringEncoded))
                XCTAssertFalse(error.localizedDescription.contains(recipient.stringEncoded))
                XCTAssertFalse(String(reflecting: error).contains(recipient.stringEncoded))
            }
        }
    }
}
