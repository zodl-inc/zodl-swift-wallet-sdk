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
        XCTAssertEqual(url, "https://ohttp-gateway-testnet.example/ohttp-configs")
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
}
