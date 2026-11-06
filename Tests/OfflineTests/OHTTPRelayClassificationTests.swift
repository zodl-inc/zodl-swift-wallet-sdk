import XCTest
@testable import ZODLSwiftWalletSDK

final class OHTTPRelayClassificationTests: XCTestCase {
    private let fingerprints: Set<String> = [
        "3395cdcd1a5a6c6830ec6178543d4997ae58777fe8ac9719d34d833c1a21a336"
    ]

    func testIndependentHostMatchingIsCaseInsensitive() {
        for host in ["independent-relay.example.invalid", "INDEPENDENT-RELAY.EXAMPLE.INVALID"] {
            XCTAssertTrue(OHTTPEndpoints.isIndependentRelayHost(host, fingerprints: fingerprints))
        }
    }

    func testLookalikesAndOperatorHostsAreNotIndependent() {
        for host in [
            "sub.independent-relay.example.invalid",
            "independent-relay.example.invalid.attacker.invalid",
            "independent-relay-example.invalid",
            "operator-relay.example.invalid",
            "",
            "independent-relay.example.invalid."
        ] {
            XCTAssertFalse(OHTTPEndpoints.isIndependentRelayHost(host, fingerprints: fingerprints))
        }
    }

    func testEmptyIndependentSetNeverClaimsPrivacy() {
        XCTAssertFalse(OHTTPEndpoints.isIndependentRelayHost("independent-relay.example.invalid", fingerprints: []))
    }

    func testUnknownGatewayHasNoIndependentRelay() {
        XCTAssertTrue(OHTTPEndpoints.usesOperatorRelay(gatewayHost: "unknown-gateway.example.invalid"))
    }
}
