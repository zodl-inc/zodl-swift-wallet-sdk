//
//  OHTTPNativeTests.swift
//  OfflineTests
//
//  The Swift side of the shared OHTTP core: the request text encoding, the packed header lists, the
//  single-use response handle, and the C functions behind them (`zcashlc_ohttp_*`, iOS profile).
//  The protocol's own rules (signed envelope, key selection, Binary HTTP, HPKE) are tested in the core
//  (`zodl-inc/ohttp`, `client/`) and in `rust/src/ohttp.rs`.
//

import XCTest
import CryptoKit
@testable import ZODLSwiftWalletSDK

final class OHTTPNativeTests: XCTestCase {
    private func makeKey(id: UInt8 = 0x05) -> OHTTPVerifiedKey {
        var bytes = Data([id])
        bytes.append(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        return OHTTPVerifiedKey(bytes: bytes, notAfter: UInt64.max, isTestnet: true)
    }

    private func makeRequest(path: String = "/test", body: Data = Data()) -> OHTTPRequest {
        OHTTPRequest(
            method: "POST",
            scheme: "https",
            authority: "gateway.test.zodl.com",
            path: path,
            headers: [("Content-Type", "application/grpc"), ("x-value", "caf\u{00e9}")],
            body: body
        )
    }

    // MARK: - Packed field lists

    func testFieldListRoundTrips() throws {
        let fields: [(Data, Data)] = [
            (Data("content-type".utf8), Data("application/grpc".utf8)),
            (Data("empty".utf8), Data()),
            (Data([0x80, 0xff]), Data([0x00, 0x01]))
        ]

        let packed = try OHTTPFieldList.pack(fields)
        let unpacked = try OHTTPFieldList.unpack(packed)

        XCTAssertEqual(unpacked.count, fields.count)
        for (expected, actual) in zip(fields, unpacked) {
            XCTAssertEqual(expected.0, actual.0)
            XCTAssertEqual(expected.1, actual.1)
        }
    }

    func testFieldListLayoutIsLengthPrefixedBigEndian() throws {
        let packed = try OHTTPFieldList.pack([(Data("ab".utf8), Data("c".utf8))])

        XCTAssertEqual(packed, Data([0, 0, 0, 2, 0x61, 0x62, 0, 0, 0, 1, 0x63]))
        XCTAssertTrue(try OHTTPFieldList.unpack(Data()).isEmpty)
    }

    func testMalformedFieldListsAreErrors() {
        let malformed: [Data] = [
            Data([0, 0, 0]),                        // truncated length
            Data([0, 0, 0, 9, 0x61]),               // length past the end
            Data([0xff, 0xff, 0xff, 0xff]),         // huge length
            Data([0, 0, 0, 1, 0x61])                // a name without a value
        ]
        for packed in malformed {
            XCTAssertThrowsError(try OHTTPFieldList.unpack(packed), "\(Array(packed))")
        }
    }

    func testFieldListUnpackHandlesADataSlice() throws {
        let packed = try OHTTPFieldList.pack([(Data("a".utf8), Data("b".utf8))])
        var padded = Data([0xaa, 0xbb])
        padded.append(packed)

        let unpacked = try OHTTPFieldList.unpack(padded.dropFirst(2))

        XCTAssertEqual(unpacked.count, 1)
        XCTAssertEqual(unpacked[0].0, Data("a".utf8))
    }

    func testResponseHeadersAreReadAsISO88591() {
        XCTAssertEqual(OHTTPFieldList.latin1(Data([0x63, 0x61, 0x66, 0xe9])), "caf\u{00e9}")
        XCTAssertEqual(OHTTPFieldList.latin1(Data([0x80, 0xff])), "\u{0080}\u{00ff}")
    }

    func testResponseFieldLookupSearchesHeadersThenTrailersCaseInsensitively() {
        let response = OHTTPResponse(
            status: 200,
            headers: [("Content-Type", "application/grpc")],
            body: Data(),
            trailers: [("Grpc-Status", "0")]
        )

        XCTAssertEqual(response.field("content-type"), "application/grpc")
        XCTAssertEqual(response.field("GRPC-STATUS"), "0")
        XCTAssertNil(response.field("missing"))
    }

    // MARK: - Request text

    func testRequestTextBecomesASCIIAndLatin1Bytes() throws {
        let bytes = try makeRequest().nativeBytes()

        XCTAssertEqual(bytes.method, Data("POST".utf8))
        XCTAssertEqual(bytes.scheme, Data("https".utf8))
        XCTAssertEqual(bytes.authority, Data("gateway.test.zodl.com".utf8))
        XCTAssertEqual(bytes.path, Data("/test".utf8))
        let fields = try OHTTPFieldList.unpack(bytes.headers)
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields[1].1, Data([0x63, 0x61, 0x66, 0xe9]), "A header value is ISO-8859-1")
    }

    func testRequestTextOutsideItsEncodingIsAnErrorNotATrap() {
        let bad: [OHTTPRequest] = [
            OHTTPRequest(method: "G\u{00e9}T", scheme: "https", authority: "a", path: "/", headers: [], body: Data()),
            OHTTPRequest(method: "GET", scheme: "h\u{20ac}", authority: "a", path: "/", headers: [], body: Data()),
            OHTTPRequest(method: "GET", scheme: "https", authority: "\u{00e9}", path: "/", headers: [], body: Data()),
            OHTTPRequest(method: "GET", scheme: "https", authority: "a", path: "/\u{20ac}", headers: [], body: Data()),
            OHTTPRequest(method: "GET", scheme: "https", authority: "a", path: "/", headers: [("n\u{00e9}", "v")], body: Data()),
            OHTTPRequest(method: "GET", scheme: "https", authority: "a", path: "/", headers: [("n", "\u{20ac}")], body: Data())
        ]
        for request in bad {
            XCTAssertThrowsError(try request.nativeBytes()) { error in
                guard case OHTTPError.binaryHttpError(let message) = error else {
                    return XCTFail("Expected binaryHttpError, got \(error)")
                }
                XCTAssertFalse(message.contains("\u{20ac}") || message.contains("\u{00e9}"), "The message must not quote the text")
            }
        }
    }

    // MARK: - Native functions

    func testSignedConfigURLReplacesTheRelaySuffixWithoutTrimming() throws {
        XCTAssertEqual(
            try OHTTPNative.signedConfigURL(relayURL: "https://relay.example/relay"),
            "https://relay.example/ohttp-configs/signed"
        )
        XCTAssertEqual(
            try OHTTPNative.signedConfigURL(relayURL: "https://relay.example"),
            "https://relay.example/ohttp-configs/signed"
        )
        XCTAssertEqual(
            try OHTTPNative.signedConfigURL(relayURL: "https://relay.example/relay/"),
            "https://relay.example/relay//ohttp-configs/signed"
        )
    }

    func testProfileInfoIsTheIOSProfile() throws {
        let info = try OHTTPNative.profileInfo()

        XCTAssertEqual(info.postHeaders.map { "\($0.name): \($0.value)" }, [
            "Content-Type: message/ohttp-chunked-req",
            "Accept: message/ohttp-chunked-res",
            "Accept-Encoding: identity"
        ])
        XCTAssertEqual(info.keyFetchHeaders.map { "\($0.name): \($0.value)" }, ["Accept: application/ohttp-keys"])
        XCTAssertEqual(info.cacheRefreshMarginSecs, 0)
        XCTAssertTrue(info.dropBeforeRefetch)
        XCTAssertTrue(info.traceOnKeyFetch)
    }

    func testAKeyIsFreshUntilItsNotAfter() throws {
        let info = try OHTTPNative.profileInfo()
        let key = OHTTPVerifiedKey(bytes: makeKey().bytes, notAfter: 1_000, isTestnet: false)

        XCTAssertTrue(info.isFresh(key, at: Date(timeIntervalSince1970: 999.5)))
        XCTAssertFalse(info.isFresh(key, at: Date(timeIntervalSince1970: 1_000)))
        XCTAssertFalse(info.isFresh(key, at: Date(timeIntervalSince1970: 1_001)))
    }

    func testEncapsulateSealsEveryCallAfresh() throws {
        let key = makeKey(id: 0x07)
        let request = makeRequest(body: Data("payload".utf8))

        let first = try OHTTPNative.encapsulate(key: key, request: request)
        let second = try OHTTPNative.encapsulate(key: key, request: request)

        XCTAssertEqual(first.body.first, 0x07)
        XCTAssertEqual(first.body.dropFirst().prefix(6), Data([0x00, 0x20, 0x00, 0x01, 0x00, 0x01]))
        XCTAssertNotEqual(first.body, second.body, "A fresh ephemeral key and ciphertext every time")
        XCTAssertEqual(first.body.count, second.body.count)
    }

    func testEncapsulateRefusesAMalformedKey() {
        let short = OHTTPVerifiedKey(bytes: Data(repeating: 1, count: 32), notAfter: 1, isTestnet: true)

        XCTAssertThrowsError(try OHTTPNative.encapsulate(key: short, request: makeRequest()))
    }

    func testEncapsulateRefusesASealedRequestOverTenMebibytes() throws {
        let key = makeKey()
        let tooBig = makeRequest(body: Data(count: 10 * 1024 * 1024))

        XCTAssertThrowsError(try OHTTPNative.encapsulate(key: key, request: tooBig))
        // A request well inside the cap still seals.
        XCTAssertNoThrow(try OHTTPNative.encapsulate(key: key, request: makeRequest(body: Data(count: 1024 * 1024))))
    }

    // MARK: - The single-use response handle

    func testACompletedHandleCannotBeCompletedAgain() throws {
        let sealed = try OHTTPNative.encapsulate(key: makeKey(), request: makeRequest())

        let first = try sealed.pending.complete(status: 409, contentType: nil, body: Data("dup".utf8), attempt: 0)
        guard case .refused(let status, let detail) = first else {
            return XCTFail("Expected refused, got \(first)")
        }
        XCTAssertEqual(status, 409)
        XCTAssertEqual(detail, "dup")

        XCTAssertThrowsError(try sealed.pending.complete(status: 409, contentType: nil, body: Data(), attempt: 0)) { error in
            guard case OHTTPError.transportError(let message) = error else {
                return XCTFail("Expected transportError, got \(error)")
            }
            XCTAssertTrue(message.contains("already used"), message)
        }
    }

    func testAFailedCompletionStillConsumesTheHandle() throws {
        let sealed = try OHTTPNative.encapsulate(key: makeKey(), request: makeRequest())

        // A 200 that does not open is an error, and the handle is spent either way.
        XCTAssertThrowsError(
            try sealed.pending.complete(
                status: 200,
                contentType: "message/ohttp-chunked-res",
                body: OHTTPTestSupport.unopenableSealedResponse(),
                attempt: 0
            )
        )
        XCTAssertThrowsError(try sealed.pending.complete(status: 200, contentType: nil, body: Data(), attempt: 0)) { error in
            guard case OHTTPError.transportError(let message) = error else {
                return XCTFail("Expected transportError, got \(error)")
            }
            XCTAssertTrue(message.contains("already used"), message)
        }
    }

    func testARejectedArgumentLeavesTheHandleUsable() throws {
        let sealed = try OHTTPNative.encapsulate(key: makeKey(), request: makeRequest())

        XCTAssertThrowsError(try sealed.pending.complete(status: 70_000, contentType: nil, body: Data(), attempt: 0))

        let completed = try sealed.pending.complete(status: 503, contentType: nil, body: Data(), attempt: 0)
        guard case .refused(let status, _) = completed else {
            return XCTFail("Expected refused, got \(completed)")
        }
        XCTAssertEqual(status, 503)
    }

    func testA400OrA422IsRetriedOnceWhateverTheBody() throws {
        for status in [400, 422] {
            for body in [Data(), Data("Bad Request".utf8), Data("{\"error\":\"ohttp-key\"}".utf8)] {
                let first = try OHTTPNative.encapsulate(key: makeKey(), request: makeRequest())
                guard case .refetchKeyConfig = try first.pending.complete(status: status, contentType: nil, body: body, attempt: 0) else {
                    return XCTFail("\(status) on the first attempt must refetch the key")
                }

                // The sealing of the retry is a new one; a second 400 or 422 is final.
                let second = try OHTTPNative.encapsulate(key: makeKey(), request: makeRequest())
                guard case .refused(let refusedStatus, _) = try second.pending.complete(
                    status: status,
                    contentType: nil,
                    body: body,
                    attempt: 1
                ) else {
                    return XCTFail("\(status) on the second attempt must be refused")
                }
                XCTAssertEqual(refusedStatus, status)
            }
        }
    }

    func testTheRefusalDetailIsCutAtTwoHundredBytes() throws {
        let sealed = try OHTTPNative.encapsulate(key: makeKey(), request: makeRequest())

        let completed = try sealed.pending.complete(status: 500, contentType: nil, body: Data(repeating: 0x61, count: 500), attempt: 0)

        guard case .refused(_, let detail) = completed else {
            return XCTFail("Expected refused, got \(completed)")
        }
        XCTAssertEqual(detail.utf8.count, 200)
    }

    func testAnUnusedHandleIsReleasedWithoutCompleting() throws {
        // The post failed before `complete`: dropping the handle frees the native context.
        for _ in 0..<100 {
            _ = try OHTTPNative.encapsulate(key: makeKey(), request: makeRequest())
        }
    }
}

    // MARK: - DNS Fallback Helpers

    func testDNSQueryURLsFollowTheResolverOrderAndTheNetwork() throws {
        let mainnet = try OHTTPNative.dohQueryURLs(gatewayHost: "ohttp-gateway.example")
        XCTAssertEqual(mainnet.count, 2)
        XCTAssertTrue(mainnet[0].hasPrefix("https://cloudflare-dns.com/dns-query?"), mainnet[0])
        XCTAssertTrue(mainnet[1].hasPrefix("https://dns.google/resolve?"), mainnet[1])
        XCTAssertTrue(mainnet[1].contains("edns_client_subnet=0.0.0.0/0"), mainnet[1])
        XCTAssertTrue(mainnet.allSatisfy { $0.contains("ohttp-keys.example") && $0.contains("type=TXT") })

        let testnet = try OHTTPNative.dohQueryURLs(gatewayHost: "OHTTP-GATEWAY-TESTNET.zodl.com")
        XCTAssertTrue(testnet.allSatisfy { $0.contains("ohttp-keys-testnet.example") })
    }

    func testDNSQueryURLsRefuseAnUnknownGatewayHost() {
        XCTAssertThrowsError(try OHTTPNative.dohQueryURLs(gatewayHost: "gateway.example"))
    }

    func testDNSEnvelopeParsingWithRealFixture() throws {
        // Real captured Cloudflare mainnet DoH JSON response (2026-10-20)
        let cloudflareJSON = """
        {
          "Status": 0,
          "TC": false,
          "RD": true,
          "RA": true,
          "AD": false,
          "CD": false,
          "Question": [
            {
              "name": "ohttp-keys.example",
              "type": 16
            }
          ],
          "Answer": [
            {
              "name": "ohttp-keys.example",
              "type": 16,
              "TTL": 300,
              "data": "\\"eyJ2IjoxLCJuZXR3b3JrIjoibWFpbm5ldCIsImNvbmZpZ3MiOiJBQ2tEQUNEY0w0ei9KdWxPVzlSamREc3R3c2dsMmo2Vk9JWXRkOW95Y2J5M0hVT3FCd0FFQUFFQUFRPT0iLCJub3RfYmVmb3JlIjoxNzkyNTE1MzAwLCJub3RfYWZ0ZXIiOjE3OTI1MzY5MDAsImtleV9pZCI6ImJhOGEyZGJkIiwic2lnIjoiYVB4blc2L1VIOElvYkxTSXM\\" \\"2c1FQbmcrZjdGU1c2dVlZS25yZmhEMFZKWFRTVWNLWWw3WEdnM0MrcytzdEtHSXlnNVM4NHNvZEhsV2tpWFN1OHJtQ3c9PSJ9\\""
            }
          ]
        }
        """

        let dohBody = Data(cloudflareJSON.utf8)
        let envelope = try OHTTPNative.envelopeFromDohJSON(dohBody: dohBody, gatewayHost: "ohttp-gateway.example")

        XCTAssertFalse(envelope.isEmpty, "Parsed envelope should not be empty")
        XCTAssertEqual(envelope.count, 264, "Expected envelope length from fixture")

        // Verify the envelope can be parsed as JSON and has expected fields
        let json = try JSONSerialization.jsonObject(with: envelope) as? [String: Any]
        XCTAssertNotNil(json, "Envelope should be valid JSON")
        XCTAssertEqual(json?["v"] as? Int, 1, "Envelope version should be 1")
        XCTAssertEqual(json?["network"] as? String, "mainnet", "Network should be mainnet")
        XCTAssertEqual(json?["key_id"] as? String, "ba8a2dbd", "Key ID should match fixture")
    }
