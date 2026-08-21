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
}
