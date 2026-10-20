//
//  OHTTPSignedConfigTests.swift
//  OfflineTests
//
//  The signed key-configuration envelope is verified by the shared Rust core (`zodl-ohttp-client`, iOS
//  profile) against the pinned signing keys, so these tests drive it through `OHTTPNative.verifyKeyConfig`.
//  The pinned keys have no private half here, so an envelope cannot be made that passes the signature; the
//  tests check that every rule in front of the signature refuses what it should and that an envelope which
//  satisfies them all stops only at the signature.
//

import XCTest
@testable import ZODLSwiftWalletSDK

final class OHTTPSignedConfigTests: XCTestCase {
    private static let testnetHost = "ohttp-gateway-testnet.example"
    private static let mainnetHost = "ohttp-gateway.example"
    private static let testnetKeyId = "a3620fb6"
    private static let mainnetKeyId = "ba8a2dbd"

    /// Middle of the validity window the envelopes below use.
    private let now = Date(timeIntervalSince1970: 1_700_010_000)
    private let notBefore: Int64 = 1_700_000_000
    private let notAfter: Int64 = 1_700_020_000

    /// 64 zero bytes: well-formed, and not a signature by the pinned key.
    private let zeroSignature = Data(count: 64).base64EncodedString()

    /// A 43-byte key-configuration document for the supported suite (the parser is not reached before the
    /// signature is checked, but the bytes are realistic).
    private var configBytes: Data {
        var config = Data([0x00, 0x29, 0x01, 0x00, 0x20])
        config.append(Data(repeating: 0x09, count: 32))
        config.append(contentsOf: [0x00, 0x04, 0x00, 0x01, 0x00, 0x01])
        return config
    }

    private func envelope(
        version: Int = 1,
        network: String = "testnet",
        configs: String? = nil,
        notBefore: Int64? = nil,
        notAfter: Int64? = nil,
        keyId: String = OHTTPSignedConfigTests.testnetKeyId,
        signature: String? = nil,
        extraFields: String = ""
    ) -> Data {
        let json = """
        {"v":\(version),"network":"\(network)","configs":"\(configs ?? configBytes.base64EncodedString())",\
        "not_before":\(notBefore ?? self.notBefore),"not_after":\(notAfter ?? self.notAfter),\
        "key_id":"\(keyId)","sig":"\(signature ?? zeroSignature)"\(extraFields)}
        """
        return Data(json.utf8)
    }

    /// The message of the key-configuration error the native verifier throws for `json`, or `nil` if it
    /// verifies.
    private func failure(
        of json: Data,
        host: String = OHTTPSignedConfigTests.testnetHost,
        at date: Date? = nil
    ) -> String? {
        do {
            _ = try OHTTPNative.verifyKeyConfig(gatewayHost: host, envelope: json, now: date ?? now)
            return nil
        } catch OHTTPError.keyConfigError(let message) {
            return message
        } catch {
            XCTFail("Expected keyConfigError, got \(error)")
            return nil
        }
    }

    // MARK: - Rules in front of the signature

    func testValidEnvelopeWithBadSignatureFails() throws {
        let message = try XCTUnwrap(failure(of: envelope()))
        XCTAssertTrue(message.contains("bad signature"), message)
    }

    func testWrongNetworkFails() throws {
        let mainnetEnvelope = envelope(network: "mainnet", keyId: Self.mainnetKeyId)
        let forTestnet = try XCTUnwrap(failure(of: mainnetEnvelope))
        XCTAssertTrue(forTestnet.contains("signed for mainnet, not testnet"), forTestnet)

        let forMainnet = try XCTUnwrap(failure(of: envelope(), host: Self.mainnetHost))
        XCTAssertTrue(forMainnet.contains("signed for testnet, not mainnet"), forMainnet)
    }

    func testExpiredConfigFails() throws {
        // Past not_after plus the 60 s of allowed clock skew.
        let message = try XCTUnwrap(failure(of: envelope(), at: Date(timeIntervalSince1970: Double(notAfter) + 61)))
        XCTAssertTrue(message.contains("validity window"), message)

        // Before not_before minus the skew.
        let early = try XCTUnwrap(failure(of: envelope(), at: Date(timeIntervalSince1970: Double(notBefore) - 61)))
        XCTAssertTrue(early.contains("validity window"), early)
    }

    func testClockSkewOfSixtySecondsIsAllowedOnBothEnds() throws {
        for date in [Double(notBefore) - 60, Double(notAfter) + 60] {
            // Inside the skew the envelope gets as far as its signature.
            let message = try XCTUnwrap(failure(of: envelope(), at: Date(timeIntervalSince1970: date)))
            XCTAssertTrue(message.contains("bad signature"), message)
        }
    }

    func testValidityExceeds24HoursFails() throws {
        let message = try XCTUnwrap(failure(of: envelope(notBefore: notBefore, notAfter: notBefore + 90_000)))
        XCTAssertTrue(message.contains("longer than a day"), message)
    }

    func testNotAfterTooFarInFutureFails() throws {
        // A day long, but ending more than a day from now.
        let start = Int64(now.timeIntervalSince1970) + 50
        let message = try XCTUnwrap(failure(of: envelope(notBefore: start, notAfter: start + 86_400)))
        XCTAssertTrue(message.contains("longer than a day"), message)
    }

    func testWrongKeyIdFails() throws {
        let message = try XCTUnwrap(failure(of: envelope(keyId: "deadbeef")))
        XCTAssertTrue(message.contains("signed by key deadbeef, not \(Self.testnetKeyId)"), message)

        // The other network's key id is wrong too.
        let swapped = try XCTUnwrap(failure(of: envelope(keyId: Self.mainnetKeyId)))
        XCTAssertTrue(swapped.contains("signed by key \(Self.mainnetKeyId)"), swapped)
    }

    func testUnsupportedProtocolVersionFails() throws {
        let message = try XCTUnwrap(failure(of: envelope(version: 2)))
        XCTAssertTrue(message.contains("envelope version 2"), message)
    }

    func testSignedConfigRejectsOversizedPayload() throws {
        // A document of 5000 bytes is over the 4096-byte cap.
        let oversized = Data(repeating: 0x42, count: 5000).base64EncodedString()
        let message = try XCTUnwrap(failure(of: envelope(configs: oversized)))
        XCTAssertTrue(message.contains("4096"), message)
    }

    func testEnvelopeOverTheKeyConfigurationCapIsRefusedBeforeItIsParsed() throws {
        let padding = String(repeating: " ", count: 65_537)
        let message = try XCTUnwrap(failure(of: Data("{\(padding)}".utf8)))
        XCTAssertTrue(message.contains("more than 65536 bytes"), message)
    }

    func testSignedConfigRejectsInvalidTimeRange() throws {
        let equal = try XCTUnwrap(failure(of: envelope(notBefore: notBefore, notAfter: notBefore)))
        XCTAssertTrue(equal.contains("not_before is not before not_after"), equal)

        let inverted = try XCTUnwrap(failure(of: envelope(notBefore: notBefore + 1000, notAfter: notBefore)))
        XCTAssertTrue(inverted.contains("not_before is not before not_after"), inverted)
    }

    func testSignedConfigRejectsWrongNetwork() throws {
        // A testnet envelope is refused for the mainnet gateway and the other way round, whatever its key id.
        let testnetForMainnet = try XCTUnwrap(failure(of: envelope(), host: Self.mainnetHost))
        XCTAssertTrue(testnetForMainnet.contains("signed for testnet, not mainnet"), testnetForMainnet)
        let mainnetForTestnet = try XCTUnwrap(failure(of: envelope(network: "mainnet", keyId: Self.mainnetKeyId)))
        XCTAssertTrue(mainnetForTestnet.contains("signed for mainnet, not testnet"), mainnetForTestnet)
    }

    // MARK: - Envelope fields

    func testAnUnknownEnvelopeFieldIsIgnored() throws {
        // The gateway can add a field without a client release: the envelope still reaches its signature.
        let message = try XCTUnwrap(failure(of: envelope(extraFields: ",\"future_field\":{\"a\":1}")))
        XCTAssertTrue(message.contains("bad signature"), message)
    }

    func testARepeatedEnvelopeFieldIsRefused() throws {
        for repeated in [",\"v\":1", ",\"sig\":\"AA==\"", ",\"future_field\":1,\"future_field\":2"] {
            let message = try XCTUnwrap(failure(of: envelope(extraFields: repeated)), repeated)
            XCTAssertTrue(message.contains("duplicate"), message)
        }
    }

    func testTheEnvelopeMustBeAJSONObject() throws {
        for body in ["", "not json", "[]", "null", "{}"] {
            let message = try XCTUnwrap(failure(of: Data(body.utf8)), body)
            XCTAssertTrue(message.hasPrefix("key configuration"), message)
        }
    }

    // MARK: - Base64 is strict

    /// The base64 alphabet, to forge a non-zero trailing bit.
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    /// What Foundation's `Data(base64Encoded:)` and other lenient readers accept and the core must not:
    /// missing padding, non-zero trailing bits and embedded whitespace. (The core decodes `configs` and
    /// `sig` strictly, before the signature is checked, so a refusal names the field; an envelope that
    /// decodes stops at "bad signature".)
    func testLenientBase64InTheSignedConfigIsRejected() throws {
        let canonical = configBytes.base64EncodedString()
        XCTAssertTrue(canonical.hasSuffix("=="), "A 43-byte document ends in two padding characters")

        // Control: the canonical form gets past decoding and stops at the signature.
        let control = try XCTUnwrap(failure(of: envelope(configs: canonical)))
        XCTAssertTrue(control.contains("bad signature"), control)

        let characters = Array(canonical)
        let lastDataCharacter = characters.count - 3
        let index = try XCTUnwrap(Self.alphabet.firstIndex(of: characters[lastDataCharacter]))
        XCTAssertEqual(index % 16, 0, "Canonical base64 has zero trailing bits")
        var forged = characters
        forged[lastDataCharacter] = Self.alphabet[index | 1]

        let lenient: [(String, String)] = [
            ("unpadded", String(canonical.dropLast(2))),
            ("non-zero trailing bits", String(forged)),
            ("embedded space", "\(canonical.prefix(20)) \(canonical.dropFirst(20))"),
            ("embedded newline", "\(canonical.prefix(20))\\n\(canonical.dropFirst(20))"),
            ("single padding", String(canonical.dropLast(1)))
        ]
        for (name, configs) in lenient {
            let message = try XCTUnwrap(failure(of: envelope(configs: configs)), name)
            XCTAssertTrue(message.contains("configs:"), "\(name): \(message)")
            XCTAssertFalse(message.contains("bad signature"), "\(name) was decoded: \(message)")
        }
    }

    func testLenientBase64InTheSignatureIsRejected() throws {
        let canonical = zeroSignature
        for (name, signature) in [
            ("unpadded", String(canonical.dropLast(2))),
            ("embedded space", "\(canonical.prefix(10)) \(canonical.dropFirst(10))")
        ] {
            let message = try XCTUnwrap(failure(of: envelope(signature: signature)), name)
            XCTAssertTrue(message.contains("sig:"), "\(name): \(message)")
        }
    }

    // MARK: - Network

    func testOHTTPEndpointsNetworkDetection() {
        // ZIP #10: network is statically configured, not inferred from hostname.
        // Only the two known gateway hosts have a configured network.
        XCTAssertEqual(OHTTPEndpoints.network(for: "ohttp-gateway-testnet.example"), "testnet")
        XCTAssertEqual(OHTTPEndpoints.network(for: "ohttp-gateway.example"), "mainnet")
        XCTAssertNil(OHTTPEndpoints.network(for: "cmc.zodl.com"))
        XCTAssertNil(OHTTPEndpoints.network(for: "vote.zodl.com"))
        XCTAssertNil(OHTTPEndpoints.network(for: "unknown.zodl.com"))
    }

    /// ZIP #10: The network is statically configured (NetworkRule::KnownHosts), not inferred from the host name.
    /// Only ohttp-gateway.example (mainnet) and ohttp-gateway-testnet.example (testnet) have a configured
    /// network; all other hosts return nil and would be rejected before signature verification.
    func testTheCoreAndOHTTPEndpointsAgreeOnTheNetworkOfAHost() throws {
        // Test the two known gateway hosts (case-insensitive)
        for (host, expectedNetwork) in [
            ("ohttp-gateway-testnet.example", "testnet"),
            ("OHTTP-GATEWAY-TESTNET.ZODL.COM", "testnet"),
            ("ohttp-gateway.example", "mainnet"),
            ("OHTTP-GATEWAY.ZODL.COM", "mainnet")
        ] {
            guard let network = OHTTPEndpoints.network(for: host) else {
                XCTFail("\(host) should have a configured network")
                continue
            }
            XCTAssertEqual(network, expectedNetwork, "\(host)")
            let otherNetwork = network == "testnet" ? "mainnet" : "testnet"

            // An envelope for the network the host is on gets past the network check ...
            let own = try XCTUnwrap(failure(of: envelope(network: network, keyId: "00000000"), host: host), host)
            XCTAssertFalse(own.contains("signed for"), "\(host): \(own)")
            // ... and one for the other network does not.
            let other = try XCTUnwrap(failure(of: envelope(network: otherNetwork), host: host), host)
            XCTAssertTrue(other.contains("signed for \(otherNetwork), not \(network)"), "\(host): \(other)")
        }

        // Unknown hosts have no configured network and would be rejected by the native layer
        for host in ["cmc.zodl.com", "vote.zodl.com", "unknown.zodl.com", "testnet.example.com"] {
            XCTAssertNil(OHTTPEndpoints.network(for: host), "\(host) should have no configured network")
        }
    }
}
