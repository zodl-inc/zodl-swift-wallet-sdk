import XCTest
@testable import ZcashLightClientKit

final class PaymentURIParserTests: XCTestCase {
    func testParsesSupportedPaymentRequests() throws {
        let bitcoin = try PaymentURIParser.parse(
            "bitcoin:1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo?amount=20.3&label=Luke-Jr"
        )
        guard case let .bitcoin(request) = bitcoin else { return XCTFail("Expected Bitcoin") }
        XCTAssertEqual(request.amount?.value, "20.3")
        XCTAssertEqual(request.label, "Luke-Jr")

        let solana = try PaymentURIParser.parse(
            "solana:mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN?amount=0.01&spl-token=EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
        )
        guard case let .solanaTransfer(request) = solana else { return XCTFail("Expected Solana") }
        XCTAssertEqual(request.amount?.value, "0.01")
        XCTAssertEqual(request.splToken?.value, "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")

        let ethereum = try PaymentURIParser.parse(
            "ethereum:0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359?value=1e18"
        )
        guard case let .ethereum(.native(request)) = ethereum else { return XCTFail("Expected native Ethereum") }
        XCTAssertEqual(request.recipientAddress, "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359")
        XCTAssertEqual(request.valueHex, "0xde0b6b3a7640000")
    }

    func testRejectsMalformedRequest() {
        XCTAssertThrowsError(try PaymentURIParser.parse("bitcoin:not-an-address"))
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
        XCTAssertEqual(request.amount?.value, "1.25")
        XCTAssertEqual(request.message, "Coffee")
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

    func testDecodesSolanaTransactionLink() throws {
        let json = """
        {"version":1,"type":"solana_transaction","link":"https://example.com/tx"}
        """
        let decoded = try JSONDecoder().decode(EncodedRequest.self, from: Data(json.utf8))
        guard case let .solanaTransaction(url) = try decoded.paymentRequest else {
            return XCTFail("Expected Solana transaction link")
        }
        XCTAssertEqual(url.absoluteString, "https://example.com/tx")
    }

    func testRejectsSolanaTransactionWithInvalidLink() {
        let json = """
        {"version":1,"type":"solana_transaction","link":""}
        """
        let decoded = try? JSONDecoder().decode(EncodedRequest.self, from: Data(json.utf8))
        XCTAssertThrowsError(try decoded?.paymentRequest)
    }

    func testDecodesUnrecognisedEthereumRequest() throws {
        let json = """
        {"version":1,"type":"ethereum_unrecognised"}
        """
        let decoded = try JSONDecoder().decode(EncodedRequest.self, from: Data(json.utf8))
        guard case .ethereum(.unrecognised) = try decoded.paymentRequest else {
            return XCTFail("Expected unrecognised Ethereum request")
        }
    }

    func testDecodesEnvelopeVersion() {
        // `PaymentURIParser.parse` compares this field against its private
        // `encodedVersion` constant; this only pins that decoding the field
        // itself keeps working, since the guard isn't reachable from outside
        // the enum without a real (version-mismatched) FFI response.
        let json = """
        {"version":2,"type":"bitcoin","address":"1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo","network":"mainnet"}
        """
        let decoded = try? JSONDecoder().decode(EncodedRequest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded?.version, 2)
    }

    func testRejectsMissingRequiredField() {
        let json = """
        {"version":1,"type":"bitcoin","network":"mainnet"}
        """
        let decoded = try? JSONDecoder().decode(EncodedRequest.self, from: Data(json.utf8))
        XCTAssertThrowsError(try decoded?.paymentRequest)
    }
}
