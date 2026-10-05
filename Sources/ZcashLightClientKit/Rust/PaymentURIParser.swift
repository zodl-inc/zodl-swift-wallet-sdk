import Foundation
import libzcashlc

/// Rust-backed parser for supported cross-chain payment request URIs, backed by librustzcash's
/// `payment_uri` crate. Covers Bitcoin/Litecoin on-chain transfers (the on-chain subset of
/// [BIP 321](https://github.com/bitcoin/bips/blob/master/bip-0321.mediawiki) / legacy
/// [BIP 21](https://github.com/bitcoin/bips/blob/master/bip-0021.mediawiki)), EIP-681 Ethereum
/// requests (native and ERC-20 transfers; other ABI calls decode as `.unrecognised`), and
/// [Solana Pay](https://github.com/solana-foundation/solana-pay/blob/master/SPEC.md)
/// native/SPL-token transfers and interactive transaction-request links. All actual protocol
/// parsing and validation happens in the Rust crate; this type only decodes its versioned JSON
/// result into the Swift model types in `PaymentURIRequest.swift`.
public enum PaymentURIParser {
    /// Parses and validates a payment request URI.
    public static func parse(_ input: String) throws -> PaymentURIRequest {
        // A null byte would truncate the string at the FFI boundary (`CStr::from_ptr`
        // stops at the first NUL), so the Rust parser would silently validate only a
        // prefix of `input` instead of the whole string.
        guard !input.utf8.contains(0) else { throw PaymentURIParserError.invalidURI }
        guard let result = zcashlc_payment_uri_parse([CChar](input.utf8CString)) else {
            throw failureFromLastError()
        }
        defer { zcashlc_string_free(result) }

        let data = Data(bytes: result, count: strlen(result))
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> PaymentURIRequest {
        // The version is read from a minimal envelope first. Decoding the whole payload up front
        // let a `DecodingError` escape an API documented to throw only `PaymentURIParserError`,
        // and -- worse -- it threw before the version check, so a v2 envelope that retyped a field
        // failed as a malformed URI rather than as the version drift this field exists to catch.
        guard let envelope = try? JSONDecoder().decode(EncodedVersion.self, from: data) else {
            throw PaymentURIParserError.invalidEnvelope
        }
        guard envelope.version == encodedVersion else {
            throw PaymentURIParserError.unsupportedEnvelope(version: envelope.version)
        }
        guard let discriminator = try? JSONDecoder().decode(EncodedType.self, from: data) else {
            throw PaymentURIParserError.invalidEnvelope
        }

        do {
            let decoder = JSONDecoder()
            switch discriminator.type {
            case "bitcoin":
                return .bitcoin(try decoder.decode(EncodedUTXORequest.self, from: data).paymentRequest())
            case "ethereum_native":
                return .ethereum(.native(
                    try decoder.decode(EncodedEthereumNativeRequest.self, from: data).paymentRequest()
                ))
            case "ethereum_erc20":
                return .ethereum(.erc20(
                    try decoder.decode(EncodedEthereumErc20Request.self, from: data).paymentRequest()
                ))
            case "ethereum_unrecognised":
                return .ethereum(.unrecognised)
            case "litecoin":
                return .litecoin(try decoder.decode(EncodedUTXORequest.self, from: data).paymentRequest())
            case "solana_transfer":
                return .solanaTransfer(
                    try decoder.decode(EncodedSolanaTransferRequest.self, from: data).paymentRequest()
                )
            case "solana_transaction":
                return .solanaTransaction(
                    try decoder.decode(EncodedSolanaTransactionRequest.self, from: data).paymentRequest()
                )
            default:
                throw PaymentURIParserError.invalidEnvelope
            }
        } catch let error as PaymentURIParserError {
            throw error
        } catch {
            throw PaymentURIParserError.invalidEnvelope
        }
    }

    private static let encodedVersion = 1

    private static func failureFromLastError() -> PaymentURIParserError {
        classifyFailure(
            reported: peekLastErrorMessage(fallback: ""),
            clearRecognizedError: { zcashlc_clear_last_error() },
            redactedReport: {
                lastErrorReport(fallback: "the payment URI parser failed without an error report")
            }
        )
    }

    /// Maps the shared Rust error slot without allowing its raw text to cross the public boundary.
    ///
    /// The closures form an injectable error-channel seam for regression tests. Production first
    /// peeks at the slot: known fixed rejection tokens are safe to decode directly and are then
    /// cleared, while every other value is consumed through `lastErrorReport`, which retains the
    /// raw detail only in Rust's device-local debug log and returns a redacted report.
    static func classifyFailure(
        reported: String,
        clearRecognizedError: () -> Void,
        redactedReport: () -> RedactedRustError
    ) -> PaymentURIParserError {
        guard reported.hasPrefix(rejectionPrefix),
              let reason = PaymentURIRejection(rawValue: String(reported.dropFirst(rejectionPrefix.count))) else {
            return .parserFailure(redactedReport())
        }
        clearRecognizedError()
        return .rejected(reason)
    }
}

/// Prefix the Rust side puts before a classification token, so a token can be told apart from a
/// panic message that lands in the same last-error slot.
private let rejectionPrefix = "payment URI rejected: "

/// Just the envelope version, decoded before the payload so that a version mismatch is reported
/// as one even when the payload's own shape changed in the same revision.
private struct EncodedVersion: Decodable {
    let version: Int
}

private struct EncodedType: Decodable {
    let type: String
}

private struct EncodedUTXORequest: Decodable {
    let address: String
    let network: String
    let amount: String?
    let label: String?
    let message: String?

    func paymentRequest() throws -> UTXOPaymentURIRequest {
        let parsedNetwork: PaymentURINetwork
        switch network {
        case "mainnet": parsedNetwork = .mainnet
        case "testnet": parsedNetwork = .testnet
        case "regtest": parsedNetwork = .regtest
        default: throw PaymentURIParserError.invalidEnvelope
        }
        return UTXOPaymentURIRequest(
            address: PaymentURIAddress(validated: address),
            network: parsedNetwork,
            amount: amount.map(PaymentURIAmount.init(validated:)),
            label: label,
            message: message
        )
    }
}

private struct EncodedEthereumNativeRequest: Decodable {
    let schemaPrefix: String
    let hasPay: Bool
    let chainId: String?
    let recipientAddress: String
    let valueHex: String?
    let gasLimitHex: String?
    let gasPriceHex: String?

    enum CodingKeys: String, CodingKey {
        case schemaPrefix = "schema_prefix"
        case hasPay = "has_pay"
        case chainId = "chain_id"
        case recipientAddress = "recipient_address"
        case valueHex = "value_hex"
        case gasLimitHex = "gas_limit_hex"
        case gasPriceHex = "gas_price_hex"
    }

    func paymentRequest() throws -> Eip681NativeRequest {
        Eip681NativeRequest(
            schemaPrefix: schemaPrefix,
            hasPay: hasPay,
            chainId: try chainId.map(parseEncodedChainId),
            recipientAddress: recipientAddress,
            valueHex: valueHex,
            gasLimitHex: gasLimitHex,
            gasPriceHex: gasPriceHex
        )
    }
}

private struct EncodedEthereumErc20Request: Decodable {
    let schemaPrefix: String
    let hasPay: Bool
    let chainId: String?
    let tokenContractAddress: String
    let recipientAddress: String
    let valueHex: String

    enum CodingKeys: String, CodingKey {
        case schemaPrefix = "schema_prefix"
        case hasPay = "has_pay"
        case chainId = "chain_id"
        case tokenContractAddress = "token_contract_address"
        case recipientAddress = "recipient_address"
        case valueHex = "value_hex"
    }

    func paymentRequest() throws -> Eip681Erc20Request {
        Eip681Erc20Request(
            schemaPrefix: schemaPrefix,
            hasPay: hasPay,
            chainId: try chainId.map(parseEncodedChainId),
            tokenContractAddress: tokenContractAddress,
            recipientAddress: recipientAddress,
            valueHex: valueHex
        )
    }
}

private struct EncodedSolanaTransferRequest: Decodable {
    let recipient: String
    let amount: String?
    let splToken: String?
    let references: [String]?
    let label: String?
    let message: String?
    let memo: String?

    enum CodingKeys: String, CodingKey {
        case recipient, amount, references, label, message, memo
        case splToken = "spl_token"
    }

    func paymentRequest() -> SolanaPayTransferRequest {
        SolanaPayTransferRequest(
            recipient: PaymentURIAddress(validated: recipient),
            amount: amount.map(PaymentURIAmount.init(validated:)),
            splToken: splToken.map(PaymentURIAddress.init(validated:)),
            references: (references ?? []).map(PaymentURIAddress.init(validated:)),
            label: label,
            message: message,
            memo: memo
        )
    }
}

private struct EncodedSolanaTransactionRequest: Decodable {
    let link: String

    func paymentRequest() throws -> PaymentURILink {
        // The crate's `is_https_url` only checks that the string splits on "://", that the scheme
        // is https, and that the authority is non-empty and whitespace-free. Everything after the
        // authority is unchecked, and validation runs on the percent-decoded payload while the
        // reject-on-query guard tests the raw one. Keep this caller-input rejection distinct from
        // structural envelope failures handled by the variant-specific decode above.
        guard let url = URL(string: link), url.isCanonicalHTTPS else {
            throw PaymentURIParserError.invalidURI
        }
        return PaymentURILink(validated: link)
    }
}

private func parseEncodedChainId(_ value: String) throws -> UInt64 {
    guard let chainId = UInt64(value) else { throw PaymentURIParserError.invalidEnvelope }
    return chainId
}

/// Copies the current Rust last-error text without consuming it.
///
/// A known fixed rejection token is cleared directly. Every other value must remain in the slot
/// for `lastErrorReport` to consume and redact while logging the raw detail locally in Rust.
private func peekLastErrorMessage(fallback: String) -> String {
    let errorLen = zcashlc_last_error_length()
    guard errorLen > 0 else { return fallback }

    let error = UnsafeMutablePointer<Int8>.allocate(capacity: Int(errorLen))
    defer { error.deallocate() }
    zcashlc_error_message_utf8(error, errorLen)
    return String(validatingUTF8: error) ?? fallback
}

private extension URL {
    /// An absolute `https://` URL with a real host and no embedded credentials.
    ///
    /// Rejects the userinfo form (`https://trusted.example.com@evil.test/pay`), where a display
    /// that truncates on length shows the trusted-looking prefix while the request goes to the
    /// host after the `@`.
    var isCanonicalHTTPS: Bool {
        guard scheme?.lowercased() == "https" else { return false }
        guard let host, !host.isEmpty else { return false }
        return user == nil && password == nil
    }
}
