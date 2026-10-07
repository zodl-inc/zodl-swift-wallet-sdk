//
//  GiftCard.swift
//  ZcashLightClientKit
//

import CryptoKit
import Foundation

/// A Zcash gift card read from a bearer link.
///
/// A gift card is a liberated payment (ZIP 324): a small, single-purpose wallet whose key travels
/// in the link itself. The link is any `https` URL whose fragment carries the card, in the `v=1`
/// format `https://gift.zodl.com/#v=1&key=zgift1...&height=<birthday>[&amount=<ZEC>][&desc=<text>]`
/// or in the legacy JSON payment-link encoding at `/payment-links/open#v1=…`, `#v2=…` or `#v3=…`.
/// The card wallet is ZIP 32 account 0 of the card's BIP 39 seed, and its funds sit at that
/// account's Orchard-only default address (in the Ironwood pool since NU6.3).
///
/// Anyone holding the link can spend the card, including whoever issued it, who can rederive its
/// key. Treat the link like cash, and redeem it with ``GiftCardRedeemer``, which sweeps the funds
/// to the user's own wallet without leaving the recipient recoverable from the card's key.
///
/// The card's seed never leaves the SDK, and the value's `description`, `debugDescription` and
/// reflection are redacted so that printing or logging a card cannot leak it. The seed is held in
/// a buffer that is wiped when the last copy of the card is released, and it takes no part in
/// equality: two cards are equal when their public fields are, and the funding address, derived
/// from the seed, already identifies the card.
public struct GiftCard: Equatable, Undescribable {
    /// The encoding a gift card link was read from.
    public enum Origin: Equatable, Sendable {
        /// A `v=1` link (`https://<host>#v=1&key=…&height=…`), as `https://gift.zodl.com/` issues.
        case zodl
        /// A legacy `v1=` JSON payment link (`/payment-links/open#v1=…`).
        case legacyV1
        /// A legacy `v2=` JSON payment link (`/payment-links/open#v2=…`).
        case legacyV2
        /// A legacy `v3=` JSON payment link (`/payment-links/open#v3=…`).
        case legacyV3
    }

    /// The card wallet's 64-byte BIP 39 seed, kept out of every textual representation.
    ///
    /// The bytes live in memory this object owns and wipes when it is released, never in a Swift
    /// array that could be copied and left behind. ``withBytes(_:)`` and ``withBytesAsync(_:)``
    /// lend them out as a temporary array, wiped as soon as the call returns, for the SDK calls
    /// that take `[UInt8]`.
    final class Seed: Undescribable {
        private let storage: UnsafeMutableRawBufferPointer

        /// Copies `bytes` into wipeable storage. The caller wipes its own copy.
        init(copying bytes: UnsafeRawBufferPointer) {
            storage = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes.count, alignment: 1)
            storage.copyMemory(from: bytes)
        }

        deinit {
            Self.wipe(storage)
            storage.deallocate()
        }

        var count: Int { storage.count }

        /// Calls `body` with a temporary copy of the seed, which is wiped when `body` returns.
        ///
        /// A callee that keeps the array keeps its own copy, which this cannot wipe; the SDK calls
        /// this is used for (wallet preparation, key derivation) pass it on to the rust layer and
        /// drop it.
        func withBytesAsync<T>(_ body: ([UInt8]) async throws -> T) async rethrows -> T {
            var bytes = [UInt8](storage)
            defer { bytes.withUnsafeMutableBytes { Self.wipe($0) } }
            return try await body(bytes)
        }

        /// The synchronous form of ``withBytesAsync(_:)``.
        func withBytes<T>(_ body: ([UInt8]) throws -> T) rethrows -> T {
            var bytes = [UInt8](storage)
            defer { bytes.withUnsafeMutableBytes { Self.wipe($0) } }
            return try body(bytes)
        }

        /// Zeroes `buffer` with `memset_s`, which the compiler may not elide.
        private static func wipe(_ buffer: UnsafeMutableRawBufferPointer) {
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }
    }

    /// The encoding the link was read from.
    public let origin: Origin

    /// The network the card is on.
    public let network: NetworkType

    /// The height from which the card wallet scans for its funds; at or below the height of the
    /// transaction that funded the card, and never below the network's NU5 activation height.
    public let birthdayHeight: BlockHeight

    /// The amount the link says the card holds, if it states one.
    ///
    /// This is informational and unverified: anyone can edit a link. Only the balance that
    /// ``GiftCardRedeemer/check()`` finds on chain is authoritative.
    public let statedAmount: Zatoshi?

    /// The message the link carries, if any, sanitized as ``init(link:)`` describes. It is text
    /// chosen by whoever made the link; display it as untrusted user content.
    public let message: String?

    /// The card wallet's Orchard-only default address, which the card is funded at.
    ///
    /// It is derived from the card's key, so it identifies the card on chain without revealing the
    /// key; it is safe to display or log.
    public let fundingAddress: UnifiedAddress

    let seed: Seed

    init(
        origin: Origin,
        network: NetworkType,
        birthdayHeight: BlockHeight,
        statedAmount: Zatoshi?,
        description: String?,
        fundingAddress: UnifiedAddress,
        seed: Seed
    ) {
        self.origin = origin
        self.network = network
        self.birthdayHeight = birthdayHeight
        self.statedAmount = statedAmount
        self.message = description
        self.fundingAddress = fundingAddress
        self.seed = seed
    }

    /// Reads a gift card link.
    ///
    /// Parsing is done by the SDK's rust layer. It is offline: no database, no network.
    /// Surrounding whitespace is ignored.
    ///
    /// The link's description is sanitized by the rust layer before it becomes ``message``: line
    /// breaks and other control whitespace become a space, and control and invisible formatting
    /// characters (bidi overrides and isolates, zero-width spaces and the like) are removed. A
    /// description that is blank afterwards is absent.
    ///
    /// - Parameter link: the link, as scanned or opened.
    /// - Throws: one error per reason the SDK cannot read the link, none of which carries any part
    ///   of it:
    ///   - ``ZcashError/giftCardLinkNotAGiftCard``: not an `https` URL carrying a gift card.
    ///   - ``ZcashError/giftCardLinkUnsupportedVersion``: a gift card link of a newer version.
    ///   - ``ZcashError/giftCardLinkUnsupportedNetwork``: a card for regtest or an unknown network.
    ///   - ``ZcashError/giftCardLinkInvalidBirthday``: a malformed birthday height, or one below the
    ///     network's NU5 activation height.
    ///   - ``ZcashError/giftCardLinkInvalid``: any other malformed link.
    public init(link: String) throws {
        self = try ZcashKeyDerivationBackend.parseGiftCardLink(link)
    }

    public static func == (lhs: GiftCard, rhs: GiftCard) -> Bool {
        lhs.origin == rhs.origin
            && lhs.network == rhs.network
            && lhs.birthdayHeight == rhs.birthdayHeight
            && lhs.statedAmount == rhs.statedAmount
            && lhs.message == rhs.message
            && lhs.fundingAddress == rhs.fundingAddress
    }

    /// The start of every card wallet's custom alias.
    static let aliasPrefix = "giftcard_"

    /// A synchronizer alias unique to this card.
    ///
    /// It is derived from a hash of the card's funding address, so it is stable for the card,
    /// distinct between cards, contains no secret, and is short enough for a file name.
    var synchronizerAlias: ZcashSynchronizerAlias {
        let digest = SHA256.hash(data: Data(fundingAddress.stringEncoded.utf8))
        let prefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return .custom("\(Self.aliasPrefix)\(prefix)")
    }
}
