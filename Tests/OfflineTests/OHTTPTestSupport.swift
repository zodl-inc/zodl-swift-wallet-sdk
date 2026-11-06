//
//  OHTTPTestSupport.swift
//  OfflineTests
//
//  Shared fixtures for the OHTTP transport tests.
//

import Foundation
import CryptoKit
@testable import ZODLSwiftWalletSDK

enum OHTTPTestSupport {
    /// Expectations come from the same public build environment as the compiled native fixture.
    static func configuredValue(_ name: String) -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            preconditionFailure("Tests require the native build configuration: \(name)")
        }
        return value
    }

    static let mainnetHost = configuredValue("ZODL_OHTTP_GATEWAY_HOST_MAINNET")
    static let testnetHost = configuredValue("ZODL_OHTTP_GATEWAY_HOST_TESTNET")
    static let mainnetDNSName = configuredValue("ZODL_OHTTP_KEYS_DNS_NAME_MAINNET")
    static let testnetDNSName = configuredValue("ZODL_OHTTP_KEYS_DNS_NAME_TESTNET")

    static func signingKeyId(for network: NetworkType) -> String {
        let suffix = network == .mainnet ? "MAINNET" : "TESTNET"
        let hex = Array(configuredValue("ZODL_OHTTP_SIGNING_PUBKEY_\(suffix)"))
        precondition(hex.count == 64, "Tests require a 32-byte signing public key")
        let bytes = stride(from: 0, to: hex.count, by: 2).map { index -> UInt8 in
            guard let byte = UInt8(String(hex[index...index + 1]), radix: 16) else {
                preconditionFailure("Tests require a hexadecimal signing public key")
            }
            return byte
        }
        return SHA256.hash(data: Data(bytes)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The body a mock serves for the signed key-configuration GET. Only the test verifier reads it.
    static let stubEnvelope = Data("{\"stub\":true}".utf8)

    /// A verifier that accepts any envelope and returns a usable gateway key (id 1 and a fresh X25519
    /// public key), valid for an hour. Only public signing keys are supplied here, so the
    /// transport flow tests use this; the signed-envelope rules themselves are tested against the native
    /// verifier in `OHTTPSignedConfigTests`.
    static func makeKeyVerifier() -> OHTTPTransport.KeyVerifier {
        var keyBytes = Data([0x01])
        keyBytes.append(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        let key = OHTTPVerifiedKey(
            bytes: keyBytes,
            notAfter: UInt64(Date().timeIntervalSince1970) + 3600,
            isTestnet: true
        )
        return { _, _ in key }
    }

    static func response(for url: URL?, status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        // swiftlint:disable:next force_unwrapping
        HTTPURLResponse(url: url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    /// A GET request that the mock senders in these tests never answer successfully.
    static let simpleRequest = OHTTPRequest(
        method: "GET",
        scheme: "https",
        authority: "example.zodl.com",
        path: "/test",
        headers: [],
        body: Data()
    )

    /// Bytes that look like a sealed response but do not open under any secret.
    static func unopenableSealedResponse() -> Data {
        Data(repeating: 0, count: 48)
    }

    /// A transport on the testnet gateway host, the test key verifier and `sender`.
    static func makeTransport(
        relayURL: String = "https://testnet-operator-relay.example.invalid/relay",
        clientTraceIdPrefix: String? = nil,
        keyCache: OHTTPKeyCache = OHTTPKeyCache(),
        sender: @escaping OHTTPTransport.HTTPSender
    ) -> OHTTPTransport {
        OHTTPTransport(
            gatewayHost: OHTTPTestSupport.testnetHost,
            relayURL: relayURL,
            clientTraceIdPrefix: clientTraceIdPrefix,
            testKeyVerifier: makeKeyVerifier(),
            keyCache: keyCache,
            httpSender: sender
        )
    }

    /// Runs one round trip against a sender that answers the key GET and aborts the first relay POST, and
    /// returns the POST the sender saw.
    static func capturePost(clientTraceIdPrefix: String?) async -> URLRequest? {
        var captured: URLRequest?
        let transport = makeTransport(clientTraceIdPrefix: clientTraceIdPrefix) { request, _ in
            if request.httpMethod == "GET" {
                return (stubEnvelope, response(for: request.url, status: 200, headers: ["Content-Type": "application/json"]))
            }
            captured = request
            throw OHTTPError.transportError("test abort")
        }
        _ = try? await transport.roundTrip(request: simpleRequest, timeoutMS: 5000)
        return captured
    }
    /// A controlled HPKE peer answers a real native request with an authenticated BHTTP chunk.
    /// Keeping the final chunk optional reproduces a body that ends after an authenticated head.
    @available(iOS 17, macOS 14, *)
    static func grpcPeerResponse(
        status: String?, trailer: String? = nil, complete: Bool = false, corrupt: Bool = false
    ) throws -> (pending: OHTTPPendingResponse, body: Data) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let key = OHTTPVerifiedKey(
            bytes: Data([7]) + privateKey.publicKey.rawRepresentation, notAfter: UInt64.max, isTestnet: true
        )
        let sealed = try OHTTPNative.encapsulate(key: key, request: simpleRequest)
        let request = sealed.body
        let recipient = try HPKE.Recipient(
            privateKey: privateKey,
            ciphersuite: HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_128),
            info: Data("message/bhttp chunked request\0".utf8) + request.prefix(7),
            encapsulatedKey: Data(request[7..<39])
        )
        let secret = try recipient.exportSecret(context: Data("message/bhttp chunked response".utf8), outputByteCount: 16)
        let responseNonce = Data(repeating: 3, count: 16)
        let salt = Data(request[7..<39]) + responseNonce
        let keyMaterial = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: salt, info: Data("key".utf8), outputByteCount: 16)
        let nonceMaterial = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: salt, info: Data("nonce".utf8), outputByteCount: 12)
        let nonceBytes = nonceMaterial.withUnsafeBytes { Data($0) }
        func field(_ name: String, _ value: String) -> Data {
            Data([UInt8(name.utf8.count)]) + Data(name.utf8) + Data([UInt8(value.utf8.count)]) + Data(value.utf8)
        }
        var plaintext = Data([3, 0x40, 200]) + field("content-type", "application/grpc")
        if let status { plaintext += field("grpc-status", status) }
        plaintext.append(0)
        if trailer != nil || complete {
            plaintext.append(0)
            if let trailer { plaintext += field("grpc-status", trailer) }
            plaintext.append(0)
        }
        let encrypted = try AES.GCM.seal(plaintext, using: keyMaterial, nonce: AES.GCM.Nonce(data: nonceBytes))
        let chunk = encrypted.ciphertext + encrypted.tag
        var wire = responseNonce
        if chunk.count >= 64 { wire.append(0x40 | UInt8(chunk.count >> 8)) }
        wire.append(UInt8(chunk.count & 0xff))
        wire += chunk
        if complete {
            var finalNonce = nonceBytes
            finalNonce[11] ^= 1
            let final = try AES.GCM.seal(
                Data(), using: keyMaterial, nonce: AES.GCM.Nonce(data: finalNonce), authenticating: Data("final".utf8)
            )
            wire.append(0)
            wire += final.ciphertext + final.tag
        }
        if corrupt { wire[wire.count - 1] ^= 1 }
        return (sealed.pending, wire)
    }
}
