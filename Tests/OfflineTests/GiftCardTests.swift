//
//  GiftCardTests.swift
//  ZODLSwiftWalletSDK
//

import XCTest
@testable import TestUtils
@testable import ZODLSwiftWalletSDK

final class GiftCardTests: ZcashTestCase {
    /// A published, never-funded reference vector of the legacy `v3` encoding: 32 zero bytes of
    /// entropy, which is the phrase of 23 times "abandon" followed by "art".
    static let legacyV3Payload = [
        "WyJtYWluIiwiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsMzQ4MzE0MSwiMTAwMDAwMCIsImtuaWdodE1hZ2ljIiwx",
        "MS4xNzQ3LCJJdCdzIGEgZ3JlYXQgZGF5IHRvIHNoaWVsZCB5b3VyIFpFQyDwn5uh77iPIl0"
    ].joined()
    static let legacyV3Link = "https://legacy.example/payment-links/open#v3=\(legacyV3Payload)"

    /// The BIP 39 seed (empty passphrase) of the all-zero 256-bit entropy.
    static let legacyV3SeedHex =
        "408b285c123836004f4b8842c89324c1f01382450c0d439af345ba7fc49acf705489c6fc77dbd4e3dc1dd8cc6bc9f043db8ada1e243c4a0eafb290d399480840"

    /// A testnet card in the Zodl format: entropy of 32 bytes of 0x07.
    static let zodlTestnetKey = "zgifttest1qurswpc8qurswpc8qurswpc8qurswpc8qurswpc8qurswpc8qurs98m07r"
    static let zodlTestnetLink = "https://gift.zodl.com/#v=1&key=\(zodlTestnetKey)&height=3000000&amount=0.5&desc=Hi%20there%21"

    // MARK: - Parsing

    func testParsesTheLegacyV3Vector() throws {
        let card = try GiftCard(link: Self.legacyV3Link)

        XCTAssertEqual(card.origin, .legacyV3)
        XCTAssertEqual(card.network, .mainnet)
        XCTAssertEqual(card.birthdayHeight, 3_483_141)
        XCTAssertEqual(card.statedAmount, Zatoshi(1_000_000))
        XCTAssertEqual(card.message, "It's a great day to shield your ZEC 🛡️")
        XCTAssertEqual(card.seed.withBytes { $0 }, [UInt8](try XCTUnwrap(Self.legacyV3SeedHex.hexadecimal)))
        XCTAssertTrue(card.fundingAddress.stringEncoded.hasPrefix("u1"))
        // The funding address is Orchard-only.
        XCTAssertEqual(try card.fundingAddress.availableReceiverTypecodes(), [.orchard])
    }

    func testParsesAZodlTestnetLink() throws {
        // Surrounding whitespace, as a scanner or a paste may add, is ignored.
        let card = try GiftCard(link: "  \(Self.zodlTestnetLink)\n")

        XCTAssertEqual(card.origin, .zodl)
        XCTAssertEqual(card.network, .testnet)
        XCTAssertEqual(card.birthdayHeight, 3_000_000)
        XCTAssertEqual(card.statedAmount, Zatoshi(50_000_000))
        XCTAssertEqual(card.message, "Hi there!")
        XCTAssertEqual(card.seed.count, 64)
        XCTAssertTrue(card.fundingAddress.stringEncoded.hasPrefix("utest1"))
        XCTAssertEqual(try card.fundingAddress.availableReceiverTypecodes(), [.orchard])
    }

    func testTheHostIsNotPartOfTheCard() throws {
        // The fragment carries the card; any `https` URL may serve it.
        let moved = Self.zodlTestnetLink.replacingOccurrences(
            of: "https://gift.zodl.com/",
            with: "HTTPS://Pay.Example.org/claim"
        )
        let card = try GiftCard(link: moved)

        XCTAssertEqual(card.origin, .zodl)
        XCTAssertEqual(card, try GiftCard(link: Self.zodlTestnetLink))
    }

    func testOptionalFieldsMayBeAbsent() throws {
        let card = try GiftCard(link: "https://gift.zodl.com/#v=1&key=\(Self.zodlTestnetKey)&height=3000000")

        XCTAssertNil(card.statedAmount)
        XCTAssertNil(card.message)
    }

    func testTheSeedDerivesTheFundingAccount() throws {
        let card = try GiftCard(link: Self.legacyV3Link)
        let tool = DerivationTool(networkType: card.network)
        let usk = try card.seed.withBytes { try tool.deriveUnifiedSpendingKey(seed: $0, accountIndex: Zip32AccountIndex(0)) }
        let ufvk = try tool.deriveUnifiedFullViewingKey(from: usk)

        XCTAssertFalse(ufvk.stringEncoded.isEmpty)
        XCTAssertEqual(card, try GiftCard(link: Self.legacyV3Link))
    }

    func testRejectsBadLinksWithATypedErrorWithoutEchoingThem() {
        let secretPart = String(Self.zodlTestnetKey.dropFirst(10))
        let key = Self.zodlTestnetKey
        let cases: [(String, ZcashError)] = [
            ("", .giftCardLinkNotAGiftCard),
            // The host is not part of the card, but the link must be an `https` URL.
            ("http://gift.zodl.com/#v=1&key=\(key)&height=3000000", .giftCardLinkNotAGiftCard),
            ("https://gift.zodl.com/#v=2&key=\(key)&height=3000000", .giftCardLinkUnsupportedVersion),
            ("https://gift.zodl.com/#v=1&key=\(key)", .giftCardLinkInvalid),
            ("https://gift.zodl.com/#v=1&key=\(key)x&height=3000000", .giftCardLinkInvalid),
            ("https://gift.zodl.com/#v=1&key=\(key)&height=0", .giftCardLinkInvalidBirthday),
            ("https://gift.zodl.com/#v=1&key=\(key)\u{0}&height=3000000", .giftCardLinkInvalid),
            // A key for an unknown network.
            ("https://gift.zodl.com/#v=1&key=zgiftfoo1qurswpc8qurswpc8qurswpc8qurswpc8qurswpc8qurswpc8qursm37r74&height=3000000", .giftCardLinkUnsupportedNetwork)
        ]

        for (link, expected) in cases {
            XCTAssertThrowsError(try GiftCard(link: link), link) { error in
                guard let error = error as? ZcashError else {
                    return XCTFail("Unexpected error \(error.localizedDescription)")
                }
                XCTAssertEqual(error.code, expected.code, link)
                XCTAssertFalse(error.localizedDescription.contains(secretPart))
                XCTAssertFalse(error.message.contains(secretPart))
            }
        }
    }

    /// Cards hold Orchard funds only, which cannot exist before NU5, so the rust parser refuses a
    /// birthday below NU5 activation: such a link would make the card wallet scan from Sapling
    /// activation, millions of blocks, for funds that cannot be there.
    func testRejectsBirthdaysBelowNU5() throws {
        let testnetNU5 = 1_842_420
        for height in [1, 280_000, 419_199, testnetNU5 - 1] {
            let link = "https://gift.zodl.com/#v=1&key=\(Self.zodlTestnetKey)&height=\(height)"
            XCTAssertThrowsError(try GiftCard(link: link), "\(height)") { error in
                guard case ZcashError.giftCardLinkInvalidBirthday = error else {
                    return XCTFail("Unexpected error \(error.localizedDescription)")
                }
            }
        }

        let atNU5 = try GiftCard(link: "https://gift.zodl.com/#v=1&key=\(Self.zodlTestnetKey)&height=\(testnetNU5)")
        XCTAssertEqual(atNU5.birthdayHeight, testnetNU5)

        // No upper bound applies beyond `u32`: the card wallet compares the height with the tip.
        let far = try GiftCard(link: "https://gift.zodl.com/#v=1&key=\(Self.zodlTestnetKey)&height=4294967295")
        XCTAssertEqual(far.birthdayHeight, 4_294_967_295)
    }

    func testTheMessageIsSanitizedByTheRustLayer() throws {
        // A bidi override, a line feed, BEL and NUL, percent-encoded as a link carries them.
        let link = "https://gift.zodl.com/#v=1&key=\(Self.zodlTestnetKey)&height=3000000&desc=a%E2%80%AEb%0Ac%07d%00e"
        XCTAssertEqual(try GiftCard(link: link).message, "ab cde")

        // A description that is blank once sanitized is absent.
        let blank = "https://gift.zodl.com/#v=1&key=\(Self.zodlTestnetKey)&height=3000000&desc=%E2%80%8B%0A"
        XCTAssertNil(try GiftCard(link: blank).message)
    }

    func testTheSeedIsLentAndWipedButNotPartOfEquality() throws {
        let card = try GiftCard(link: Self.legacyV3Link)
        let expected = [UInt8](try XCTUnwrap(Self.legacyV3SeedHex.hexadecimal))

        let lent = card.seed.withBytes { $0 }
        XCTAssertEqual(lent, expected)
        // Each loan is a fresh copy of the wiped-on-release storage.
        XCTAssertEqual(card.seed.withBytes { $0 }, expected)

        // Equality compares the public fields; the seed object is a different instance per parse.
        let again = try GiftCard(link: Self.legacyV3Link)
        XCTAssertFalse(card.seed === again.seed)
        XCTAssertEqual(card, again)
    }

    // MARK: - Redaction

    func testTextualRepresentationsAreRedacted() throws {
        let card = try GiftCard(link: Self.legacyV3Link)
        let seedBytes = card.seed.withBytes { $0 }
        let seedHex = seedBytes.map { String(format: "%02x", $0) }.joined()

        var dumped = ""
        dump(card, to: &dumped)
        let representations = [
            String(describing: card),
            String(reflecting: card),
            "\(card)",
            dumped,
            String(describing: card.seed),
            "\(Mirror(reflecting: card).children.map { "\($0.label ?? ""): \($0.value)" })"
        ]

        for representation in representations {
            XCTAssertFalse(representation.contains(seedHex), representation)
            XCTAssertFalse(representation.contains("\(seedBytes)"), representation)
        }
        XCTAssertEqual(String(describing: card), "--redacted--")
        XCTAssertEqual(String(describing: card.seed), "--redacted--")
    }

    // MARK: - Alias

    func testAliasIsStablePerCardAndDistinctBetweenCards() throws {
        let legacy = try GiftCard(link: Self.legacyV3Link)
        let zodl = try GiftCard(link: Self.zodlTestnetLink)

        XCTAssertEqual(legacy.synchronizerAlias, try GiftCard(link: Self.legacyV3Link).synchronizerAlias)
        XCTAssertNotEqual(legacy.synchronizerAlias, zodl.synchronizerAlias)
        XCTAssertNotEqual(legacy.synchronizerAlias, .default)

        guard case let .custom(name) = legacy.synchronizerAlias else {
            return XCTFail("A gift card must never use the default alias")
        }
        XCTAssertTrue(name.hasPrefix("giftcard_"))
        XCTAssertEqual(name.count, "giftcard_".count + 16)
        XCTAssertFalse(name.contains(legacy.fundingAddress.stringEncoded))
    }

    // MARK: - Status

    func testStatusClassifiesBalances() {
        func balance(spendable: Int64, pending: Int64) -> AccountBalance {
            AccountBalance(
                saplingBalance: .zero,
                orchardBalance: PoolBalance(
                    spendableValue: Zatoshi(spendable / 2),
                    changePendingConfirmation: .zero,
                    valuePendingSpendability: .zero
                ),
                ironwoodBalance: PoolBalance(
                    spendableValue: Zatoshi(spendable - spendable / 2),
                    changePendingConfirmation: .zero,
                    valuePendingSpendability: Zatoshi(pending)
                ),
                unshielded: .zero
            )
        }

        let sweep = GiftCardStatus.Sweep(fee: Zatoshi(10_000), amount: Zatoshi(1_000_000))
        let ready = GiftCardStatus(balance: balance(spendable: 1_010_000, pending: 0), sweep: sweep)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.spendable, Zatoshi(1_010_000))
        XCTAssertEqual(ready.pending, .zero)
        XCTAssertEqual(ready.fee, Zatoshi(10_000))
        XCTAssertEqual(ready.redeemable, Zatoshi(1_000_000))

        let partly = GiftCardStatus(balance: balance(spendable: 20_000, pending: 500), sweep: GiftCardStatus.Sweep(fee: Zatoshi(10_000), amount: Zatoshi(10_000)))
        XCTAssertEqual(partly.state, .ready)
        XCTAssertEqual(partly.total, Zatoshi(20_500))
        XCTAssertEqual(partly.pending, Zatoshi(500))
        XCTAssertEqual(partly.redeemable, Zatoshi(10_000))

        let pending = GiftCardStatus(balance: balance(spendable: 0, pending: 1_010_000), sweep: nil)
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(pending.spendable, .zero)
        XCTAssertEqual(pending.pending, Zatoshi(1_010_000))
        XCTAssertNil(pending.fee)
        XCTAssertEqual(pending.redeemable, .zero)

        // Spendable funds the fee would take entirely: dust, unless more is on its way.
        let dust = GiftCardStatus(balance: balance(spendable: 10_000, pending: 0), sweep: nil)
        XCTAssertEqual(dust.state, .dust)
        XCTAssertEqual(dust.spendable, Zatoshi(10_000))
        XCTAssertNil(dust.fee)
        XCTAssertEqual(dust.redeemable, .zero)
        let dustAndPending = GiftCardStatus(balance: balance(spendable: 10_000, pending: 500_000), sweep: nil)
        XCTAssertEqual(dustAndPending.state, .pending)
        // A sweep that would send nothing is no sweep at all.
        let zeroSweep = GiftCardStatus(balance: balance(spendable: 10_000, pending: 0), sweep: GiftCardStatus.Sweep(fee: Zatoshi(10_000), amount: .zero))
        XCTAssertEqual(zeroSweep.state, .dust)
        XCTAssertNil(zeroSweep.fee)

        XCTAssertEqual(GiftCardStatus(balance: balance(spendable: 0, pending: 0), sweep: nil).state, .empty)
        XCTAssertEqual(GiftCardStatus(balance: nil, sweep: nil).state, .empty)
    }

    /// The fee and the amount a card reports come from the send-max proposal the redemption makes:
    /// a card holding several notes pays more than the 10,000 zatoshi minimum, and receives less.
    func testSweepIsReadFromTheProposal() {
        let singleNote = FfiProposalFixtures.makeProposal(
            steps: [FfiProposalFixtures.Step(inputValues: [10_010_000], changeValues: [], fee: 10_000)]
        )
        XCTAssertEqual(GiftCardStatus.Sweep(proposal: singleNote), GiftCardStatus.Sweep(fee: Zatoshi(10_000), amount: Zatoshi(10_000_000)))

        let threeNotes = FfiProposalFixtures.makeProposal(
            steps: [FfiProposalFixtures.Step(inputValues: [5_000_000, 3_000_000, 2_010_000], changeValues: [], fee: 15_000)]
        )
        let sweep = GiftCardStatus.Sweep(proposal: threeNotes)
        XCTAssertEqual(sweep.fee, Zatoshi(15_000))
        XCTAssertEqual(sweep.amount, Zatoshi(9_995_000))

        let status = GiftCardStatus(
            balance: AccountBalance(
                saplingBalance: .zero,
                orchardBalance: .zero,
                ironwoodBalance: PoolBalance(spendableValue: Zatoshi(10_010_000), changePendingConfirmation: .zero, valuePendingSpendability: .zero),
                unshielded: .zero
            ),
            sweep: sweep
        )
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.fee, Zatoshi(15_000))
        XCTAssertEqual(status.redeemable, Zatoshi(9_995_000))
    }

    // MARK: - Confirmation policy (ZIP 315)

    /// Card notes come from another wallet, so they are untrusted and need 10 confirmations; the
    /// successfully recorded claim is trusted in the main wallet and needs 3. Both use the transfer policy,
    /// which this pins so that a change to the default cannot loosen either wait unnoticed.
    func testConfirmationPoliciesArePinned() async throws {
        let card = try GiftCard(link: Self.zodlTestnetLink)
        let redeemer = try GiftCardRedeemer(
            card: card,
            network: ZcashNetworkBuilder.network(for: .testnet),
            endpoint: LightWalletEndpointBuilder.default,
            isTorEnabled: false,
            storageDirectory: testTempDirectory
        )

        let fetchedPolicy = await redeemer.cardWalletConfirmationsPolicy()
        let cardPolicy = try XCTUnwrap(fetchedPolicy)
        XCTAssertEqual(cardPolicy.untrusted, 10, "card notes are untrusted: 10 confirmations")
        XCTAssertEqual(cardPolicy.trusted, 3)
        XCTAssertEqual(cardPolicy.toBackend().untrusted, 10)
        XCTAssertEqual(cardPolicy.toBackend().trusted, 3)

        // The destination wallet spends a recorded trusted claim under the same transfer policy.
        let walletPolicy = ConfirmationsPolicy.defaultTransferPolicy()
        XCTAssertEqual(walletPolicy.trusted, 3)
        XCTAssertEqual(walletPolicy.untrusted, 10, "external card funding requires 10 confirmations")

        try await redeemer.cleanup()
    }

    // MARK: - Redeemer lifecycle

    func testRedeemerRefusesACardForAnotherNetwork() throws {
        let card = try GiftCard(link: Self.legacyV3Link)

        XCTAssertThrowsError(
            try GiftCardRedeemer(
                card: card,
                network: ZcashNetworkBuilder.network(for: .testnet),
                endpoint: LightWalletEndpointBuilder.default,
                isTorEnabled: false,
                storageDirectory: testTempDirectory
            )
        ) { error in
            guard case ZcashError.giftCardNetworkMismatch = error else {
                return XCTFail("Unexpected error \(error.localizedDescription)")
            }
        }
    }

    func testOnlyOneRedeemerPerCardIsActiveAndCleanupRemovesItsFiles() async throws {
        let card = try GiftCard(link: Self.zodlTestnetLink)
        let network = ZcashNetworkBuilder.network(for: .testnet)

        let redeemer = try GiftCardRedeemer(
            card: card,
            network: network,
            endpoint: LightWalletEndpointBuilder.default,
            isTorEnabled: false,
            storageDirectory: testTempDirectory
        )
        XCTAssertEqual(redeemer.alias, card.synchronizerAlias)

        XCTAssertThrowsError(
            try GiftCardRedeemer(
                card: card,
                network: network,
                endpoint: LightWalletEndpointBuilder.default,
                isTorEnabled: false,
                storageDirectory: testTempDirectory
            )
        ) { error in
            guard case ZcashError.giftCardRedeemerAlreadyActive = error else {
                return XCTFail("Unexpected error \(error.localizedDescription)")
            }
        }

        // A redeem before `check()` has prepared the card wallet is refused.
        do {
            _ = try await redeemer.redeem(to: card.fundingAddress)
            XCTFail("redeem(to:) must require check()")
        } catch ZcashError.giftCardRedeemerNotReady {
        } catch {
            XCTFail("Unexpected error \(error.localizedDescription)")
        }

        // Leftover files of the card wallet, as a crash could leave them, are all removed.
        let cardDirectory = testTempDirectory.appendingPathComponent(card.synchronizerAlias.description, isDirectory: true)
        try FileManager.default.createDirectory(at: cardDirectory, withIntermediateDirectories: true)
        for leftover in ["c_x_data.db-wal", "c_x_data.db-shm", "c_x_sapling-spend.params"] {
            FileManager.default.createFile(atPath: cardDirectory.appendingPathComponent(leftover).path, contents: Data([1]))
        }

        try await redeemer.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cardDirectory.path))

        // Cleanup is idempotent, and the redeemer is unusable afterwards.
        try await redeemer.cleanup()
        do {
            _ = try await redeemer.check()
            XCTFail("check() must fail after cleanup()")
        } catch ZcashError.giftCardRedeemerCleanedUp {
        } catch {
            XCTFail("Unexpected error \(error.localizedDescription)")
        }

        // The card is free again.
        let next = try GiftCardRedeemer(
            card: card,
            network: network,
            endpoint: LightWalletEndpointBuilder.default,
            isTorEnabled: false,
            storageDirectory: testTempDirectory
        )
        try await next.cleanup()
    }

    func testOldRedeemerDeinitCannotReleaseItsReplacement() async throws {
        let card = try GiftCard(link: Self.zodlTestnetLink)
        let network = ZcashNetworkBuilder.network(for: .testnet)
        var old: GiftCardRedeemer? = try GiftCardRedeemer(
            card: card,
            network: network,
            endpoint: LightWalletEndpointBuilder.default,
            isTorEnabled: false,
            storageDirectory: testTempDirectory
        )
        weak var oldReference = old
        try await old?.cleanup()

        let replacement = try GiftCardRedeemer(
            card: card,
            network: network,
            endpoint: LightWalletEndpointBuilder.default,
            isTorEnabled: false,
            storageDirectory: testTempDirectory
        )
        old = nil
        // The completed cleanup task may briefly retain the old actor until its tail finishes.
        // Wait for its actual release so this tests deinit rather than that temporary retention.
        while oldReference != nil {
            await Task.yield()
        }
        XCTAssertNil(oldReference)

        XCTAssertThrowsError(
            try GiftCardRedeemer(
                card: card,
                network: network,
                endpoint: LightWalletEndpointBuilder.default,
                isTorEnabled: false,
                storageDirectory: testTempDirectory
            )
        ) { error in
            guard case ZcashError.giftCardRedeemerAlreadyActive = error else {
                return XCTFail("Unexpected error \(error.localizedDescription)")
            }
        }

        let directory = testTempDirectory.appendingPathComponent(replacement.alias.description, isDirectory: true)
        let marker = directory.appendingPathComponent("live-wallet-marker")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1]).write(to: marker)
        XCTAssertEqual(try GiftCardRedeemer.removeLeftoverWallets(in: testTempDirectory), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the replacement still owns its wallet")

        try await replacement.cleanup()
        let next = try GiftCardRedeemer(
            card: card,
            network: network,
            endpoint: LightWalletEndpointBuilder.default,
            isTorEnabled: false,
            storageDirectory: testTempDirectory
        )
        try await next.cleanup()
    }

    func testReleasingARedeemerFreesTheCardAfterTeardown() async throws {
        let card = try GiftCard(link: Self.zodlTestnetLink)
        let network = ZcashNetworkBuilder.network(for: .testnet)
        let storageDirectory = try XCTUnwrap(testTempDirectory)
        var redeemer: GiftCardRedeemer? = try GiftCardRedeemer(
            card: card,
            network: network,
            endpoint: LightWalletEndpointBuilder.default,
            isTorEnabled: false,
            storageDirectory: storageDirectory
        )
        XCTAssertNotNil(redeemer)
        redeemer = nil

        let admitted = XCTestExpectation(description: "card becomes available after deinit teardown")
        let replacement = Task { () throws -> GiftCardRedeemer in
            while true {
                try Task.checkCancellation()
                do {
                    let next = try GiftCardRedeemer(
                        card: card,
                        network: network,
                        endpoint: LightWalletEndpointBuilder.default,
                        isTorEnabled: false,
                        storageDirectory: storageDirectory
                    )
                    admitted.fulfill()
                    return next
                } catch ZcashError.giftCardRedeemerAlreadyActive {
                    await Task.yield()
                }
            }
        }
        let result = await XCTWaiter.fulfillment(of: [admitted], timeout: 5)
        XCTAssertEqual(result, .completed)
        guard result == .completed else {
            replacement.cancel()
            return
        }
        let next = try await replacement.value
        try await next.cleanup()
    }

    // MARK: - Recording the claim in the destination wallet (ZIP 315)

    private static let claimTxId = Data(repeating: 0xC1, count: 32)
    private static let claimRaw = Data([0x05, 0x00, 0x00, 0x80, 0x0A, 0x27, 0xA7, 0x26, 0x01])

    private func makeDestination() -> TrustedTransactionRecordingMock {
        let destination = TrustedTransactionRecordingMock()
        destination.recordTrustedTransactionTxIdClosure = { _, _ in }
        return destination
    }

    private func makeLogger() -> LoggerMock {
        let logger = LoggerMock()
        logger.warnFileFunctionLineClosure = { _, _, _, _ in }
        return logger
    }

    func testAnAcceptedClaimIsRecordedInTheDestination() async {
        let destination = makeDestination()
        let logger = makeLogger()
        var lookedUp: [Data] = []

        let recorded = await GiftCardRedeemer.record(
            [.success(txId: Self.claimTxId)],
            in: destination,
            rawTransaction: { txId in
                lookedUp.append(txId)
                return Self.claimRaw
            },
            logger: logger
        )

        XCTAssertTrue(recorded)
        XCTAssertEqual(lookedUp, [Self.claimTxId], "the raw transaction comes from the card wallet, by the accepted txid")
        XCTAssertEqual(destination.recordTrustedTransactionTxIdCallsCount, 1)
        XCTAssertEqual(destination.recordTrustedTransactionTxIdReceivedArguments?.rawTransaction, Self.claimRaw)
        XCTAssertEqual(destination.recordTrustedTransactionTxIdReceivedArguments?.txId, try TxId([UInt8](Self.claimTxId)))
        XCTAssertEqual(logger.warnFileFunctionLineCallsCount, 0)
    }

    func testOnlyAcceptedClaimsAreRecorded() async {
        let destination = makeDestination()
        let logger = makeLogger()
        let other = Data(repeating: 0xC2, count: 32)
        let results: [TransactionSubmitResult] = [
            .grpcFailure(txId: other, error: .timeOut),
            .success(txId: Self.claimTxId),
            .notAttempted(txId: Data(repeating: 0xC3, count: 32))
        ]

        let recorded = await GiftCardRedeemer.record(results, in: destination, rawTransaction: { _ in Self.claimRaw }, logger: logger)

        XCTAssertTrue(recorded)
        XCTAssertEqual(destination.recordTrustedTransactionTxIdCallsCount, 1)
        XCTAssertEqual(destination.recordTrustedTransactionTxIdReceivedArguments?.txId, try TxId([UInt8](Self.claimTxId)))

        // Nothing accepted: nothing to record, and nothing claims to have been.
        let rejectedOnly = await GiftCardRedeemer.record(
            [.grpcFailure(txId: other, error: .timeOut)],
            in: destination,
            rawTransaction: { _ in
                XCTFail("no lookup for a rejected transaction")
                return nil
            },
            logger: logger
        )
        XCTAssertFalse(rejectedOnly)
        XCTAssertEqual(destination.recordTrustedTransactionTxIdCallsCount, 1)
    }

    func testRedeemWithoutADestinationTouchesNone() async throws {
        let card = try GiftCard(link: Self.zodlTestnetLink)
        let redeemer = try GiftCardRedeemer(
            card: card,
            network: ZcashNetworkBuilder.network(for: .testnet),
            endpoint: LightWalletEndpointBuilder.default,
            isTorEnabled: false,
            storageDirectory: testTempDirectory
        )
        // A bare mock: any call on it would trap on its unset closure. The destination is only
        // ever contacted after an accepted submission; a redeem that does not get that far —
        // here, before `check()` — leaves it alone, with either overload.
        let destination = SynchronizerMock()
        do {
            _ = try await redeemer.redeem(to: card.fundingAddress, memo: nil, recordIn: destination)
            XCTFail("redeem must require check()")
        } catch ZcashError.giftCardRedeemerNotReady {
        } catch {
            XCTFail("Unexpected error \(error.localizedDescription)")
        }
        do {
            _ = try await redeemer.redeem(to: card.fundingAddress, memo: nil, recordIn: nil)
            XCTFail("redeem must require check()")
        } catch ZcashError.giftCardRedeemerNotReady {
        } catch {
            XCTFail("Unexpected error \(error.localizedDescription)")
        }

        try await redeemer.cleanup()
    }

    func testADestinationFailureIsLoggedAndReportedNotThrown() async {
        let destination = makeDestination()
        destination.recordTrustedTransactionTxIdThrowableError = ZcashError.rustDecryptAndStoreTransaction("destination is busy")
        let logger = makeLogger()

        let recorded = await GiftCardRedeemer.record(
            [.success(txId: Self.claimTxId)],
            in: destination,
            rawTransaction: { _ in Self.claimRaw },
            logger: logger
        )

        XCTAssertFalse(recorded, "the funds are on chain either way; only the flag reports the failure")
        XCTAssertEqual(logger.warnFileFunctionLineCallsCount, 1)
        let message = logger.warnFileFunctionLineReceivedArguments?.message ?? ""
        XCTAssertTrue(message.contains("Gift card"), message)
        XCTAssertFalse(message.contains("destination is busy"), "the error's associated value must stay out of the logs")

        let redemption = GiftCardRedeemer.Redemption(results: [.success(txId: Self.claimTxId)], recordedInDestination: recorded, fee: Zatoshi(10_000), amount: Zatoshi(10_000_000))
        XCTAssertEqual(redemption.results, [.success(txId: Self.claimTxId)])
        XCTAssertFalse(redemption.recordedInDestination)
    }

    func testAnUnstoredDestinationClaimIsReportedNotRecorded() async {
        let destination = makeDestination()
        destination.recordTrustedTransactionTxIdClosure = { _, _ in
            throw ZcashError.rustSetTransactionTrust("not stored in destination")
        }
        let logger = makeLogger()

        let recorded = await GiftCardRedeemer.record(
            [.success(txId: Self.claimTxId)],
            in: destination,
            rawTransaction: { _ in Self.claimRaw },
            logger: logger
        )

        XCTAssertEqual(destination.recordTrustedTransactionTxIdCallsCount, 1)
        XCTAssertEqual(destination.recordTrustedTransactionTxIdReceivedArguments?.txId, try TxId([UInt8](Self.claimTxId)))
        XCTAssertFalse(recorded, "the funds are on chain either way; only the flag reports the failure")
        XCTAssertEqual(logger.warnFileFunctionLineCallsCount, 1)
        let message = logger.warnFileFunctionLineReceivedArguments?.message ?? ""
        XCTAssertTrue(message.contains("Gift card"), message)
        XCTAssertFalse(message.contains("not stored in destination"), "the error's associated value must stay out of the logs")

        let redemption = GiftCardRedeemer.Redemption(results: [.success(txId: Self.claimTxId)], recordedInDestination: recorded, fee: Zatoshi(10_000), amount: Zatoshi(10_000_000))
        XCTAssertEqual(redemption.results, [.success(txId: Self.claimTxId)])
        XCTAssertFalse(redemption.recordedInDestination)
    }

    func testAClaimMissingFromTheCardWalletIsLoggedAndNotRecorded() async {
        let destination = makeDestination()
        let logger = makeLogger()

        let recorded = await GiftCardRedeemer.record(
            [.success(txId: Self.claimTxId)],
            in: destination,
            rawTransaction: { _ in nil },
            logger: logger
        )

        XCTAssertFalse(recorded)
        XCTAssertEqual(destination.recordTrustedTransactionTxIdCallsCount, 0)
        XCTAssertEqual(logger.warnFileFunctionLineCallsCount, 1)
    }

    func testCheckpointSourceServesTheExactBirthdayWhenFetched() {
        let bundled = CheckpointSourceFactory.fromBundle(for: .testnet)
        let source = GiftCardCheckpointSource(bundled: bundled)
        let birthday = BlockHeight(4_453_870)

        // Nothing fetched yet: the bundled grid applies.
        XCTAssertEqual(source.birthday(for: birthday).height, bundled.birthday(for: birthday).height)

        XCTAssertTrue(source.use(Self.treeState(height: birthday - 1), forBirthday: birthday))

        XCTAssertEqual(source.birthday(for: birthday).height, birthday - 1)
        XCTAssertEqual(source.birthday(for: birthday + 500).height, birthday - 1)
        XCTAssertNil(source.birthday(for: birthday).ironwoodTree)
        // A birthday below the fetched state falls back to the bundled grid.
        XCTAssertEqual(source.birthday(for: birthday - 100).height, bundled.birthday(for: birthday - 100).height)
    }

    func testCheckpointSourceFallbacksStartStrictlyBeforeGiftCardBirthdays() {
        let cases: [(NetworkType, BlockHeight)] = [
            (.mainnet, 3_500_000),
            (.testnet, 3_000_000),
            (.mainnet, 1_687_104),
            (.testnet, 1_842_420)
        ]

        for (network, birthday) in cases {
            let bundled = CheckpointSourceFactory.fromBundle(for: network)
            let source = GiftCardCheckpointSource(bundled: bundled)

            let fallback = source.birthday(for: birthday)

            XCTAssertLessThan(fallback.height, birthday, "network: \(network), birthday: \(birthday)")
            XCTAssertLessThanOrEqual(fallback.height + 1, birthday, "network: \(network), birthday: \(birthday)")
            XCTAssertEqual(
                fallback.height,
                bundled.birthday(for: birthday - 1).height,
                "network: \(network), birthday: \(birthday)"
            )
        }
    }

    func testCheckpointSourceDoesNotServeCachedStateAtItsExactHeight() {
        let bundled = CheckpointSourceFactory.fromBundle(for: .testnet)
        let source = GiftCardCheckpointSource(bundled: bundled)
        let birthday = BlockHeight(4_453_870)
        let cachedHeight = birthday - 1
        let bundledFallback = bundled.birthday(for: cachedHeight - 1)

        XCTAssertTrue(source.use(Self.treeState(height: cachedHeight), forBirthday: birthday))

        let checkpoint = source.birthday(for: cachedHeight)

        XCTAssertEqual(checkpoint.height, bundledFallback.height)
        XCTAssertNotEqual(checkpoint.height, cachedHeight)
    }

    /// A server that answers with the state of another height must not move the start of the
    /// scan: later would skip the card's funds, earlier would scan for nothing.
    func testCheckpointSourceIgnoresATreeStateForAnotherHeight() {
        let bundled = CheckpointSourceFactory.fromBundle(for: .testnet)
        let source = GiftCardCheckpointSource(bundled: bundled)
        let birthday = BlockHeight(4_453_870)

        for height in [birthday, birthday - 2, birthday + 1_000, birthday - 50_000, 0] {
            XCTAssertFalse(source.use(Self.treeState(height: height), forBirthday: birthday), "\(height)")
            XCTAssertEqual(source.birthday(for: birthday).height, bundled.birthday(for: birthday).height)
        }
    }

    /// A checkpoint is built from whatever tree state the server answers with, and a server can put
    /// any `UInt64` in its height. One the SDK cannot use gives no checkpoint, instead of a trap.
    func testCheckpointFromATreeStateAtAnUnusableHeightIsNil() {
        for height in [UInt64(Int32.max) + 1, UInt64(UInt32.max), UInt64(Int64.max) + 1, UInt64.max] {
            var treeState = Self.treeState(height: 1)
            treeState.height = height

            XCTAssertNil(Checkpoint(treeState: treeState), "\(height)")
        }
    }

    func testCheckpointFromATreeStateAtTheLargestUsableHeightKeepsTheTreeState() {
        var treeState = Self.treeState(height: 1)
        treeState.height = UInt64(Int32.max)

        let checkpoint = Checkpoint(treeState: treeState)

        XCTAssertEqual(checkpoint?.height, BlockHeight(Int32.max))
        XCTAssertEqual(checkpoint?.hash, treeState.hash)
        XCTAssertEqual(checkpoint?.saplingTree, treeState.saplingTree)
        XCTAssertEqual(checkpoint?.orchardTree, treeState.orchardTree)
        XCTAssertNil(checkpoint?.ironwoodTree)
    }

    /// The tree state is only used at exactly `birthday - 1`. When that height is one the SDK cannot
    /// use, the state is ignored like any other state for the wrong height, and the bundled
    /// checkpoint applies.
    func testCheckpointSourceIgnoresATreeStateAtAnUnusableHeight() {
        let bundled = CheckpointSourceFactory.fromBundle(for: .testnet)
        let source = GiftCardCheckpointSource(bundled: bundled)
        let birthday = BlockHeight(Int32.max) + 2
        var treeState = Self.treeState(height: 1)
        treeState.height = UInt64(birthday - 1)

        XCTAssertFalse(source.use(treeState, forBirthday: birthday))
        XCTAssertEqual(source.birthday(for: birthday).height, bundled.birthday(for: birthday - 1).height)
    }

    private static func treeState(height: BlockHeight) -> TreeState {
        var treeState = TreeState()
        treeState.height = UInt64(height)
        treeState.hash = "00"
        treeState.time = 1
        treeState.saplingTree = "00"
        treeState.orchardTree = "00"
        return treeState
    }

    // MARK: - Leftover card wallets

    func testRemoveLeftoverWalletsSparesLiveRedeemersAndOtherFiles() async throws {
        let card = try GiftCard(link: Self.zodlTestnetLink)
        let live = try GiftCardRedeemer(
            card: card,
            network: ZcashNetworkBuilder.network(for: .testnet),
            endpoint: LightWalletEndpointBuilder.default,
            isTorEnabled: false,
            storageDirectory: testTempDirectory
        )
        let fileManager = FileManager.default
        let liveDirectory = testTempDirectory.appendingPathComponent(card.synchronizerAlias.description, isDirectory: true)
        let orphans = ["c_giftcard_0011223344556677", "c_giftcard_8899aabbccddeeff"].map {
            testTempDirectory.appendingPathComponent($0, isDirectory: true)
        }
        let unrelated = testTempDirectory.appendingPathComponent("c_default_wallet", isDirectory: true)
        for directory in [liveDirectory, unrelated] + orphans {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            fileManager.createFile(atPath: directory.appendingPathComponent("data.db").path, contents: Data([1]))
        }

        XCTAssertEqual(try GiftCardRedeemer.removeLeftoverWallets(in: testTempDirectory), 2)

        for orphan in orphans {
            XCTAssertFalse(fileManager.fileExists(atPath: orphan.path))
        }
        XCTAssertTrue(fileManager.fileExists(atPath: liveDirectory.path), "a live redeemer's wallet is never touched")
        XCTAssertTrue(fileManager.fileExists(atPath: unrelated.path), "only card wallets are removed")

        // Once the redeemer is gone, its wallet is a leftover too.
        try await live.cleanup()
        try fileManager.createDirectory(at: liveDirectory, withIntermediateDirectories: true)
        XCTAssertEqual(try GiftCardRedeemer.removeLeftoverWallets(in: testTempDirectory), 1)
        XCTAssertFalse(fileManager.fileExists(atPath: liveDirectory.path))

        // A missing storage directory has nothing to remove.
        let missing = testTempDirectory.appendingPathComponent("missing", isDirectory: true)
        XCTAssertEqual(try GiftCardRedeemer.removeLeftoverWallets(in: missing), 0)
    }
}
