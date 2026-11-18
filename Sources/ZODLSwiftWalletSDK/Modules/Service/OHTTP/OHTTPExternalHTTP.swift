//
//  OHTTPExternalHTTP.swift
//  ZODLSwiftWalletSDK
//
//  HTTP requests to the third-party hosts the gateway serves (`OHTTPEndpoints`), with the answer read as
//  the gateway sends it: `Synchronizer.httpStreamOverOHTTP(for:viaTor:)` and `OHTTPURLProtocol`.
//

import Foundation

/// An answer through the OHTTP relay and gateway, its body read as the gateway sends it. The body fails
/// when the gateway's sealed answer breaks off before its end or does not open: a body that ends without
/// an error is the whole, authenticated answer.
public struct OHTTPStreamedResponse: @unchecked Sendable {
    public let response: HTTPURLResponse
    public let body: AsyncThrowingStream<Data, Error>

    public init(response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>) {
        self.response = response
        self.body = body
    }
}

enum OHTTPExternalHTTP {
    /// Fields of the device's own connection to the relay, never part of the inner request.
    static let connectionHeaders: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te", "host",
        "content-length", "accept-encoding"
    ]

    /// Credentials only the gateway adds for its alias hosts: never sent from the device.
    static let gatewayInjectedHeaders: Set<String> = ["x-cmc_pro_api_key", "authorization"]

    /// The longest request body sent, the gateway's cap on a sealed request.
    static let maxRequestBodyBytes = 10 * 1024 * 1024

    /// The inner request for `request`, whose host the gateway serves. The answer's body is passed on as it
    /// comes, so it is asked for without a content coding.
    static func innerRequest(for request: URLRequest) throws -> OHTTPRequest {
        guard let url = request.url, let host = url.host else {
            throw ZcashError.ohttpUnsupportedHost
        }
        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        let path = (rawPath.isEmpty ? "/" : rawPath) + (url.query.map { "?\($0)" } ?? "")

        let stripSecrets = OHTTPEndpoints.needsHeaderStripping(host: host)
        var headers = (request.allHTTPHeaderFields ?? [:])
            .map { ($0.key.lowercased(), $0.value) }
            .filter { name, _ in
                !connectionHeaders.contains(name) && !(stripSecrets && gatewayInjectedHeaders.contains(name))
            }
            .sorted { $0.0 < $1.0 }
        headers.append(("accept-encoding", "identity"))

        return OHTTPRequest(
            method: request.httpMethod ?? "GET",
            scheme: url.scheme ?? "https",
            authority: host,
            path: path,
            headers: headers,
            body: try body(of: request)
        )
    }

    /// The request body, read out of its stream when it has one (as a `URLProtocol` gets it).
    static func body(of request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            if body.count > maxRequestBodyBytes {
                throw OHTTPError.requestTooLarge("The request body exceeds \(maxRequestBodyBytes) bytes")
            }
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw OHTTPError.transportError("The request body could not be read")
            }
            if count == 0 {
                return body
            }
            body.append(buffer, count: count)
            if body.count > maxRequestBodyBytes {
                throw OHTTPError.requestTooLarge("The request body exceeds \(maxRequestBodyBytes) bytes")
            }
        }
    }

    /// Sends `request` through the relay and the gateway of the wallet's `network` and returns once the
    /// backend's head is in. With `viaTor` the relay leg, the key-configuration fetch included, rides Tor.
    /// `request.timeoutInterval` bounds each wait for the relay, not the whole answer.
    ///
    /// A passthrough host is admitted by the gateway's host list before anything is sent for it. That list is
    /// fetched only through OHTTP, over this request's own transport and so on its route (Tor with `viaTor`),
    /// and a host it does not carry is refused with `ZcashError.ohttpUnsupportedHost`: nothing is reached
    /// directly.
    static func stream(
        _ request: URLRequest,
        network: NetworkType,
        viaTor: Bool,
        torSender: @escaping OHTTPTransport.HTTPSender,
        torStreamSender: @escaping OHTTPTransport.StreamSender
    ) async throws -> OHTTPStreamedResponse {
        guard let url = request.url, let host = url.host else {
            throw ZcashError.ohttpUnsupportedHost
        }
        // A host that is not a fixed destination needs the list of the wallet's gateway, so OHTTP on for it.
        guard OHTTPThirdPartyHosts.isFixedDestination(url, host: host) || OHTTPEndpoints.gatewayHost(for: network) != nil else {
            throw ZcashError.ohttpUnsupportedHost
        }
        let route = try OHTTPEndpoints.proxyRoute(for: host, network: network)
        let inner = try innerRequest(for: request)

        let transport: OHTTPTransport
        if viaTor {
            transport = OHTTPTransport(
                gatewayHost: route.gatewayHost,
                relayURL: route.relayURL,
                clientTraceIdPrefix: OHTTPEndpoints.effectiveClientTraceIdPrefix,
                walletNetwork: network,
                viaTor: true,
                streamSender: torStreamSender,
                httpSender: torSender
            )
        } else {
            transport = OHTTPTransport(
                gatewayHost: route.gatewayHost,
                relayURL: route.relayURL,
                clientTraceIdPrefix: OHTTPEndpoints.effectiveClientTraceIdPrefix,
                walletNetwork: network
            )
        }

        // The list is refreshed over this transport's round trip, which uses its own sender: in Tor mode a Tor
        // circuit, never the device's own address.
        try await OHTTPThirdPartyHosts.admit(
            url: url,
            host: host,
            network: network,
            exchange: OHTTPThirdPartyHosts.exchange(through: transport, timeoutMS: OHTTPThirdPartyHosts.admissionRefreshTimeoutMS)
        )

        let streamed = try await transport.stream(request: inner, timeoutMS: timeoutMS(for: request.timeoutInterval))
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: streamed.status,
            httpVersion: "HTTP/1.1",
            headerFields: Dictionary(streamed.headers, uniquingKeysWith: { "\($0), \($1)" })
        ) else {
            throw ZcashError.ohttpResponseError
        }
        // A `403` for a host the list carries may be the gateway's `unknown authority`: its body is read through,
        // as it comes, and reported to the list once it ends. A fixed destination is not on the list.
        let body = streamed.status == 403 && !OHTTPThirdPartyHosts.isFixedDestination(url, host: host)
            ? OHTTPThirdPartyHosts.watchingForUnknownAuthority(streamed.body, host: host, network: network)
            : streamed.body
        return OHTTPStreamedResponse(response: response, body: body)
    }

    /// The longest wait for the relay a request can ask for.
    static let maxTimeout: TimeInterval = 24 * 60 * 60

    /// `interval` in milliseconds, between 1 s and ``maxTimeout``; a value that is not a number (NaN, an
    /// infinity) gets URLRequest's default of 60 s.
    static func timeoutMS(for interval: TimeInterval) -> Int {
        guard interval.isFinite else { return 60_000 }
        return Int(min(max(interval, 1), maxTimeout) * 1000)
    }
}
