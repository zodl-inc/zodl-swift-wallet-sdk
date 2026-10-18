//
//  OHTTPGRPCClient.swift
//  ZODLSwiftWalletSDK
//
//  Generic gRPC client over OHTTP transport.
//

import Foundation
import SwiftProtobuf

/// Generic gRPC client that carries every RPC as one OHTTP exchange.
actor OHTTPGRPCClient {
    private let authority: String
    private let transport: OHTTPTransport
    private let singleCallTimeoutMS: Int
    private let streamingCallTimeoutMS: Int

    private static let grpcContentType = "application/grpc"
    private static let userAgent = "zodl-ohttp-swift/1.0"
    private static let frameHeaderSize = 5
    private static let httpOK = 200
    private static let timeoutSlackMS = 5000

    // ZIP 1093: gateway upstream timeout is 80 s; keep grpc-timeout under that with margin
    private static let maxGRPCTimeoutMS = 75000
    // ZIP 661: suitable request timeout, leaving room for retries and key fetch
    private static let maxExchangeTimeoutMS = 100000

    init(
        authority: String,
        transport: OHTTPTransport,
        singleCallTimeoutMS: Int,
        streamingCallTimeoutMS: Int
    ) {
        self.authority = authority
        self.transport = transport
        self.singleCallTimeoutMS = singleCallTimeoutMS
        self.streamingCallTimeoutMS = streamingCallTimeoutMS
    }

    /// Performs a unary gRPC call over OHTTP.
    func unary<Req: SwiftProtobuf.Message, Resp: SwiftProtobuf.Message>(
        path: String,
        request: Req,
        timeout: Int? = nil
    ) async throws -> Resp {
        let requestedTimeoutMS = timeout ?? singleCallTimeoutMS
        let grpcTimeoutMS = min(requestedTimeoutMS, Self.maxGRPCTimeoutMS)
        let exchangeTimeoutMS = min(requestedTimeoutMS + Self.timeoutSlackMS, Self.maxExchangeTimeoutMS)

        let body = try encodeGRPCMessage(request)

        let headers: [(String, String)] = [
            ("content-type", Self.grpcContentType),
            ("te", "trailers"),
            ("grpc-accept-encoding", "identity"),
            ("user-agent", Self.userAgent),
            ("grpc-timeout", "\(grpcTimeoutMS)m")
        ]

        let bhttpRequest = OHTTPRequest(
            method: "POST",
            scheme: "https",
            authority: authority,
            path: path,
            headers: headers,
            body: body
        )

        let bhttpResponse = try await transport.roundTrip(
            request: bhttpRequest,
            timeoutMS: exchangeTimeoutMS
        )

        return try parseUnaryResponse(bhttpResponse)
    }

    /// Performs a server-streaming gRPC call over OHTTP (all frames buffered).
    func serverStreaming<Req: SwiftProtobuf.Message, Resp: SwiftProtobuf.Message>(
        path: String,
        request: Req,
        timeout: Int? = nil
    ) async throws -> [Resp] {
        let requestedTimeoutMS = timeout ?? streamingCallTimeoutMS
        let grpcTimeoutMS = min(requestedTimeoutMS, Self.maxGRPCTimeoutMS)
        let exchangeTimeoutMS = min(requestedTimeoutMS + Self.timeoutSlackMS, Self.maxExchangeTimeoutMS)

        let body = try encodeGRPCMessage(request)

        let headers: [(String, String)] = [
            ("content-type", Self.grpcContentType),
            ("te", "trailers"),
            ("grpc-accept-encoding", "identity"),
            ("user-agent", Self.userAgent),
            ("grpc-timeout", "\(grpcTimeoutMS)m")
        ]

        let bhttpRequest = OHTTPRequest(
            method: "POST",
            scheme: "https",
            authority: authority,
            path: path,
            headers: headers,
            body: body
        )

        let bhttpResponse = try await transport.roundTrip(
            request: bhttpRequest,
            timeoutMS: exchangeTimeoutMS
        )

        return try parseStreamingResponse(bhttpResponse)
    }

    // MARK: - gRPC Message Encoding/Decoding

    private func encodeGRPCMessage<T: SwiftProtobuf.Message>(_ message: T) throws -> Data {
        let serialized = try message.serializedData()
        var data = Data()
        data.append(0)  // uncompressed flag
        withUnsafeBytes(of: UInt32(serialized.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(serialized)
        return data
    }

    private func parseUnaryResponse<T: SwiftProtobuf.Message>(_ response: OHTTPResponse) throws -> T {
        try checkGRPCStatus(response)

        guard response.body.count >= Self.frameHeaderSize else {
            throw LightWalletServiceError.generalError(message: "Empty gRPC response body")
        }

        let messages: [T] = try parseGRPCFrames(response.body)
        guard let message = messages.first else {
            throw LightWalletServiceError.generalError(message: "No message in unary response")
        }

        return message
    }

    private func parseStreamingResponse<T: SwiftProtobuf.Message>(_ response: OHTTPResponse) throws -> [T] {
        try checkGRPCStatus(response)

        if response.body.isEmpty {
            return []
        }

        return try parseGRPCFrames(response.body)
    }

    private func checkGRPCStatus(_ response: OHTTPResponse) throws {
        guard response.status == Self.httpOK else {
            let grpcStatus = httpStatusToGRPCCode(response.status)
            throw LightWalletServiceError.failed(
                statusCode: grpcStatus,
                message: "gateway/lightwalletd returned HTTP \(response.status)"
            )
        }

        let contentType = response.field("content-type") ?? ""
        guard contentType.hasPrefix(Self.grpcContentType) else {
            throw LightWalletServiceError.generalError(message: "unexpected content-type '\(contentType)'")
        }

        let encoding = response.field("grpc-encoding")
        if let encoding = encoding, encoding != "identity" {
            throw LightWalletServiceError.generalError(message: "unsupported grpc-encoding '\(encoding)'")
        }

        guard let grpcStatusString = response.field("grpc-status"),
              let grpcStatusCode = Int(grpcStatusString) else {
            throw LightWalletServiceError.generalError(message: "response is missing grpc-status")
        }

        guard grpcStatusCode == 0 else {
            let grpcMessage = response.field("grpc-message")?.percentDecoded() ?? ""
            throw LightWalletServiceError.failed(statusCode: grpcStatusCode, message: grpcMessage)
        }
    }

    private func parseGRPCFrames<T: SwiftProtobuf.Message>(_ slice: Data) throws -> [T] {
        // Re-base: a `Data` slice keeps its parent's indices, and everything below indexes from 0.
        let body = Data(slice)
        var messages: [T] = []
        var pos = 0

        while pos < body.count {
            guard body.count - pos >= Self.frameHeaderSize else {
                throw LightWalletServiceError.generalError(message: "truncated frame header")
            }

            let compressed = body[pos]
            let length = Int(body[pos + 1]) << 24 |
                        Int(body[pos + 2]) << 16 |
                        Int(body[pos + 3]) << 8 |
                        Int(body[pos + 4])
            pos += Self.frameHeaderSize

            guard compressed == 0 else {
                throw LightWalletServiceError.generalError(message: "compressed frames are not supported")
            }

            guard length >= 0, length <= body.count - pos else {
                throw LightWalletServiceError.generalError(message: "truncated frame body")
            }

            let messageData = body.subdata(in: pos..<pos + length)
            let message = try T(serializedData: messageData)
            messages.append(message)
            pos += length
        }

        return messages
    }

    private func httpStatusToGRPCCode(_ httpStatus: Int) -> Int {
        switch httpStatus {
        case 400: return 13  // INTERNAL
        case 401: return 14  // UNAVAILABLE (per ZIP, outer auth failure)
        case 403: return 7   // PERMISSION_DENIED
        case 404: return 12  // UNIMPLEMENTED
        case 426: return 14  // UNAVAILABLE (per ZIP, non-encapsulated/wrong protocol)
        case 429, 500, 502, 503, 504: return 14  // UNAVAILABLE
        default: return 2    // UNKNOWN
        }
    }
}

// MARK: - String Extension for Percent Decoding

private extension String {
    func percentDecoded() -> String {
        guard self.contains("%") else { return self }

        var result = Data()
        var i = self.startIndex

        while i < self.endIndex {
            let character = self[i]
            if character == "%" {
                let nextIndex = self.index(after: i)
                if nextIndex < self.endIndex, self.index(after: nextIndex) < self.endIndex {
                    let nextNextIndex = self.index(after: nextIndex)
                    // Two hex digits follow the '%'.
                    let hexString = String(self[nextIndex...nextNextIndex])
                    if let byte = UInt8(hexString, radix: 16) {
                        result.append(byte)
                        i = self.index(after: nextNextIndex)
                        continue
                    }
                }
            }
            if let asciiValue = character.asciiValue {
                result.append(asciiValue)
            }
            i = self.index(after: i)
        }

        return String(data: result, encoding: .utf8) ?? self
    }
}
