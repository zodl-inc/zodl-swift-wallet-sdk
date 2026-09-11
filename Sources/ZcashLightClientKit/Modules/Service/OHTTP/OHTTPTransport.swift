//
//  OHTTPTransport.swift
//  ZcashLightClientKit
//
//  OHTTP (RFC 9458) client transport: encapsulates a Binary HTTP request with HPKE, POSTs it to the
//  relay and decapsulates the gateway's response.
//

import Foundation

actor OHTTPTransport {
    private let relayURL: String
    private let keyConfigURL: String
    private let connectTimeoutMS: Int
    private let keyFetchTimeoutMS: Int
    private var cachedKeyConfig: OHTTPKeyConfig?

    private static let requestMediaType = "message/ohttp-req"
    private static let responseMediaType = "message/ohttp-res"
    private static let keysMediaType = "application/ohttp-keys"
    private static let requestLabel = "message/bhttp request".data(using: .ascii)!
    private static let responseLabel = "message/bhttp response".data(using: .ascii)!

    init(relayURL: String, keyConfigURL: String, connectTimeoutMS: Int = 15000, keyFetchTimeoutMS: Int = 15000) {
        self.relayURL = relayURL
        self.keyConfigURL = keyConfigURL
        self.connectTimeoutMS = connectTimeoutMS
        self.keyFetchTimeoutMS = keyFetchTimeoutMS
    }

    /// Fetches (or returns the cached) gateway key configuration.
    func keyConfig(forceRefresh: Bool = false) async throws -> OHTTPKeyConfig {
        if !forceRefresh, let cached = cachedKeyConfig {
            return cached
        }

        let bytes = try await httpGet(url: keyConfigURL, timeoutMS: keyFetchTimeoutMS)
        let parsed = try OHTTPKeyConfig.parseSupported(bytes)
        cachedKeyConfig = parsed
        return parsed
    }

    /// Performs one OHTTP round trip. A gateway rejection (HTTP 400 from the relay/gateway pair) is
    /// retried once after refreshing the key configuration, which handles gateway key rotation.
    func roundTrip(request: BinaryHTTP.Request, timeoutMS: Int) async throws -> BinaryHTTP.Response {
        var keyConfig = try await self.keyConfig()

        do {
            return try await roundTripWith(keyConfig: keyConfig, request: request, timeoutMS: timeoutMS)
        } catch let error as OHTTPError {
            // Check if it's a 400 error
            if case .transportError(let message) = error, message.contains("HTTP 400") {
                // Refresh key config and retry
                keyConfig = try await self.keyConfig(forceRefresh: true)
                return try await roundTripWith(keyConfig: keyConfig, request: request, timeoutMS: timeoutMS)
            }
            throw error
        }
    }

    private func roundTripWith(
        keyConfig: OHTTPKeyConfig,
        request: BinaryHTTP.Request,
        timeoutMS: Int
    ) async throws -> BinaryHTTP.Response {
        // RFC 9458 §4.3 — Encapsulation of Requests
        let header = keyConfig.header()
        let info = Self.requestLabel + Data([0x00]) + header
        var context = try OHTTPHPKE.setupBaseS(recipientPublicKey: keyConfig.publicKey, info: info)
        let plaintext = try BinaryHTTP.encodeRequest(request)
        let ciphertext = try context.seal(aad: Data(), plaintext: plaintext)
        let encapsulatedRequest = header + context.enc + ciphertext

        let encapsulatedResponse = try await httpPost(
            url: relayURL,
            body: encapsulatedRequest,
            timeoutMS: timeoutMS
        )

        // RFC 9458 §4.4 — Encapsulation of Responses (client side: decapsulate)
        let nonceLength = max(OHTTPHPKE.nN, OHTTPHPKE.nK)
        guard encapsulatedResponse.count >= nonceLength + OHTTPHPKE.nT else {
            throw OHTTPError.transportError("OHTTP response too short (\(encapsulatedResponse.count) bytes)")
        }

        let responseNonce = encapsulatedResponse.prefix(nonceLength)
        let responseCiphertext = encapsulatedResponse.suffix(from: nonceLength)

        let secret = try context.export(exporterContext: Self.responseLabel, length: OHTTPHPKE.nK)
        let salt = context.enc + responseNonce
        let prk = OHTTPHPKE.hkdfExtract(salt: salt, ikm: secret)
        let aeadKey = try OHTTPHPKE.hkdfExpand(prk: prk, info: "key".data(using: .ascii)!, length: OHTTPHPKE.nK)
        let aeadNonce = try OHTTPHPKE.hkdfExpand(prk: prk, info: "nonce".data(using: .ascii)!, length: OHTTPHPKE.nN)

        let decrypted: Data
        do {
            decrypted = try OHTTPHPKE.aesGcmOpen(key: aeadKey, nonce: aeadNonce, aad: Data(), ciphertext: responseCiphertext)
        } catch {
            throw OHTTPError.transportError("OHTTP response authentication failed")
        }

        return try BinaryHTTP.decodeResponse(decrypted)
    }

    // MARK: - HTTP

    private func httpGet(url: String, timeoutMS: Int) async throws -> Data {
        guard let urlObj = URL(string: url) else {
            throw OHTTPError.transportError("Invalid URL: \(url)")
        }

        var request = URLRequest(url: urlObj, timeoutInterval: TimeInterval(timeoutMS) / 1000.0)
        request.httpMethod = "GET"
        request.setValue(Self.keysMediaType, forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OHTTPError.transportError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            throw OHTTPError.transportError("Key config fetch failed: HTTP \(httpResponse.statusCode)")
        }

        return data
    }

    private func httpPost(url: String, body: Data, timeoutMS: Int) async throws -> Data {
        guard let urlObj = URL(string: url) else {
            throw OHTTPError.transportError("Invalid URL: \(url)")
        }

        var request = URLRequest(url: urlObj, timeoutInterval: TimeInterval(timeoutMS) / 1000.0)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(Self.requestMediaType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.responseMediaType, forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OHTTPError.transportError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            let detail = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw OHTTPError.transportError("Relay/gateway returned HTTP \(httpResponse.statusCode)\(detail.isEmpty ? "" : ": \(detail)")")
        }

        return data
    }
}
