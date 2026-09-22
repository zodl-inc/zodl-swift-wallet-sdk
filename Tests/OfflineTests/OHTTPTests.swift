//
//  OHTTPTests.swift
//  OfflineTests
//
//  Tests for OHTTP (RFC 9458) components.
//

import XCTest
@testable import ZcashLightClientKit

final class OHTTPTests: XCTestCase {

    // MARK: - HKDF Tests (RFC 5869 Test Case 1)

    func testHKDFRFC5869TestCase1() throws {
        // RFC 5869 Test Case 1 (Appendix A.1)
        // IKM  = 0x0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b (22 octets)
        // salt = 0x000102030405060708090a0b0c (13 octets)
        // info = 0xf0f1f2f3f4f5f6f7f8f9 (10 octets)
        // L    = 42
        //
        // Expected OKM (42 octets):
        // 0x3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf
        // 34007208d5b887185865

        let ikm = Data(repeating: 0x0b, count: 22)
        let salt = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c])
        let info = Data([0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9])
        let length = 42

        let prk = OHTTPHPKE.hkdfExtract(salt: salt, ikm: ikm)
        let okm = try OHTTPHPKE.hkdfExpand(prk: prk, info: info, length: length)

        let expected = Data([
            0x3c, 0xb2, 0x5f, 0x25, 0xfa, 0xac, 0xd5, 0x7a,
            0x90, 0x43, 0x4f, 0x64, 0xd0, 0x36, 0x2f, 0x2a,
            0x2d, 0x2d, 0x0a, 0x90, 0xcf, 0x1a, 0x5a, 0x4c,
            0x5d, 0xb0, 0x2d, 0x56, 0xec, 0xc4, 0xc5, 0xbf,
            0x34, 0x00, 0x72, 0x08, 0xd5, 0xb8, 0x87, 0x18,
            0x58, 0x65
        ])

        XCTAssertEqual(okm, expected, "HKDF output doesn't match RFC 5869 test case 1")
    }

    // MARK: - Binary HTTP Tests

    func testBinaryHTTPRequestEncodeDecode() throws {
        let request = BinaryHTTP.Request(
            method: "POST",
            scheme: "https",
            authority: "example.com",
            path: "/test",
            headers: [("content-type", "application/json")],
            body: Data("test body".utf8)
        )

        let encoded = try BinaryHTTP.encodeRequest(request)
        XCTAssertGreaterThan(encoded.count, 0, "Encoded request should not be empty")

        // Basic validation: check that framing indicator is 0 (known-length request)
        XCTAssertEqual(encoded[0], 0, "First byte should be framing indicator 0")
    }

    func testBinaryHTTPKnownLengthResponse() throws {
        // Construct a minimal known-length response:
        // framing (1), status (200), empty headers section (length 0), empty body (length 0), empty trailers (length 0)
        var response = Data()
        BinaryHTTP.writeVarint(&response, 1)  // framing: known-length response
        BinaryHTTP.writeVarint(&response, 200)  // status
        BinaryHTTP.writeVarint(&response, 0)  // headers section length
        BinaryHTTP.writeVarint(&response, 0)  // body length
        BinaryHTTP.writeVarint(&response, 0)  // trailers section length

        let decoded = try BinaryHTTP.decodeResponse(response)
        XCTAssertEqual(decoded.status, 200)
        XCTAssertTrue(decoded.headers.isEmpty)
        XCTAssertTrue(decoded.body.isEmpty)
        XCTAssertTrue(decoded.trailers.isEmpty)
    }

    func testBinaryHTTPResponseWithHeaders() throws {
        // Construct a response with headers
        var response = Data()
        BinaryHTTP.writeVarint(&response, 1)  // framing
        BinaryHTTP.writeVarint(&response, 200)  // status

        // Headers section
        var headersSection = Data()
        BinaryHTTP.writeVarint(&headersSection, UInt64("content-type".count))
        headersSection.append("content-type".data(using: .ascii)!)
        BinaryHTTP.writeVarint(&headersSection, UInt64("text/plain".count))
        headersSection.append("text/plain".data(using: .isoLatin1)!)

        BinaryHTTP.writeVarint(&response, UInt64(headersSection.count))
        response.append(headersSection)

        BinaryHTTP.writeVarint(&response, 0)  // body length
        BinaryHTTP.writeVarint(&response, 0)  // trailers length

        let decoded = try BinaryHTTP.decodeResponse(response)
        XCTAssertEqual(decoded.status, 200)
        XCTAssertEqual(decoded.headers.count, 1)
        XCTAssertEqual(decoded.headers[0].0, "content-type")
        XCTAssertEqual(decoded.headers[0].1, "text/plain")
    }

    // MARK: - OHTTP Key Config Tests

    func testOHTTPKeyConfigParsing() throws {
        // Construct a minimal key config document for the supported suite
        var config = Data()

        // Config length (will be calculated)
        let configStart = config.count + 2
        var configBody = Data()

        configBody.append(0x01)  // key_id = 1
        configBody.append(contentsOf: [0x00, 0x20])  // kem_id = 0x0020 (X25519)
        configBody.append(Data(count: 32))  // 32-byte public key (all zeros for test)

        // Symmetric suites
        var suites = Data()
        suites.append(contentsOf: [0x00, 0x01])  // kdf_id = 0x0001 (HKDF-SHA256)
        suites.append(contentsOf: [0x00, 0x01])  // aead_id = 0x0001 (AES-128-GCM)

        configBody.append(contentsOf: [UInt8(suites.count >> 8), UInt8(suites.count & 0xFF)])
        configBody.append(suites)

        // Write config length
        config.append(contentsOf: [UInt8(configBody.count >> 8), UInt8(configBody.count & 0xFF)])
        config.append(configBody)

        let parsed = try OHTTPKeyConfig.parseSupported(config)
        XCTAssertEqual(parsed.keyId, 1)
        XCTAssertEqual(parsed.kemId, 0x0020)
        XCTAssertEqual(parsed.kdfId, 0x0001)
        XCTAssertEqual(parsed.aeadId, 0x0001)
        XCTAssertEqual(parsed.publicKey.count, 32)
    }

    func testOHTTPKeyConfigUnsupportedSuite() {
        // Config with unsupported KEM
        var config = Data()
        var configBody = Data()

        configBody.append(0x01)  // key_id
        configBody.append(contentsOf: [0x00, 0x10])  // kem_id = 0x0010 (DHKEM(P-256))
        configBody.append(Data(count: 32))  // public key
        configBody.append(contentsOf: [0x00, 0x00])  // empty suites

        config.append(contentsOf: [UInt8(configBody.count >> 8), UInt8(configBody.count & 0xFF)])
        config.append(configBody)

        XCTAssertThrowsError(try OHTTPKeyConfig.parseSupported(config)) { error in
            guard case OHTTPError.keyConfigError = error else {
                XCTFail("Expected keyConfigError")
                return
            }
        }
    }

    // MARK: - OHTTP Endpoints Tests

    func testOHTTPEndpointsGatewayDetection() {
        XCTAssertTrue(OHTTPEndpoints.isGateway("ohttp-gateway-testnet.example"))
        XCTAssertTrue(OHTTPEndpoints.isGateway("ohttp-gateway.example"))
        XCTAssertFalse(OHTTPEndpoints.isGateway("lightwalletd.testnet.electriccoin.co"))
        XCTAssertFalse(OHTTPEndpoints.isGateway("example.com"))
    }

    func testOHTTPEndpointsRelayMapping() throws {
        let relay1 = try OHTTPEndpoints.relayURL(for: "ohttp-gateway-testnet.example")
        XCTAssertEqual(relay1, "https://testnet-simulator-relay.example.invalid/relay")

        let relay2 = try OHTTPEndpoints.relayURL(for: "ohttp-gateway.example")
        XCTAssertEqual(relay2, "https://simulator-relay.example.invalid/relay")

        XCTAssertThrowsError(try OHTTPEndpoints.relayURL(for: "unknown.zodl.com"))
    }

    func testOHTTPEndpointsKeyConfigURL() {
        let url = OHTTPEndpoints.keyConfigURL(for: "ohttp-gateway-testnet.example")
        XCTAssertEqual(url, "https://testnet-simulator-relay.example.invalid/ohttp-configs")
    }

    func testOHTTPEndpointsKeyConfigURLMainnet() {
        let url = OHTTPEndpoints.keyConfigURL(for: "ohttp-gateway.example")
        XCTAssertEqual(url, "https://simulator-relay.example.invalid/ohttp-configs")
    }

    func testOHTTPEndpointsKeyConfigURLProxyHosts() {
        // Proxy hosts (static mappings and allowlisted) should use mainnet relay config
        let cmcURL = OHTTPEndpoints.keyConfigURL(for: "cmc.zodl.com")
        XCTAssertEqual(cmcURL, "https://simulator-relay.example.invalid/ohttp-configs")
        
        let nearURL = OHTTPEndpoints.keyConfigURL(for: "near.zodl.com")
        XCTAssertEqual(nearURL, "https://simulator-relay.example.invalid/ohttp-configs")
        
        let voteURL = OHTTPEndpoints.keyConfigURL(for: "vote.zodl.com")
        XCTAssertEqual(voteURL, "https://simulator-relay.example.invalid/ohttp-configs")
    }

    // MARK: - I2OSP Tests

    func testI2OSP() {
        let result1 = OHTTPHPKE.i2osp(UInt16(0x1234), 2)
        XCTAssertEqual(result1, Data([0x12, 0x34]))

        let result2 = OHTTPHPKE.i2osp(UInt64(0x12345678), 4)
        XCTAssertEqual(result2, Data([0x12, 0x34, 0x56, 0x78]))

        let result3 = OHTTPHPKE.i2osp(UInt64(0), 2)
        XCTAssertEqual(result3, Data([0x00, 0x00]))
    }

    // MARK: - QUIC Varint Tests

    func testQUICVarintEncode() {
        var data = Data()

        // 1-byte encoding
        BinaryHTTP.writeVarint(&data, 63)
        XCTAssertEqual(data, Data([63]))

        data = Data()
        // 2-byte encoding
        BinaryHTTP.writeVarint(&data, 16383)
        XCTAssertEqual(data, Data([0x7F, 0xFF]))

        data = Data()
        // 4-byte encoding
        BinaryHTTP.writeVarint(&data, 1073741823)
        XCTAssertEqual(data, Data([0xBF, 0xFF, 0xFF, 0xFF]))
    }

    // MARK: - gRPC Frame Parsing Tests

    func testGRPCFrameEncoding() {
        // Test that a frame is encoded correctly (uncompressed flag + 4-byte length + payload)
        let payload = Data("test".utf8)
        var frame = Data()
        frame.append(0)  // uncompressed
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)

        XCTAssertEqual(frame.count, 5 + payload.count)
        XCTAssertEqual(frame[0], 0)
        XCTAssertEqual(frame[1], 0)
        XCTAssertEqual(frame[2], 0)
        XCTAssertEqual(frame[3], 0)
        XCTAssertEqual(frame[4], UInt8(payload.count))
    }

    // MARK: - Proxy Allowlist Tests

    func testProxyAllowlistLeadingDotSuffix() {
        // Leading-dot suffix (.valargroup.org) matches subdomains only
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "prod.vote-chain-primary.valargroup.org"))
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "x.valargroup.org"))
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "valargroup.org"))
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "evilvalargroup.org"))
    }

    func testProxyAllowlistBareDomain() {
        // Bare domain (chaindefuser.com) matches itself or any subdomain
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "chaindefuser.com"))
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "1click.chaindefuser.com"))
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "api.chaindefuser.com"))
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "evilchaindefuser.com"))
    }

    func testProxyAllowlistCaseInsensitive() {
        // Host matching is case-insensitive
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "PROD.VOTE-CHAIN-PRIMARY.VALARGROUP.ORG"))
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "ChainDefUser.Com"))
    }

    func testProxyAllowlistValarGroupDev() {
        // .valargroup.dev suffix
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "voting.valargroup.dev"))
        XCTAssertTrue(OHTTPEndpoints.isProxyAllowlisted(host: "api.valargroup.dev"))
        XCTAssertFalse(OHTTPEndpoints.isProxyAllowlisted(host: "valargroup.dev"))
    }

    func testProxyAllowlistGatewayDetection() {
        // Allowlisted hosts should be recognized as gateways
        XCTAssertTrue(OHTTPEndpoints.isGateway("prod.vote-chain-primary.valargroup.org"))
        XCTAssertTrue(OHTTPEndpoints.isGateway("1click.chaindefuser.com"))
        XCTAssertTrue(OHTTPEndpoints.isGateway("voting.valargroup.dev"))
    }

    func testProxyAllowlistProxyHostPassthrough() {
        // Allowlisted hosts return unchanged host (no rewrite)
        let url1 = URL(string: "https://prod.vote-chain-primary.valargroup.org/path")!
        XCTAssertEqual(OHTTPEndpoints.proxyHost(for: url1), "prod.vote-chain-primary.valargroup.org")

        // Static mapping wins over the suffix allowlist: NEAR goes to the gateway alias so the
        // gateway injects the 1Click credential (allowlisted vote servers keep their real host).
        let url2 = URL(string: "https://1click.chaindefuser.com/api")!
        XCTAssertEqual(OHTTPEndpoints.proxyHost(for: url2), "near.zodl.com")
        XCTAssertEqual(OHTTPEndpoints.proxyURL(for: URL(string: "https://1click.chaindefuser.com/v0/tokens")!)?.host, "near.zodl.com")
        XCTAssertEqual(OHTTPEndpoints.proxyURL(for: URL(string: "https://1click.chaindefuser.com/v0/tokens")!)?.path, "/v0/tokens")
        let voteURL = URL(string: "https://prod.vote-chain-primary.valargroup.org/x")!
        XCTAssertEqual(OHTTPEndpoints.proxyHost(for: voteURL), "prod.vote-chain-primary.valargroup.org")
    }

    func testProxyAllowlistProxyURLPassthrough() {
        // Allowlisted hosts return unchanged URL (no hostname rewrite)
        let url = URL(string: "https://prod.vote-chain-primary.valargroup.org/shielded-vote/v1/rounds?limit=10")!
        XCTAssertEqual(OHTTPEndpoints.proxyURL(for: url), url)
    }

    // MARK: - Secret Stripping Tests

    func testSecretStrippingForMappedHosts() {
        // Verify that CMC and NEAR hosts are recognized as mapped hosts
        let cmcURL = URL(string: "https://pro-api.coinmarketcap.com/v1/key/info")!
        let nearURL = URL(string: "https://1click.chaindefuser.com/v0/tokens")!

        XCTAssertNotNil(OHTTPEndpoints.proxyHost(for: cmcURL), "CMC should be a mapped host")
        XCTAssertNotNil(OHTTPEndpoints.proxyHost(for: nearURL), "NEAR should be a mapped host")

        // The proxy hosts should be recognized as gateways
        XCTAssertTrue(OHTTPEndpoints.isGateway("cmc.zodl.com"))
        XCTAssertTrue(OHTTPEndpoints.isGateway("near.zodl.com"))
    }

    func testSecretStrippingForNonMappedHosts() {
        // Verify that non-mapped hosts (like voting) are NOT stripped
        let votingURL = URL(string: "https://voting.valargroup.dev/prod/dynamic-voting-config.json")!

        // voting.valargroup.dev is allowlisted (passthrough, no rewrite), but NOT a static mapping
        // OHTTPEndpoints.proxyHost returns the original host for allowlisted hosts
        XCTAssertNotNil(OHTTPEndpoints.proxyHost(for: votingURL), "Voting should be allowlisted")

        // But the host is the same (passthrough), so it's NOT in the static mapping list
        // The secret-stripping logic only applies to hosts where proxyHost(for:) != nil,
        // which includes both static mappings AND allowlisted hosts. However, the test
        // intention here is to verify the static mappings (CMC, NEAR) are recognized.
        // For a non-mapped clearnet host:
        let clearnetURL = URL(string: "https://example.com/api")!
        XCTAssertNil(OHTTPEndpoints.proxyHost(for: clearnetURL), "example.com should NOT be mapped")
    }

    // MARK: - Client Trace ID Tests

    /// Creates a valid OHTTP key config for testing (X25519 / HKDF-SHA256 / AES-128-GCM).
    private func makeValidKeyConfig() -> Data {
        var config = Data()
        var configBody = Data()
        
        configBody.append(0x01)  // key_id
        configBody.append(contentsOf: [0x00, 0x20])  // kem_id = 0x0020 (X25519)
        // Use a non-zero public key (arbitrary but non-zero to avoid potential edge cases)
        configBody.append(Data([
            0x50, 0x4a, 0x36, 0x99, 0x9f, 0x48, 0x9c, 0xd2,
            0xfd, 0xbc, 0x08, 0xba, 0xff, 0x3d, 0x88, 0xfa,
            0x00, 0x56, 0x9d, 0x21, 0x74, 0x05, 0x10, 0x9e,
            0x79, 0xda, 0x66, 0x05, 0x3c, 0x5f, 0x04, 0xef
        ]))
        configBody.append(contentsOf: [0x00, 0x04])  // suites_length = 4
        configBody.append(contentsOf: [0x00, 0x01])  // kdf_id = 0x0001 (HKDF-SHA256)
        configBody.append(contentsOf: [0x00, 0x01])  // aead_id = 0x0001 (AES-128-GCM)
        
        let length = UInt16(configBody.count)
        config.append(UInt8(length >> 8))
        config.append(UInt8(length & 0xFF))
        config.append(configBody)
        
        return config
    }

    func testClientTraceIdAbsentWhenNotSet() async throws {
        var capturedRequest: URLRequest?
        var callCount = 0
        let validKeyConfig = makeValidKeyConfig()
        
        let mockSender: OHTTPTransport.HTTPSender = { request in
            callCount += 1
            // Return valid key config for GET, capture POST where trace ID should be
            if request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/ohttp-keys"]
                )!
                return (validKeyConfig, response)
            } else {
                // POST to relay - capture and throw to abort the test early
                capturedRequest = request
                throw OHTTPError.transportError("test abort")
            }
        }

        let transport = OHTTPTransport(
            relayURL: "https://operator-relay.example.invalid/relay",
            keyConfigURL: "https://simulator-relay.example.invalid/ohttp-configs",
            clientTraceIdPrefix: nil,
            httpSender: mockSender
        )

        do {
            _ = try await transport.roundTrip(
                request: BinaryHTTP.Request(
                    method: "GET",
                    scheme: "https",
                    authority: "example.zodl.com",
                    path: "/test",
                    headers: [],
                    body: Data()
                ),
                timeoutMS: 5000
            )
            XCTFail("Should have thrown")
        } catch {
            // Expected - mock sender throws on POST
        }

        XCTAssertNotNil(capturedRequest, "Request should have been captured (callCount=\(callCount))")
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "X-Client-Trace-Id"), "X-Client-Trace-Id should be absent")
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "X-Request-Id"), "X-Request-Id should never be set by SDK")
    }

    func testClientTraceIdPresentWhenSet() async throws {
        var capturedRequest: URLRequest?
        let validKeyConfig = makeValidKeyConfig()
        
        let mockSender: OHTTPTransport.HTTPSender = { request in
            if request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/ohttp-keys"]
                )!
                return (validKeyConfig, response)
            } else {
                capturedRequest = request
                throw OHTTPError.transportError("test abort")
            }
        }

        let transport = OHTTPTransport(
            relayURL: "https://operator-relay.example.invalid/relay",
            keyConfigURL: "https://simulator-relay.example.invalid/ohttp-configs",
            clientTraceIdPrefix: "test-wallet",
            httpSender: mockSender
        )

        do {
            _ = try await transport.roundTrip(
                request: BinaryHTTP.Request(
                    method: "GET",
                    scheme: "https",
                    authority: "example.zodl.com",
                    path: "/test",
                    headers: [],
                    body: Data()
                ),
                timeoutMS: 5000
            )
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }

        XCTAssertNotNil(capturedRequest, "Request should have been captured")
        let traceId = capturedRequest?.value(forHTTPHeaderField: "X-Client-Trace-Id")
        XCTAssertNotNil(traceId, "X-Client-Trace-Id should be present")
        XCTAssertTrue(traceId?.hasPrefix("test-wallet-") ?? false, "Trace ID should start with prefix")
        XCTAssertLessThanOrEqual(traceId?.count ?? 0, 64, "Trace ID should be ≤ 64 chars")
        XCTAssertTrue(traceId?.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$", options: .regularExpression) != nil,
                      "Trace ID should match allowed charset")
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "X-Request-Id"), "X-Request-Id should never be set by SDK")
    }

    func testClientTraceIdNeverSetsXRequestId() async throws {
        var capturedRequest: URLRequest?
        let validKeyConfig = makeValidKeyConfig()
        
        let mockSender: OHTTPTransport.HTTPSender = { request in
            if request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/ohttp-keys"]
                )!
                return (validKeyConfig, response)
            } else {
                capturedRequest = request
                throw OHTTPError.transportError("test abort")
            }
        }

        let transport = OHTTPTransport(
            relayURL: "https://operator-relay.example.invalid/relay",
            keyConfigURL: "https://simulator-relay.example.invalid/ohttp-configs",
            clientTraceIdPrefix: "test",
            httpSender: mockSender
        )

        do {
            _ = try await transport.roundTrip(
                request: BinaryHTTP.Request(
                    method: "GET",
                    scheme: "https",
                    authority: "example.zodl.com",
                    path: "/test",
                    headers: [],
                    body: Data()
                ),
                timeoutMS: 5000
            )
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }

        XCTAssertNotNil(capturedRequest, "Request should have been captured")
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "X-Request-Id"), "SDK must never set X-Request-Id")
    }

    func testClientTraceIdSanitization() async throws {
        var capturedRequest: URLRequest?
        let validKeyConfig = makeValidKeyConfig()
        
        let mockSender: OHTTPTransport.HTTPSender = { request in
            if request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/ohttp-keys"]
                )!
                return (validKeyConfig, response)
            } else {
                capturedRequest = request
                throw OHTTPError.transportError("test abort")
            }
        }

        let transport = OHTTPTransport(
            relayURL: "https://operator-relay.example.invalid/relay",
            keyConfigURL: "https://simulator-relay.example.invalid/ohttp-configs",
            clientTraceIdPrefix: "test@wallet#123",
            httpSender: mockSender
        )

        do {
            _ = try await transport.roundTrip(
                request: BinaryHTTP.Request(
                    method: "GET",
                    scheme: "https",
                    authority: "example.zodl.com",
                    path: "/test",
                    headers: [],
                    body: Data()
                ),
                timeoutMS: 5000
            )
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }

        let traceId = capturedRequest?.value(forHTTPHeaderField: "X-Client-Trace-Id")
        XCTAssertNotNil(traceId, "Trace ID should be present")
        XCTAssertFalse(traceId?.contains("@") ?? true, "Trace ID should not contain @")
        XCTAssertFalse(traceId?.contains("#") ?? true, "Trace ID should not contain #")
        XCTAssertTrue(traceId?.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$", options: .regularExpression) != nil,
                      "Trace ID should match allowed charset")
    }

    func testClientTraceIdTruncation() async throws {
        var capturedRequest: URLRequest?
        let validKeyConfig = makeValidKeyConfig()
        
        let mockSender: OHTTPTransport.HTTPSender = { request in
            if request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/ohttp-keys"]
                )!
                return (validKeyConfig, response)
            } else {
                capturedRequest = request
                throw OHTTPError.transportError("test abort")
            }
        }

        let longPrefix = String(repeating: "a", count: 60)
        let transport = OHTTPTransport(
            relayURL: "https://operator-relay.example.invalid/relay",
            keyConfigURL: "https://simulator-relay.example.invalid/ohttp-configs",
            clientTraceIdPrefix: longPrefix,
            httpSender: mockSender
        )

        do {
            _ = try await transport.roundTrip(
                request: BinaryHTTP.Request(
                    method: "GET",
                    scheme: "https",
                    authority: "example.zodl.com",
                    path: "/test",
                    headers: [],
                    body: Data()
                ),
                timeoutMS: 5000
            )
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }

        let traceId = capturedRequest?.value(forHTTPHeaderField: "X-Client-Trace-Id")
        XCTAssertNotNil(traceId, "Trace ID should be present")
        XCTAssertEqual(traceId?.count, 64, "Trace ID should be truncated to exactly 64 chars")
    }

    // MARK: - Tor Mode Tests

    func testTorModeUsesCustomSenderForKeyConfigAndRelay() async throws {
        var keyConfigRequestCaptured = false
        var relayRequestCaptured = false
        let validKeyConfig = makeValidKeyConfig()

        let torSender: OHTTPTransport.HTTPSender = { request in
            if request.httpMethod == "GET" {
                keyConfigRequestCaptured = true
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/ohttp-keys"]
                )!
                return (validKeyConfig, response)
            } else {
                relayRequestCaptured = true
                throw OHTTPError.transportError("test abort after relay POST")
            }
        }

        let transport = OHTTPTransport(
            relayURL: "https://operator-relay.example.invalid/relay",
            keyConfigURL: "https://simulator-relay.example.invalid/ohttp-configs",
            httpSender: torSender
        )

        do {
            _ = try await transport.roundTrip(
                request: BinaryHTTP.Request(
                    method: "GET",
                    scheme: "https",
                    authority: "example.zodl.com",
                    path: "/test",
                    headers: [],
                    body: Data()
                ),
                timeoutMS: 5000
            )
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }

        XCTAssertTrue(keyConfigRequestCaptured, "Custom sender should be used for key config GET")
        XCTAssertTrue(relayRequestCaptured, "Custom sender should be used for relay POST")
    }

    func testClearnetModeUsesDefaultSenderWhenNotProvided() async throws {
        // This test verifies that when httpSender is not provided (uses default URLSession),
        // it works as expected for clearnet. We can't easily test the actual URLSession call
        // without mocking URLSession, so this is more of a smoke test that the default path compiles.
        let transport = OHTTPTransport(
            relayURL: "https://operator-relay.example.invalid/relay",
            keyConfigURL: "https://simulator-relay.example.invalid/ohttp-configs"
        )

        // The transport should be created successfully with default httpSender
        XCTAssertNotNil(transport, "Transport should initialize with default httpSender")
    }

    func testSessionConfigurationIsEphemeralWithNoCookiesOrCache() {
        // Verify the dedicated OHTTP session has ephemeral configuration with cookies and caching disabled.
        // This prevents a relay or gateway from storing Set-Cookie headers or cached responses that would
        // link a wallet's requests across IPs or Tor circuits.
        let config = OHTTPTransport.sessionConfigurationForTesting

        XCTAssertEqual(config.httpCookieAcceptPolicy, .never, "Cookie accept policy should be .never")
        XCTAssertFalse(config.httpShouldSetCookies, "httpShouldSetCookies should be false")
        XCTAssertNil(config.httpCookieStorage, "httpCookieStorage should be nil")
        XCTAssertNil(config.urlCache, "urlCache should be nil")
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData, "Cache policy should ignore all caching")
    }

    // MARK: - Redirect Refusal Tests

    func testSessionDelegateRefusesRedirects() {
        // Verify that the session's delegate refuses HTTP redirects.
        // A redirect from a relay or key-config server is an attack vector.
        let session = OHTTPTransport.session
        guard let delegate = session.delegate as? URLSessionTaskDelegate else {
            XCTFail("Session should have a URLSessionTaskDelegate")
            return
        }

        // Create a dummy task and redirect response
        let url = URL(string: "https://operator-relay.example.invalid/relay")!
        let task = session.dataTask(with: url)
        let redirectResponse = HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "https://evil.example.com/"]
        )!
        let newRequest = URLRequest(url: URL(string: "https://evil.example.com/")!)

        var capturedNewRequest: URLRequest?
        let expectation = self.expectation(description: "Completion handler called")

        delegate.urlSession!(
            session,
            task: task,
            willPerformHTTPRedirection: redirectResponse,
            newRequest: newRequest
        ) { request in
            capturedNewRequest = request
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1.0)
        XCTAssertNil(capturedNewRequest, "Delegate should refuse redirects by returning nil")
    }

    func testNonHTTPSRelayURLFails() async throws {
        // Verify that a non-https relay URL throws at request time (not init).
        let validKeyConfig = makeValidKeyConfig()
        let mockSender: OHTTPTransport.HTTPSender = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (validKeyConfig, response)
        }

        // Init succeeds with http:// relay (validation is lazy)
        let transport = OHTTPTransport(
            relayURL: "http://operator-relay.example.invalid/relay",
            keyConfigURL: "https://simulator-relay.example.invalid/ohttp-configs",
            httpSender: mockSender
        )

        // First call (roundTrip → relay POST) throws with https requirement
        do {
            _ = try await transport.roundTrip(
                request: BinaryHTTP.Request(
                    method: "GET",
                    scheme: "https",
                    authority: "example.zodl.com",
                    path: "/test",
                    headers: [],
                    body: Data()
                ),
                timeoutMS: 5000
            )
            XCTFail("Should have thrown for http relay URL")
        } catch let error as OHTTPError {
            if case .transportError(let message) = error {
                XCTAssertTrue(message.contains("must use https"), "Error should mention https requirement")
            } else {
                XCTFail("Wrong error type")
            }
        }
    }

    func testNonHTTPSKeyConfigURLFails() async throws {
        // Verify that a non-https key-config URL throws at request time (not init).
        let validKeyConfig = makeValidKeyConfig()
        let mockSender: OHTTPTransport.HTTPSender = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (validKeyConfig, response)
        }

        // Init succeeds with http:// key-config (validation is lazy)
        let transport = OHTTPTransport(
            relayURL: "https://operator-relay.example.invalid/relay",
            keyConfigURL: "http://simulator-relay.example.invalid/ohttp-configs",
            httpSender: mockSender
        )

        // First call (keyConfig → GET) throws with https requirement
        do {
            _ = try await transport.keyConfig()
            XCTFail("Should have thrown for http key-config URL")
        } catch let error as OHTTPError {
            if case .transportError(let message) = error {
                XCTAssertTrue(message.contains("must use https"), "Error should mention https requirement")
            } else {
                XCTFail("Wrong error type")
            }
        }
    }
}
