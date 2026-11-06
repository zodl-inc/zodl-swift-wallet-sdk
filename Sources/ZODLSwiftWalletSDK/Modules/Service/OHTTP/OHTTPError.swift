//
//  OHTTPError.swift
//  ZODLSwiftWalletSDK
//
//  Errors of the OHTTP (RFC 9458) transport.
//

import Foundation

/// OHTTP-specific errors.
enum OHTTPError: Error {
    case hpkeError(String)
    case binaryHttpError(String)
    case transportError(String)
    case httpStatusError(statusCode: Int, message: String)
    case keyConfigError(String)
    case responseTooLarge(String)
    /// The sealed request is larger than the relay and the gateway accept; it was not sent.
    case requestTooLarge(String)
}

extension OHTTPError {
    /// The error for a failure the shared Rust core reported, by the fixed prefix of its message.
    /// The core's messages never echo request or response content.
    static func native(_ message: String) -> OHTTPError {
        // A response cut off before its final chunk is a transport failure, not a format one.
        if message.hasPrefix("the gateway's answer ended before its final chunk") {
            return .transportError(message)
        }
        if message.hasPrefix("binary HTTP") || message.hasPrefix("the gateway's answer") {
            return .binaryHttpError(message)
        }
        if message.hasPrefix("an answer larger than") {
            return .responseTooLarge(message)
        }
        if message.hasPrefix("sealing failed") {
            return .hpkeError(message)
        }
        if message.hasPrefix("key configuration") {
            return .keyConfigError(message)
        }
        return .transportError(message)
    }
}
