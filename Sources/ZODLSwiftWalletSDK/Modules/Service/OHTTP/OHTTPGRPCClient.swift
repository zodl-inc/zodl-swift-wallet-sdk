//
//  OHTTPGRPCClient.swift
//  ZODLSwiftWalletSDK
//
//  Generic gRPC client over OHTTP transport.
//

import Foundation
import SwiftProtobuf
import os

/// Generic gRPC client that carries every RPC as one OHTTP exchange.
actor OHTTPGRPCClient {
    private let authority: String
    private let transport: OHTTPTransport
    private let singleCallTimeoutMS: Int
    private let streamingCallTimeoutMS: Int
    private let logger = Logger(subsystem: "ZODLSwiftWalletSDK", category: "OHTTPGRPCClient")

    private static let grpcContentType = "application/grpc"
    private static let userAgent = "zodl-ohttp-swift/1.0"
    private static let frameHeaderSize = 5
    private static let httpOK = 200
    private static let timeoutSlackMS = 5000
    private static let httpPayloadTooLarge = 413
    private static let httpUpgradeRequired = 426

    // Gateway upstream timeout is 80 s; keep grpc-timeout under that with margin
    private static let maxGRPCTimeoutMS = 75000
    // Suitable request timeout, leaving room for retries and key fetch
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

        let bhttpResponse = try await exchange(bhttpRequest, timeoutMS: exchangeTimeoutMS)

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

        let bhttpResponse = try await exchange(bhttpRequest, timeoutMS: exchangeTimeoutMS)

        return try parseStreamingResponse(bhttpResponse)
    }

    private func exchange(_ request: OHTTPRequest, timeoutMS: Int) async throws -> OHTTPResponse {
        do {
            return try await transport.roundTrip(request: request, timeoutMS: timeoutMS)
        } catch {
            if case OHTTPError.httpStatusError(let status, _) = error, status == Self.httpUpgradeRequired {
                logger.error("OHTTP: the relay or gateway answered 426 Upgrade Required")
            }
            throw Self.serviceError(for: error)
        }
    }

    /// The gRPC status a failed exchange is surfaced as: INVALID_ARGUMENT or RESOURCE_EXHAUSTED for a
    /// request too large to send (or refused with 413), INTERNAL for an answer that does not open or does
    /// not parse, UNAVAILABLE for every outer refusal and transport failure.
    static func serviceError(for error: Error) -> Error {
        if error is CancellationError || error is LightWalletServiceError {
            return error
        }
        guard let ohttpError = error as? OHTTPError else {
            return LightWalletServiceError.failed(statusCode: OHTTPGRPCStatus.unavailable, message: "OHTTP transport: \(error)")
        }
        switch ohttpError {
        case .requestTooLarge(let message):
            return LightWalletServiceError.failed(statusCode: OHTTPGRPCStatus.resourceExhausted, message: message)
        case .httpStatusError(let status, let message) where status == httpPayloadTooLarge:
            return LightWalletServiceError.failed(statusCode: OHTTPGRPCStatus.resourceExhausted, message: message)
        case .binaryHttpError(let message), .hpkeError(let message), .responseTooLarge(let message):
            return LightWalletServiceError.failed(statusCode: OHTTPGRPCStatus.internalError, message: message)
        case .httpStatusError(_, let message), .transportError(let message), .keyConfigError(let message):
            return LightWalletServiceError.failed(statusCode: OHTTPGRPCStatus.unavailable, message: message)
        }
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
            throw LightWalletServiceError.failed(statusCode: OHTTPGRPCStatus.internalError, message: "Empty gRPC response body")
        }

        let messages: [T] = try parseGRPCFrames(response.body)
        guard let message = messages.first else {
            throw LightWalletServiceError.failed(statusCode: OHTTPGRPCStatus.internalError, message: "No message in unary response")
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
            throw LightWalletServiceError.failed(
                statusCode: OHTTPGRPCStatus.internalError,
                message: "gateway/lightwalletd returned HTTP \(response.status)"
            )
        }

        let contentType = response.field("content-type") ?? ""
        guard contentType.hasPrefix(Self.grpcContentType) else {
            throw LightWalletServiceError.failed(
                statusCode: OHTTPGRPCStatus.internalError,
                message: "unexpected content-type '\(contentType)'"
            )
        }

        let encoding = response.field("grpc-encoding")
        if let encoding = encoding, encoding != "identity" {
            throw LightWalletServiceError.failed(
                statusCode: OHTTPGRPCStatus.internalError,
                message: "unsupported grpc-encoding '\(encoding)'"
            )
        }

        guard let grpcStatusString = response.field("grpc-status"),
              let grpcStatusCode = Int(grpcStatusString) else {
            throw LightWalletServiceError.failed(
                statusCode: OHTTPGRPCStatus.internalError,
                message: "response is missing grpc-status"
            )
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
                throw LightWalletServiceError.failed(statusCode: OHTTPGRPCStatus.internalError, message: "truncated frame header")
            }

            let compressed = body[pos]
            let length = Int(body[pos + 1]) << 24 |
                        Int(body[pos + 2]) << 16 |
                        Int(body[pos + 3]) << 8 |
                        Int(body[pos + 4])
            pos += Self.frameHeaderSize

            guard compressed == 0 else {
                throw LightWalletServiceError.failed(statusCode: OHTTPGRPCStatus.internalError, message: "compressed frames are not supported")
            }

            guard length >= 0, length <= body.count - pos else {
                throw LightWalletServiceError.failed(statusCode: OHTTPGRPCStatus.internalError, message: "truncated frame body")
            }

            let messageData = body.subdata(in: pos..<pos + length)
            do {
                messages.append(try T(serializedData: messageData))
            } catch {
                throw LightWalletServiceError.failed(statusCode: OHTTPGRPCStatus.internalError, message: "malformed gRPC message: \(error)")
            }
            pos += length
        }

        return messages
    }
}

/// The gRPC status codes this client surfaces.
enum OHTTPGRPCStatus {
    static let invalidArgument = 3
    static let resourceExhausted = 8
    static let internalError = 13
    static let unavailable = 14
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
