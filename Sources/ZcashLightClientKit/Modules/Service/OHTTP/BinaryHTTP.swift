//
//  BinaryHTTP.swift
//  ZcashLightClientKit
//
//  Binary HTTP (RFC 9292) encoder/decoder — the inner message format used by OHTTP (RFC 9458).
//
//  Requests are always emitted in known-length form (framing indicator 0). Responses in both
//  known-length (1) and indeterminate-length (3) form are accepted. Integers use the QUIC
//  variable-length encoding (RFC 9000 §16) as mandated by RFC 9292 §1.1.
//

import Foundation

enum BinaryHTTP {
    private static let framingKnownLengthRequest: UInt64 = 0
    private static let framingKnownLengthResponse: UInt64 = 1
    private static let framingIndeterminateResponse: UInt64 = 3

    struct Request {
        let method: String
        let scheme: String
        let authority: String
        let path: String
        let headers: [(String, String)]
        let body: Data
    }

    struct Response {
        let status: Int
        let headers: [(String, String)]
        let body: Data
        let trailers: [(String, String)]

        /// Case-insensitive lookup across headers then trailers.
        func field(_ name: String) -> String? {
            let lowercaseName = name.lowercased()
            for (key, value) in headers + trailers {
                if key.lowercased() == lowercaseName {
                    return value
                }
            }
            return nil
        }
    }

    static func encodeRequest(_ request: Request) throws -> Data {
        var out = Data()
        writeVarint(&out, framingKnownLengthRequest)
        try writeLengthPrefixed(&out, request.method.data(using: .ascii)!)
        try writeLengthPrefixed(&out, request.scheme.data(using: .ascii)!)
        try writeLengthPrefixed(&out, request.authority.data(using: .ascii)!)
        try writeLengthPrefixed(&out, request.path.data(using: .ascii)!)
        try writeKnownLengthFieldSection(&out, request.headers)
        try writeLengthPrefixed(&out, request.body)
        try writeKnownLengthFieldSection(&out, [])  // trailers
        return out
    }

    static func decodeResponse(_ bytes: Data) throws -> Response {
        var reader = Reader(bytes: bytes)
        let framing = try reader.readVarint()

        switch framing {
        case framingKnownLengthResponse:
            return try decodeKnownLengthResponse(&reader)
        case framingIndeterminateResponse:
            return try decodeIndeterminateResponse(&reader)
        default:
            throw OHTTPError.binaryHttpError("Unsupported Binary HTTP framing indicator: \(framing)")
        }
    }

    private static func decodeKnownLengthResponse(_ reader: inout Reader) throws -> Response {
        var status: Int
        var headers: [(String, String)]

        // Skip informational (1xx) responses — RFC 9292 §3.5.1
        repeat {
            status = Int(try reader.readVarint())
            headers = reader.hasRemaining() ? try readKnownLengthFieldSection(&reader) : []
        } while status >= 100 && status <= 199 && reader.hasRemaining()

        let body = reader.hasRemaining() ? try reader.readLengthPrefixed() : Data()
        let trailers = reader.hasRemaining() ? try readKnownLengthFieldSection(&reader) : []

        return Response(status: status, headers: headers, body: body, trailers: trailers)
    }

    private static func decodeIndeterminateResponse(_ reader: inout Reader) throws -> Response {
        var status: Int
        var headers: [(String, String)]

        repeat {
            status = Int(try reader.readVarint())
            headers = reader.hasRemaining() ? try readIndeterminateFieldSection(&reader) : []
        } while status >= 100 && status <= 199 && reader.hasRemaining()

        var body = Data()
        while reader.hasRemaining() {
            let chunk = try reader.readLengthPrefixed()
            if chunk.isEmpty { break }
            body.append(chunk)
        }

        let trailers = reader.hasRemaining() ? try readIndeterminateFieldSection(&reader) : []

        return Response(status: status, headers: headers, body: body, trailers: trailers)
    }

    private static func writeKnownLengthFieldSection(_ out: inout Data, _ fields: [(String, String)]) throws {
        var section = Data()
        for (name, value) in fields {
            try writeLengthPrefixed(&section, name.lowercased().data(using: .ascii)!)
            try writeLengthPrefixed(&section, value.data(using: .isoLatin1)!)
        }
        try writeLengthPrefixed(&out, section)
    }

    private static func readKnownLengthFieldSection(_ reader: inout Reader) throws -> [(String, String)] {
        let sectionBytes = try reader.readLengthPrefixed()
        var section = Reader(bytes: sectionBytes)
        var fields: [(String, String)] = []

        while section.hasRemaining() {
            let name = String(data: try section.readLengthPrefixed(), encoding: .ascii)!
            let value = String(data: try section.readLengthPrefixed(), encoding: .isoLatin1)!
            fields.append((name, value))
        }

        return fields
    }

    private static func readIndeterminateFieldSection(_ reader: inout Reader) throws -> [(String, String)] {
        var fields: [(String, String)] = []

        while reader.hasRemaining() {
            let nameBytes = try reader.readLengthPrefixed()
            if nameBytes.isEmpty { break }  // content terminator
            let value = String(data: try reader.readLengthPrefixed(), encoding: .isoLatin1)!
            fields.append((String(data: nameBytes, encoding: .ascii)!, value))
        }

        return fields
    }

    private static func writeLengthPrefixed(_ out: inout Data, _ bytes: Data) throws {
        writeVarint(&out, UInt64(bytes.count))
        out.append(bytes)
    }

    /// QUIC variable-length integer (RFC 9000 §16).
    static func writeVarint(_ out: inout Data, _ value: UInt64) {
        if value < (1 << 6) {
            out.append(UInt8(value))
        } else if value < (1 << 14) {
            out.append(UInt8((value >> 8) | 0x40))
            out.append(UInt8(value & 0xFF))
        } else if value < (1 << 30) {
            out.append(UInt8((value >> 24) | 0x80))
            out.append(UInt8((value >> 16) & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF))
            out.append(UInt8(value & 0xFF))
        } else if value < (1 << 62) {
            out.append(UInt8((value >> 56) | 0xC0))
            for shift in stride(from: 48, through: 0, by: -8) {
                out.append(UInt8((value >> shift) & 0xFF))
            }
        }
    }

    struct Reader {
        private let bytes: Data
        private var pos: Int = 0

        init(bytes: Data) {
            self.bytes = bytes
        }

        mutating func hasRemaining() -> Bool {
            return pos < bytes.count
        }

        private mutating func readByte() throws -> UInt8 {
            guard pos < bytes.count else {
                throw OHTTPError.binaryHttpError("Truncated Binary HTTP message")
            }
            let byte = bytes[pos]
            pos += 1
            return byte
        }

        mutating func readVarint() throws -> UInt64 {
            let first = try readByte()
            let length = 1 << (first >> 6)
            var value = UInt64(first & 0x3F)

            for _ in 1..<length {
                value = (value << 8) | UInt64(try readByte())
            }

            return value
        }

        mutating func readLengthPrefixed() throws -> Data {
            let length = try readVarint()
            guard length <= bytes.count - pos else {
                throw OHTTPError.binaryHttpError("Truncated Binary HTTP field")
            }

            let result = bytes.subdata(in: pos..<pos + Int(length))
            pos += Int(length)
            return result
        }
    }
}
