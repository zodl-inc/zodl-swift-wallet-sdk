import XCTest
@testable import ZcashLightClientKit

final class PaymentURIParserTests: XCTestCase {
    func testParsesSupportedPaymentRequests() throws {
        let bitcoin = try PaymentURIParser.parse(
            "bitcoin:1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo?amount=20.3&label=Luke-Jr"
        )
        guard case let .bitcoin(request) = bitcoin else { return XCTFail("Expected Bitcoin") }
        XCTAssertEqual(request.address.value, "1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo")
        XCTAssertEqual(request.network, .mainnet)
        XCTAssertEqual(request.amount?.value, "20.3")
        XCTAssertEqual(request.label, "Luke-Jr")

        let solana = try PaymentURIParser.parse(
            "solana:mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN?amount=0.01&spl-token=EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
        )
        guard case let .solanaTransfer(request) = solana else { return XCTFail("Expected Solana") }
        XCTAssertEqual(request.recipient.value, "mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN")
        XCTAssertEqual(request.amount?.value, "0.01")
        XCTAssertEqual(request.splToken?.value, "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")

        // EIP-681's own worked example: a non-round value exercises the decimal-to-hex
        // conversion far more meaningfully than a round number like 1e18 would.
        let ethereum = try PaymentURIParser.parse(
            "ethereum:0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359@42161?value=2.014e18&gasLimit=21000&gasPrice=50"
        )
        guard case let .ethereum(.native(request)) = ethereum else { return XCTFail("Expected native Ethereum") }
        XCTAssertEqual(request.recipientAddress, "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359")
        XCTAssertEqual(request.valueHex, "0x1bf32a5451a30000")
        XCTAssertEqual(request.chainId, 42161)
        XCTAssertEqual(request.gasLimitHex, "0x5208")
        XCTAssertEqual(request.gasPriceHex, "0x32")
    }

    func testRejectsMalformedRequest() {
        XCTAssertThrowsError(try PaymentURIParser.parse("bitcoin:not-an-address")) { error in
            XCTAssertEqual(error as? PaymentURIParserError, .rejected(.invalidAddress))
        }
    }

    func testRejectsDuplicateBitcoinAmountParameter() {
        // BIP-321's own "Invalid Payment Request URIs" example: a duplicate parameter is
        // rejected even when both occurrences carry the same value.
        XCTAssertThrowsError(
            try PaymentURIParser.parse("bitcoin:1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo?amount=42&amount=42")
        ) { error in
            XCTAssertEqual(error as? PaymentURIParserError, .rejected(.duplicateParameter))
        }
    }

    func testRejectsUnsupportedRequiredBitcoinExtension() {
        XCTAssertThrowsError(
            try PaymentURIParser.parse(
                "bitcoin:1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo?req-somethingyoudontunderstand=50"
            )
        ) { error in
            XCTAssertEqual(error as? PaymentURIParserError, .rejected(.unsupportedRequiredParameter))
        }
    }

    func testRejectsEmbeddedNullByte() {
        let uri = "bitcoin:1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo\0?amount=1"
        XCTAssertThrowsError(try PaymentURIParser.parse(uri)) { error in
            XCTAssertEqual(error as? PaymentURIParserError, .invalidURI)
        }
    }

    func testParsesLitecoinRequest() throws {
        let litecoin = try PaymentURIParser.parse(
            "litecoin:LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA?amount=1.25&message=Coffee"
        )
        guard case let .litecoin(request) = litecoin else { return XCTFail("Expected Litecoin") }
        XCTAssertEqual(request.address.value, "LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA")
        XCTAssertEqual(request.network, .mainnet)
        XCTAssertEqual(request.amount?.value, "1.25")
        XCTAssertEqual(request.message, "Coffee")
    }

    func testParsesUppercaseBech32Addresses() throws {
        let bitcoin = try PaymentURIParser.parse(
            "bitcoin:BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4?amount=1"
        )
        guard case let .bitcoin(bitcoinRequest) = bitcoin else { return XCTFail("Expected Bitcoin") }
        XCTAssertEqual(bitcoinRequest.address.value, "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
        XCTAssertEqual(bitcoinRequest.amount?.value, "1")

        let litecoin = try PaymentURIParser.parse(
            "litecoin:TLTC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KLFSUQ0?amount=2"
        )
        guard case let .litecoin(litecoinRequest) = litecoin else { return XCTFail("Expected Litecoin") }
        XCTAssertEqual(litecoinRequest.address.value, "tltc1qw508d6qejxtdg4y5r3zarvary0c5xw7klfsuq0")
        XCTAssertEqual(litecoinRequest.amount?.value, "2")
    }

    func testLitecoinQueryKeysAreCaseInsensitive() throws {
        let litecoin = try PaymentURIParser.parse(
            "litecoin:LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA?Amount=1.2500&Label=Coffee"
        )
        guard case let .litecoin(request) = litecoin else { return XCTFail("Expected Litecoin") }
        XCTAssertEqual(request.amount?.value, "1.2500")
        XCTAssertEqual(request.label, "Coffee")

        XCTAssertThrowsError(
            try PaymentURIParser.parse(
                "litecoin:LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA?REQ-somethingyoudontunderstand=50"
            )
        ) { error in
            XCTAssertEqual(error as? PaymentURIParserError, .rejected(.unsupportedRequiredParameter))
        }
    }

    func testParsesErc20Request() throws {
        let erc20 = try PaymentURIParser.parse(
            "ethereum:0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48/transfer" +
            "?address=0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359&uint256=1000000"
        )
        guard case let .ethereum(.erc20(request)) = erc20 else { return XCTFail("Expected ERC-20 Ethereum") }
        XCTAssertEqual(request.tokenContractAddress, "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")
        XCTAssertEqual(request.recipientAddress, "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359")
    }

    func testRejectsOverlengthEthereumAddresses() {
        let overlength = "0x" + String(repeating: "a", count: 41)
        let valid = "0x" + String(repeating: "b", count: 40)
        let malformedRequests = [
            "ethereum:\(overlength)",
            "ethereum:\(overlength)/transfer?address=\(valid)&uint256=1",
            "ethereum:\(valid)/transfer?address=\(overlength)&uint256=1",
            "ethereum:\(overlength)/approve?address=\(valid)&uint256=1"
        ]

        for request in malformedRequests {
            XCTAssertThrowsError(try PaymentURIParser.parse(request)) { error in
                XCTAssertEqual(error as? PaymentURIParserError, .rejected(.invalidAddress))
            }
        }
    }

    func testDecodesSolanaTransactionLink() throws {
        // The link is re-validated in Swift (see PaymentURIParser.swift): the crate's own check
        // leaves everything after the authority unverified and runs on the decoded payload.
        let json = """
        {"version":1,"type":"solana_transaction","link":"https://example.com/tx"}
        """
        guard case let .solanaTransaction(link) = try PaymentURIParser.decode(Data(json.utf8)) else {
            return XCTFail("Expected Solana transaction link")
        }
        XCTAssertEqual(link.value, "https://example.com/tx")
    }

    func testRejectsSolanaTransactionWithMissingLink() {
        let json = """
        {"version":1,"type":"solana_transaction"}
        """
        XCTAssertThrowsError(try PaymentURIParser.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? PaymentURIParserError, .invalidEnvelope)
        }
    }

    func testDecodesUnrecognisedEthereumRequest() throws {
        let json = """
        {"version":1,"type":"ethereum_unrecognised"}
        """
        guard case .ethereum(.unrecognised) = try PaymentURIParser.decode(Data(json.utf8)) else {
            return XCTFail("Expected unrecognised Ethereum request")
        }
    }

    func testDecodesEnvelopeVersion() {
        let json = """
        {"version":2,"type":"bitcoin","address":"1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo","network":"mainnet"}
        """
        XCTAssertThrowsError(try PaymentURIParser.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? PaymentURIParserError, .unsupportedEnvelope(version: 2))
        }
    }

    func testRejectsMissingRequiredField() {
        let json = """
        {"version":1,"type":"bitcoin","network":"mainnet"}
        """
        XCTAssertThrowsError(try PaymentURIParser.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? PaymentURIParserError, .invalidEnvelope)
        }
    }

    func testRejectsRetypedEnvelopeFieldAsInvalidEnvelope() {
        let json = """
        {
          "version":1,
          "type":"ethereum_native",
          "schema_prefix":"ethereum",
          "has_pay":"false",
          "recipient_address":"0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"
        }
        """
        XCTAssertThrowsError(try PaymentURIParser.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? PaymentURIParserError, .invalidEnvelope)
        }
    }

    func testRejectsUnknownEnvelopeTypeAsInvalidEnvelope() {
        let json = """
        {"version":1,"type":"future_payment_protocol"}
        """
        XCTAssertThrowsError(try PaymentURIParser.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? PaymentURIParserError, .invalidEnvelope)
        }
    }

    func testParserFailureRedactsRawRustError() {
        let raw = "panic while parsing secret-recipient.example"
        let redacted = RedactedRustError(
            kind: .unclassified,
            message: "an unclassified error occurred"
        )
        let error = PaymentURIParser.classifyFailure(
            reported: raw,
            clearRecognizedError: { XCTFail("A panic is not a rejection token") },
            redactedReport: { redacted }
        )

        XCTAssertEqual(error, .parserFailure(redacted))
        XCTAssertFalse(String(describing: error).contains(raw))
    }

    func testRecognizedRejectionDoesNotRequestARedactedReport() {
        var didClear = false
        let error = PaymentURIParser.classifyFailure(
            reported: "payment URI rejected: invalid_address",
            clearRecognizedError: { didClear = true },
            redactedReport: {
                XCTFail("A recognized rejection should not consume a redacted report")
                return RedactedRustError(kind: .unclassified, message: "unused")
            }
        )

        XCTAssertEqual(error, .rejected(.invalidAddress))
        XCTAssertTrue(didClear)
    }

    // MARK: - Coverage gaps closed after review

    func testErc20CarriesTheTransferValue() throws {
        // uint256=1000000 must survive the decimal -> hex conversion. Asserted numerically so a
        // change of case or zero-padding in the envelope doesn't fail the test spuriously.
        let erc20 = try PaymentURIParser.parse(
            "ethereum:0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48/transfer" +
            "?address=0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359&uint256=1000000"
        )
        guard case let .ethereum(.erc20(request)) = erc20 else { return XCTFail("Expected ERC-20") }
        let digits = request.valueHex.dropFirst(2)
        XCTAssertTrue(request.valueHex.hasPrefix("0x"))
        XCTAssertEqual(UInt64(digits, radix: 16), 1_000_000)
        XCTAssertEqual(request.schemaPrefix, "ethereum")
        XCTAssertFalse(request.hasPay)
        XCTAssertNil(request.chainId)
    }

    func testNativeRequestCarriesSchemaPrefixAndPayFlag() throws {
        let native = try PaymentURIParser.parse(
            "ethereum:pay-0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359@1?value=1"
        )
        guard case let .ethereum(.native(request)) = native else { return XCTFail("Expected native") }
        XCTAssertEqual(request.schemaPrefix, "ethereum")
        XCTAssertTrue(request.hasPay)
        XCTAssertEqual(request.chainId, 1)
    }

    func testSolanaTransferCarriesEveryOptionalField() throws {
        let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
        let reference = "mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN"
        let solana = try PaymentURIParser.parse(
            "solana:mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN?amount=0.01&spl-token=\(mint)" +
            "&reference=\(reference)&label=Shop&message=Order%20123&memo=note"
        )
        guard case let .solanaTransfer(request) = solana else { return XCTFail("Expected transfer") }
        XCTAssertEqual(request.splToken?.value, mint)
        XCTAssertEqual(request.references.map(\.value), [reference])
        XCTAssertEqual(request.label, "Shop")
        XCTAssertEqual(request.message, "Order 123")
        XCTAssertEqual(request.memo, "note")
    }

    func testDecodesNonMainnetNetworks() throws {
        // The testnet/regtest arms of `utxoRequest()` had no coverage: every existing address
        // was mainnet, so a mis-mapped arm could not fail a test.
        let testnet = try PaymentURIParser.parse("bitcoin:tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx")
        guard case let .bitcoin(request) = testnet else { return XCTFail("Expected Bitcoin") }
        XCTAssertEqual(request.network, .testnet)

        let regtest = try PaymentURIParser.parse("bitcoin:bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080")
        guard case let .bitcoin(regtestRequest) = regtest else { return XCTFail("Expected Bitcoin") }
        XCTAssertEqual(regtestRequest.network, .regtest)

        let litecoin = try PaymentURIParser.parse("litecoin:tltc1qw508d6qejxtdg4y5r3zarvary0c5xw7klfsuq0")
        guard case let .litecoin(litecoinRequest) = litecoin else { return XCTFail("Expected Litecoin") }
        XCTAssertEqual(litecoinRequest.network, .testnet)
    }

    func testParsesSolanaTransactionLinkThroughTheFFI() throws {
        // Previously exercised only through hand-written JSON the crate never emits.
        let request = try PaymentURIParser.parse("solana:https://example.com/tx")
        guard case let .solanaTransaction(link) = request else { return XCTFail("Expected link") }
        XCTAssertEqual(link.value, "https://example.com/tx")
    }

    func testParsesUnrecognisedEthereumRequestThroughTheFFI() throws {
        let request = try PaymentURIParser.parse(
            "ethereum:0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48/approve" +
            "?address=0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359&uint256=1"
        )
        guard case .ethereum(.unrecognised) = request else { return XCTFail("Expected unrecognised") }
    }

    func testRejectsTransactionLinkWithEmbeddedCredentials() {
        // https://trusted.example.com@evil.test/pay — a length-truncating display shows the
        // trusted-looking prefix while the request targets the host after the "@".
        let json = """
        {"version":1,"type":"solana_transaction","link":"https://trusted.example.com@evil.test/pay"}
        """
        XCTAssertThrowsError(try PaymentURIParser.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? PaymentURIParserError, .invalidURI)
        }
    }

    func testRejectsNonHTTPSTransactionLink() {
        let json = """
        {"version":1,"type":"solana_transaction","link":"http://example.com/tx"}
        """
        XCTAssertThrowsError(try PaymentURIParser.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? PaymentURIParserError, .invalidURI)
        }
    }

    func testUnsupportedSchemeIsClassified() {
        XCTAssertThrowsError(try PaymentURIParser.parse("near:alice.near")) { error in
            XCTAssertEqual(error as? PaymentURIParserError, .rejected(.unsupportedScheme))
        }
    }

    func testResultTypesAreConstructableByConsumers() {
        // Guards the public inits a dependency double needs; without them these types could only
        // be built inside the module.
        let request = UTXOPaymentURIRequest(
            address: PaymentURIAddress(value: "1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo"),
            network: .mainnet,
            amount: PaymentURIAmount(value: "1.5"),
            label: nil,
            message: nil
        )
        XCTAssertEqual(PaymentURIRequest.bitcoin(request), .bitcoin(request))
    }
}
