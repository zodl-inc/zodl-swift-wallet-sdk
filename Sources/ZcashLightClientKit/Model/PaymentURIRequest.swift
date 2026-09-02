import Foundation

// Public model types decoded from librustzcash's `payment_uri` crate. Covers Bitcoin/Litecoin
// on-chain transfers (the on-chain subset of BIP 321 / legacy BIP 21), EIP-681 Ethereum requests
// (native and ERC-20 transfers; other ABI calls decode as `.unrecognised`), and Solana Pay
// native/SPL-token transfers and interactive transaction-request links. All actual protocol
// parsing and validation happens in the Rust crate (see PaymentURIParser.swift); these types
// only carry its already-validated, versioned JSON result.

/// A cross-chain address validated by the Rust payment URI parser.
public struct PaymentURIAddress: Equatable {
    /// The canonical address text supplied by the payment request.
    public let value: String

    init(validated value: String) {
        self.value = value
    }

    /// Builds a value directly. The parser uses `init(validated:)`; this exists so that
    /// consumers can construct canned results for tests and dependency doubles.
    public init(value: String) {
        self.value = value
    }
}

/// An exact non-negative decimal amount from a payment request.
public struct PaymentURIAmount: Equatable {
    /// The decimal value without floating-point conversion.
    public let value: String

    init(validated value: String) {
        self.value = value
    }

    /// Builds a value directly. The parser uses `init(validated:)`; this exists so that
    /// consumers can construct canned results for tests and dependency doubles.
    public init(value: String) {
        self.value = value
    }
}

/// An interactive Solana Pay transaction-request link validated by the Rust payment URI parser.
public struct PaymentURILink: Equatable {
    /// The canonical link text supplied by the payment request.
    public let value: String

    init(validated value: String) {
        self.value = value
    }

    /// Builds a value directly. The parser uses `init(validated:)`; this exists so that
    /// consumers can construct canned results for tests and dependency doubles.
    public init(value: String) {
        self.value = value
    }
}

/// A network encoded by a Bitcoin or Litecoin address.
public enum PaymentURINetwork: Equatable {
    case mainnet
    case testnet
    case regtest
}

/// A validated Bitcoin or Litecoin payment request.
public struct UTXOPaymentURIRequest: Equatable {
    public let address: PaymentURIAddress
    public let network: PaymentURINetwork
    public let amount: PaymentURIAmount?
    public let label: String?
    public let message: String?

    public init(
        address: PaymentURIAddress,
        network: PaymentURINetwork,
        amount: PaymentURIAmount?,
        label: String?,
        message: String?
    ) {
        self.address = address
        self.network = network
        self.amount = amount
        self.label = label
        self.message = message
    }
}

/// A validated Solana Pay transfer request.
public struct SolanaPayTransferRequest: Equatable {
    public let recipient: PaymentURIAddress
    public let amount: PaymentURIAmount?
    public let splToken: PaymentURIAddress?
    public let references: [PaymentURIAddress]
    public let label: String?
    public let message: String?
    public let memo: String?

    public init(
        recipient: PaymentURIAddress,
        amount: PaymentURIAmount?,
        splToken: PaymentURIAddress?,
        references: [PaymentURIAddress],
        label: String?,
        message: String?,
        memo: String?
    ) {
        self.recipient = recipient
        self.amount = amount
        self.splToken = splToken
        self.references = references
        self.label = label
        self.message = message
        self.memo = memo
    }
}

/// A parsed cross-chain payment request.
public enum PaymentURIRequest: Equatable {
    case bitcoin(UTXOPaymentURIRequest)
    case ethereum(Eip681TransactionRequest)
    case litecoin(UTXOPaymentURIRequest)
    case solanaTransfer(SolanaPayTransferRequest)
    case solanaTransaction(PaymentURILink)
}

/// Why the Rust parser rejected a payment URI. Mirrors `payment_uri::Error`'s variants without
/// carrying the offending fragment of the input, which stays on the Rust side of the FFI.
public enum PaymentURIRejection: String, Equatable, Sendable {
    case missingScheme = "missing_scheme"
    case unsupportedScheme = "unsupported_scheme"
    case missingRecipient = "missing_recipient"
    case invalidAddress = "invalid_address"
    case invalidAmount = "invalid_amount"
    case duplicateParameter = "duplicate_parameter"
    case unsupportedRequiredParameter = "unsupported_required_parameter"
    case invalidEncoding = "invalid_encoding"
    case invalidTransactionLink = "invalid_transaction_link"
    case ethereum

    /// A variant added to the Rust crate that this SDK version does not know about yet.
    case unclassified
}

/// Errors returned by ``PaymentURIParser``.
public enum PaymentURIParserError: Error, Equatable {
    /// The input is not a payment request this SDK supports, or it failed protocol validation.
    case invalidURI

    /// The Rust core produced an envelope version this SDK cannot read -- the SDK is older than
    /// the core it is linked against. Distinct from `invalidURI`, which means the user's input
    /// was bad rather than the two halves of the SDK disagreeing.
    case unsupportedEnvelope(version: Int)

    /// The envelope was not the shape this SDK expects: malformed JSON, a missing field, or a
    /// field whose type changed. Also a core/SDK mismatch, not a bad URI.
    case invalidEnvelope

    /// The Rust parser rejected the input, with the reason it gave.
    case rejected(PaymentURIRejection)

    /// The Rust parser failed without a recognised classification -- in practice a panic caught
    /// at the FFI boundary. Distinct from `rejected` so a crash is not reported as a bad scan.
    case parserFailure(String)
}
