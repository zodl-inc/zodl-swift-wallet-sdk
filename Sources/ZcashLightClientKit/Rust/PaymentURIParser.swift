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
            // The Rust side puts a fixed classification token in the last-error slot, so the ten
            // crate error variants no longer collapse into one value. Reading it also separates a
            // genuine parser panic -- which `catch_panic` writes to the same slot -- from an
            // ordinary bad URI; that used to reach the caller as a rejected scan and was never
            // surfaced. The tokens carry no caller input.
            let reported = lastErrorMessage(fallback: "")
            guard let token = reported.components(separatedBy: rejectionPrefix).last,
                  reported.hasPrefix(rejectionPrefix),
                  let reason = PaymentURIRejection(rawValue: token) else {
                throw PaymentURIParserError.parserFailure(reported)
            }
            throw PaymentURIParserError.rejected(reason)
        }
        defer { zcashlc_string_free(result) }

        let data = Data(bytes: result, count: strlen(result))

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
        guard let decoded = try? JSONDecoder().decode(EncodedRequest.self, from: data) else {
            throw PaymentURIParserError.invalidEnvelope
        }
        return try decoded.paymentRequest
    }

    private static let encodedVersion = 1
}

/// Prefix the Rust side puts before a classification token, so a token can be told apart from a
/// panic message that lands in the same last-error slot.
private let rejectionPrefix = "payment URI rejected: "

/// Just the envelope version, decoded before the payload so that a version mismatch is reported
/// as one even when the payload's own shape changed in the same revision.
private struct EncodedVersion: Decodable {
    let version: Int
}

struct EncodedRequest: Decodable {
    let version: Int
    let type: String
    let address: String?
    let network: String?
    let amount: String?
    let label: String?
    let message: String?
    let schemaPrefix: String?
    let hasPay: Bool?
    let chainId: String?
    let recipientAddress: String?
    let tokenContractAddress: String?
    let valueHex: String?
    let gasLimitHex: String?
    let gasPriceHex: String?
    let recipient: String?
    let splToken: String?
    let references: [String]?
    let memo: String?
    let link: String?

    enum CodingKeys: String, CodingKey {
        case version, type, address, network, amount, label, message, recipient, references, memo, link
        case splToken = "spl_token"
        case schemaPrefix = "schema_prefix"
        case hasPay = "has_pay"
        case chainId = "chain_id"
        case recipientAddress = "recipient_address"
        case tokenContractAddress = "token_contract_address"
        case valueHex = "value_hex"
        case gasLimitHex = "gas_limit_hex"
        case gasPriceHex = "gas_price_hex"
    }

    var paymentRequest: PaymentURIRequest {
        get throws {
            switch type {
            case "bitcoin": return .bitcoin(try utxoRequest())
            case "ethereum_native": return .ethereum(try ethereumNativeRequest())
            case "ethereum_erc20": return .ethereum(try ethereumErc20Request())
            case "ethereum_unrecognised": return .ethereum(.unrecognised)
            case "litecoin": return .litecoin(try utxoRequest())
            case "solana_transfer": return .solanaTransfer(try solanaTransfer())
            case "solana_transaction":
                // The crate's `is_https_url` only checks that the string splits on "://", that the
                // scheme is https, and that the authority is non-empty and whitespace-free --
                // everything after the authority is unchecked. It also runs on the percent-DECODED
                // payload while the reject-on-query guard tests the RAW one, so a decoded link can
                // carry a query the guard never saw, or a userinfo "@" that makes a hostile host
                // display as a trusted one. This re-validates rather than trusting that.
                guard let link, let url = URL(string: link), url.isCanonicalHTTPS else {
                    throw PaymentURIParserError.invalidURI
                }
                return .solanaTransaction(PaymentURILink(validated: link))
            default: throw PaymentURIParserError.invalidURI
            }
        }
    }

    private func ethereumNativeRequest() throws -> Eip681TransactionRequest {
        guard let schemaPrefix, let hasPay, let recipientAddress else {
            throw PaymentURIParserError.invalidURI
        }
        return .native(Eip681NativeRequest(
            schemaPrefix: schemaPrefix,
            hasPay: hasPay,
            chainId: try chainId.map(parseChainId),
            recipientAddress: recipientAddress,
            valueHex: valueHex,
            gasLimitHex: gasLimitHex,
            gasPriceHex: gasPriceHex
        ))
    }

    private func ethereumErc20Request() throws -> Eip681TransactionRequest {
        guard let schemaPrefix, let hasPay, let tokenContractAddress, let recipientAddress, let valueHex else {
            throw PaymentURIParserError.invalidURI
        }
        return .erc20(Eip681Erc20Request(
            schemaPrefix: schemaPrefix,
            hasPay: hasPay,
            chainId: try chainId.map(parseChainId),
            tokenContractAddress: tokenContractAddress,
            recipientAddress: recipientAddress,
            valueHex: valueHex
        ))
    }

    private func parseChainId(_ value: String) throws -> UInt64 {
        guard let chainId = UInt64(value) else { throw PaymentURIParserError.invalidURI }
        return chainId
    }

    private func utxoRequest() throws -> UTXOPaymentURIRequest {
        guard let address, let network else { throw PaymentURIParserError.invalidURI }
        let parsedNetwork: PaymentURINetwork
        switch network {
        case "mainnet": parsedNetwork = .mainnet
        case "testnet": parsedNetwork = .testnet
        case "regtest": parsedNetwork = .regtest
        default: throw PaymentURIParserError.invalidURI
        }
        return UTXOPaymentURIRequest(
            address: PaymentURIAddress(validated: address),
            network: parsedNetwork,
            amount: amount.map(PaymentURIAmount.init(validated:)),
            label: label,
            message: message
        )
    }

    private func solanaTransfer() throws -> SolanaPayTransferRequest {
        guard let recipient else { throw PaymentURIParserError.invalidURI }
        return SolanaPayTransferRequest(
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
