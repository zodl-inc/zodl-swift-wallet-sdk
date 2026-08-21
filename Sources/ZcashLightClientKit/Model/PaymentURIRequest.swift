import Foundation

/// A cross-chain address validated by the Rust payment URI parser.
public struct PaymentURIAddress: Equatable {
    /// The canonical address text supplied by the payment request.
    public let value: String

    init(validated value: String) {
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
}

/// An interactive Solana Pay transaction-request link validated by the Rust payment URI parser.
public struct PaymentURILink: Equatable {
    /// The canonical link text supplied by the payment request.
    public let value: String

    init(validated value: String) {
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
}

/// A parsed cross-chain payment request.
public enum PaymentURIRequest: Equatable {
    case bitcoin(UTXOPaymentURIRequest)
    case ethereum(Eip681TransactionRequest)
    case litecoin(UTXOPaymentURIRequest)
    case solanaTransfer(SolanaPayTransferRequest)
    case solanaTransaction(PaymentURILink)
}

/// Errors returned by ``PaymentURIParser``.
public enum PaymentURIParserError: Error, Equatable {
    case invalidURI
}
