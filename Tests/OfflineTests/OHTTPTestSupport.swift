//
//  OHTTPTestSupport.swift
//  OfflineTests
//
//  Shared fixtures for the OHTTP transport tests.
//

import Foundation
import CryptoKit
@testable import ZcashLightClientKit

enum OHTTPTestSupport {
    /// The body a mock serves for the signed key-configuration GET. Only the test verifier reads it.
    static let stubEnvelope = Data("{\"stub\":true}".utf8)

    /// A verifier that accepts any envelope and returns a usable gateway key (id 1 and a fresh X25519
    /// public key), valid for an hour. The pinned signing keys have no private half to sign with, so the
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
        keyConfigURL: String = "https://testnet-operator-relay.example.invalid/ohttp-configs",
        clientTraceIdPrefix: String? = nil,
        sender: @escaping OHTTPTransport.HTTPSender
    ) -> OHTTPTransport {
        OHTTPTransport(
            gatewayHost: "ohttp-gateway-testnet.example",
            relayURL: relayURL,
            keyConfigURL: keyConfigURL,
            clientTraceIdPrefix: clientTraceIdPrefix,
            testKeyVerifier: makeKeyVerifier(),
            httpSender: sender
        )
    }

    /// Runs one round trip against a sender that answers the key GET and aborts the first relay POST, and
    /// returns the POST the sender saw.
    static func capturePost(clientTraceIdPrefix: String?) async -> URLRequest? {
        var captured: URLRequest?
        let transport = makeTransport(clientTraceIdPrefix: clientTraceIdPrefix) { request in
            if request.httpMethod == "GET" {
                return (stubEnvelope, response(for: request.url, status: 200, headers: ["Content-Type": "application/json"]))
            }
            captured = request
            throw OHTTPError.transportError("test abort")
        }
        _ = try? await transport.roundTrip(request: simpleRequest, timeoutMS: 5000)
        return captured
    }
}
