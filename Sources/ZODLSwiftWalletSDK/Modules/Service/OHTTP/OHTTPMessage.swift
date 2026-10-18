//
//  OHTTPMessage.swift
//  ZODLSwiftWalletSDK
//
//  The HTTP request and response an OHTTP exchange carries, as the transport's callers see them.
//  The Binary HTTP (RFC 9292) codec itself lives in the shared Rust core; this file only turns Swift
//  strings into the bytes the core takes and back.
//

import Foundation

/// A request to send through the OHTTP relay and gateway.
struct OHTTPRequest {
    let method: String
    let scheme: String
    let authority: String
    let path: String
    let headers: [(String, String)]
    let body: Data
}

/// The gateway's answer to an ``OHTTPRequest``.
struct OHTTPResponse {
    let status: Int
    let headers: [(String, String)]
    let body: Data
    let trailers: [(String, String)]

    /// Case-insensitive lookup: trailers first, then headers. gRPC status is in trailers.
    func field(_ name: String) -> String? {
        let lowercaseName = name.lowercased()
        for (key, value) in trailers + headers where key.lowercased() == lowercaseName {
            return value
        }
        return nil
    }

    /// Whether this is the gateway's freshness refusal: status 400 with `ohttp-freshness: rejected` in the
    /// header section.
    var isFreshnessRefusal: Bool {
        status == 400 && headers.contains { name, value in
            name.lowercased() == "ohttp-freshness"
                && value.trimmingCharacters(in: .whitespaces).lowercased() == "rejected"
        }
    }
}

/// A request as the bytes the Rust core encodes: the control data and the packed header list.
struct OHTTPRequestBytes {
    let method: Data
    let scheme: Data
    let authority: Data
    let path: Data
    /// The header fields packed by ``OHTTPFieldList/pack(_:)``.
    let headers: Data
}

extension OHTTPRequest {
    /// Request text as bytes: control data and header names as ASCII, header values as ISO-8859-1.
    /// Text outside those encodings is an error, where the Swift codec this replaces trapped. The
    /// message names the part but never quotes it.
    func nativeBytes() throws -> OHTTPRequestBytes {
        func ascii(_ text: String, _ what: String) throws -> Data {
            guard let data = text.data(using: .ascii) else {
                throw OHTTPError.binaryHttpError("The request \(what) is not ASCII")
            }
            return data
        }

        var fields: [(Data, Data)] = []
        fields.reserveCapacity(headers.count)
        for (name, value) in headers {
            guard let valueBytes = value.data(using: .isoLatin1) else {
                throw OHTTPError.binaryHttpError("A request header value is not ISO-8859-1")
            }
            fields.append((try ascii(name, "header name"), valueBytes))
        }

        return OHTTPRequestBytes(
            method: try ascii(method, "method"),
            scheme: try ascii(scheme, "scheme"),
            authority: try ascii(authority, "authority"),
            path: try ascii(path, "path"),
            headers: try OHTTPFieldList.pack(fields)
        )
    }
}

/// The list of header or trailer fields as one byte array, the shape the C functions take and return:
/// for each name and then each value, a 4-byte big-endian length and the bytes.
enum OHTTPFieldList {
    static func pack(_ fields: [(Data, Data)]) throws -> Data {
        var out = Data()
        for (name, value) in fields {
            for part in [name, value] {
                guard let length = UInt32(exactly: part.count) else {
                    throw OHTTPError.binaryHttpError("A header field is too long")
                }
                withUnsafeBytes(of: length.bigEndian) { out.append(contentsOf: $0) }
                out.append(part)
            }
        }
        return out
    }

    static func unpack(_ packed: Data) throws -> [(Data, Data)] {
        var parts: [Data] = []
        var position = packed.startIndex
        while position < packed.endIndex {
            guard packed.endIndex - position >= 4 else {
                throw OHTTPError.binaryHttpError("Truncated header field length")
            }
            let length = packed[position..<position + 4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            position += 4
            guard length <= UInt64(packed.endIndex - position) else {
                throw OHTTPError.binaryHttpError("Truncated header field")
            }
            let end = position + Int(length)
            parts.append(packed.subdata(in: position..<end))
            position = end
        }
        guard parts.count % 2 == 0 else {
            throw OHTTPError.binaryHttpError("A header name without a value")
        }
        return stride(from: 0, to: parts.count, by: 2).map { (parts[$0], parts[$0 + 1]) }
    }

    /// Field bytes as text, each byte one character (ISO-8859-1): how a header read from the gateway
    /// has always been decoded here. It cannot fail, where a strict decoding would.
    static func latin1(_ data: Data) -> String {
        String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) }))
    }
}
