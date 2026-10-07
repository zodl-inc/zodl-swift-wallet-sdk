//! Liberated payments (ZIP 324): payments encapsulated in a URI that carries the key of a
//! small, single-purpose wallet.
//!
//! A *minter* creates a *payment secret*, funds the *payment wallet* derived from it, and
//! hands the secret to a *claimant* inside a link. The claimant imports the payment wallet
//! and sweeps its funds into a wallet of their own. Nothing about the payment is tied to
//! the host that serves the link: the secret travels in the URI fragment, which browsers
//! never send to the server.
//!
//! A payment secret is 32 bytes: the entropy of a 24-word English BIP 39 phrase. The
//! payment wallet is ZIP 32 account 0 of that phrase's seed (empty passphrase), and funds
//! are sent to its Orchard-only default address. Any wallet that can restore a phrase can
//! therefore recover a payment.
//!
//! Secrets minted from a wallet are derived from that wallet's seed with ZIP 32 registered
//! key derivation under ZIP 324, so a minter can always rederive (and reclaim) payments
//! that were never claimed:
//!
//! ```text
//! secret_i = registered::SecretKey::from_subpath("Zcash_URIEncapsulatedPayment", seed, 324,
//!                                                [coin_type', i']).data()
//! ```
//!
//! A payment is shared as a link whose fragment carries the secret:
//!
//! ```text
//! https://<host>#v=1&key=<bech32m secret>&height=<birthday>[&amount=<ZEC>][&desc=<text>]
//! ```
//!
//! The Bech32m human-readable part of `key` (`zgift`, `zgifttest` or `zgiftregtest`, in
//! either case but not mixed) selects the network. `height` is a block height at or below
//! the height of the transaction that funded the payment, from which a wallet scans for
//! its funds. It must be at or above the network's NU5 activation height (any positive
//! height on regtest): payment wallets hold Orchard funds only, which cannot exist before
//! NU5. No upper bound is enforced beyond `u32`; a wallet compares it with the chain tip.
//!
//! `v`, `key` and `height` are strict: a missing, repeated or malformed one rejects the
//! link. `amount` and `desc` are informational (the funds found on chain are
//! authoritative), so a malformed, out-of-range, over-long or repeated one is read as
//! absent rather than making a funded payment unclaimable. Descriptions are sanitized on
//! read (see [`LiberatedPayment::description`]). Empty and unknown parameters are ignored
//! so that later versions can add optional ones.
//!
//! This module also reads the legacy JSON payment-link encoding found in the wild at
//! `/payment-links/open#vN=` (`v1`, `v2` and `v3` base64url payloads), which uses the same
//! key shape.

use std::fmt;

use base64::{
    Engine,
    engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD},
};
use bech32::{Bech32m, Hrp, primitives::decode::CheckedHrpstring};
use bip0039::{English, Mnemonic};
use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, percent_decode_str, utf8_percent_encode};
use secrecy::zeroize::Zeroizing;
use zcash_keys::keys::{UnifiedAddressRequest, UnifiedSpendingKey};
use zcash_primitives::transaction::fees::zip317;
use zcash_protocol::{
    consensus::{
        BlockHeight, MAIN_NETWORK, NetworkConstants, NetworkType, NetworkUpgrade, Parameters,
        TEST_NETWORK,
    },
    value::{COIN, Zatoshis},
};
use zip32::{
    AccountId, ChildIndex,
    registered::{PathElement, SecretKey},
};

/// The ZIP 32 context string for payment secrets derived from a wallet seed.
pub const DERIVATION_CONTEXT: &[u8] = b"Zcash_URIEncapsulatedPayment";

/// The ZIP under which payment secrets are registered.
pub const DERIVATION_ZIP: u16 = 324;

/// The fee that a payment is funded with on top of its face value so that claiming it
/// does not reduce the face value: the ZIP 317 minimum fee (one two-action transaction).
pub const CLAIM_FEE_RESERVE: Zatoshis = zip317::MINIMUM_FEE;

/// The Bech32m human-readable part of a mainnet payment key.
pub const KEY_HRP_MAIN: &str = "zgift";
/// The Bech32m human-readable part of a testnet payment key.
pub const KEY_HRP_TEST: &str = "zgifttest";
/// The Bech32m human-readable part of a regtest payment key.
pub const KEY_HRP_REGTEST: &str = "zgiftregtest";

/// The largest link this module will parse.
pub const MAX_LINK_LENGTH: usize = 16 * 1024;

/// The longest description, in UTF-8 bytes, that a link may carry.
pub const MAX_DESCRIPTION_BYTES: usize = 512;

const LINK_VERSION: &str = "1";

/// Characters of a description written literally in a link: RFC 3986 unreserved
/// characters. Everything else is percent-encoded (as UTF-8, upper-case hex).
const DESCRIPTION_ENCODE_SET: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

/// Errors produced while minting, reading or using a liberated payment.
///
/// Messages never include any part of the link, which carries a spending secret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The text is not a liberated payment link of any supported kind.
    NotAPaymentLink,
    /// The link is a liberated payment link of a version this code does not read.
    UnsupportedVersion,
    /// A required field is missing.
    MissingField(&'static str),
    /// A field appears more than once.
    DuplicateField(&'static str),
    /// A field is present but malformed or out of range.
    InvalidField(&'static str),
    /// The link is for a network this code does not support.
    UnsupportedNetwork,
    /// The payment is for a different network than the wallet using it.
    NetworkMismatch,
    /// The link is longer than [`MAX_LINK_LENGTH`].
    TooLong,
    /// The payment's key could not be derived.
    KeyDerivation,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::NotAPaymentLink => write!(f, "not a liberated payment link"),
            Error::UnsupportedVersion => write!(f, "unsupported payment link version"),
            Error::MissingField(name) => write!(f, "payment link is missing `{name}`"),
            Error::DuplicateField(name) => write!(f, "payment link repeats `{name}`"),
            Error::InvalidField(name) => write!(f, "payment link has an invalid `{name}`"),
            Error::UnsupportedNetwork => write!(f, "payment link is for an unsupported network"),
            Error::NetworkMismatch => write!(f, "payment is for a different network"),
            Error::TooLong => write!(f, "payment link is too long"),
            Error::KeyDerivation => write!(f, "payment key could not be derived"),
        }
    }
}

impl std::error::Error for Error {}

/// The encoding a liberated payment link was read from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Origin {
    /// A `v=1` link in the format described at the top of this module.
    V1,
    /// A legacy `v1=` JSON payload.
    LegacyV1,
    /// A legacy `v2=` JSON payload.
    LegacyV2,
    /// A legacy `v3=` JSON payload.
    LegacyV3,
}

impl Origin {
    /// Returns a stable, machine-readable name for the origin.
    pub fn as_str(self) -> &'static str {
        match self {
            Origin::V1 => "v1",
            Origin::LegacyV1 => "legacy-v1",
            Origin::LegacyV2 => "legacy-v2",
            Origin::LegacyV3 => "legacy-v3",
        }
    }
}

/// The secret that controls a payment wallet: BIP 39 entropy, or (for older legacy links)
/// the phrase itself. Both are wiped when dropped.
enum Secret {
    Entropy(Zeroizing<Vec<u8>>),
    Phrase(Zeroizing<String>),
}

/// A liberated payment read from, or ready to be written as, a link.
pub struct LiberatedPayment {
    origin: Origin,
    network: NetworkType,
    secret: Secret,
    birthday_height: BlockHeight,
    amount: Option<Zatoshis>,
    description: Option<String>,
}

impl fmt::Debug for LiberatedPayment {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LiberatedPayment")
            .field("origin", &self.origin)
            .field("network", &self.network)
            .field("secret", &"<redacted>")
            .field("birthday_height", &self.birthday_height)
            .field("amount", &self.amount)
            .field("description", &self.description)
            .finish()
    }
}

/// Derives the secret of payment `index` from a minter's wallet seed.
pub fn derive_payment_secret<P: Parameters>(
    params: &P,
    seed: &[u8],
    index: u32,
) -> Result<Zeroizing<[u8; 32]>, Error> {
    // `ChildIndex::hardened` panics on indices of 2^31 and above.
    if index >= (1 << 31) {
        return Err(Error::KeyDerivation);
    }
    let key = SecretKey::from_subpath(
        DERIVATION_CONTEXT,
        seed,
        DERIVATION_ZIP,
        &[
            PathElement::new(ChildIndex::hardened(params.network_type().coin_type()), &[]),
            PathElement::new(ChildIndex::hardened(index), &[]),
        ],
    )
    .map_err(|_| Error::KeyDerivation)?;
    Ok(Zeroizing::new(*key.data()))
}

/// Returns the lowest birthday height a payment on `network` may have: the network's NU5
/// activation height, since payment wallets hold Orchard funds only. Regtest has no fixed
/// activation heights, so any positive height is allowed there.
pub fn min_birthday_height(network: NetworkType) -> BlockHeight {
    let nu5 = match network {
        NetworkType::Main => MAIN_NETWORK.activation_height(NetworkUpgrade::Nu5),
        NetworkType::Test => TEST_NETWORK.activation_height(NetworkUpgrade::Nu5),
        NetworkType::Regtest => None,
    };
    nu5.unwrap_or(BlockHeight::from_u32(1))
}

impl LiberatedPayment {
    /// Creates a payment in the `v=1` format.
    ///
    /// The birthday must be at or above [`min_birthday_height`], and the description, if
    /// any, must be at most [`MAX_DESCRIPTION_BYTES`] long, not blank, and free of the
    /// characters that reading a link strips (see [`LiberatedPayment::description`]).
    pub fn new(
        network: NetworkType,
        secret: &[u8; 32],
        birthday_height: BlockHeight,
        amount: Option<Zatoshis>,
        description: Option<String>,
    ) -> Result<Self, Error> {
        let birthday_height = check_birthday(network, u32::from(birthday_height))?;
        let description_ok = description.iter().all(|text| {
            text.len() <= MAX_DESCRIPTION_BYTES
                && sanitize_description(text).as_deref() == Some(text.as_str())
        });
        if !description_ok {
            return Err(Error::InvalidField("desc"));
        }
        Ok(LiberatedPayment {
            origin: Origin::V1,
            network,
            secret: Secret::Entropy(Zeroizing::new(secret.to_vec())),
            birthday_height,
            amount,
            description,
        })
    }

    /// Reads a liberated payment link of any supported kind.
    ///
    /// The link must be an `https` URL. The encoding is selected by the fragment: a
    /// legacy `vN=<payload>` fragment, or the `v=1&key=…` form otherwise.
    pub fn parse(link: &str) -> Result<Self, Error> {
        let link = link.trim();
        if link.len() > MAX_LINK_LENGTH {
            return Err(Error::TooLong);
        }
        let (base, fragment) = link.split_once('#').ok_or(Error::NotAPaymentLink)?;
        check_host(base).map_err(|_| Error::NotAPaymentLink)?;
        if is_legacy_fragment(fragment) {
            parse_legacy(fragment)
        } else {
            parse_v1(fragment)
        }
    }

    /// Returns the encoding the link was read from.
    pub fn origin(&self) -> Origin {
        self.origin
    }

    /// Returns the network the payment is on.
    pub fn network(&self) -> NetworkType {
        self.network
    }

    /// Returns the height from which to scan for the payment's funds. It is never below
    /// [`min_birthday_height`] for the payment's network.
    pub fn birthday_height(&self) -> BlockHeight {
        self.birthday_height
    }

    /// Returns the amount the link claims the payment holds, if it states a valid one.
    pub fn amount(&self) -> Option<Zatoshis> {
        self.amount
    }

    /// Returns the link's description or message, if any.
    ///
    /// Text read from a link is sanitized: line and paragraph breaks and other control
    /// whitespace (tab, LF, VT, FF, CR, NEL, U+2028, U+2029) become a space, and the
    /// remaining control characters (Unicode `Cc`, i.e. C0, DEL and C1) and invisible
    /// format characters that can hide or reorder text are removed: ALM (U+061C), LRM and
    /// RLM (U+200E, U+200F), the bidi embeddings, overrides and isolates (U+202A to U+202E,
    /// U+2066 to U+2069), the deprecated format controls (U+206A to U+206F), zero width
    /// space (U+200B), word joiner and invisible operators (U+2060 to U+2064), the byte
    /// order mark (U+FEFF) and the interlinear annotation controls (U+FFF9 to U+FFFB). ZWJ
    /// and ZWNJ (U+200D, U+200C) and variation selectors are kept, as emoji and several
    /// scripts need them. A description that is blank after this is absent.
    pub fn description(&self) -> Option<&str> {
        self.description.as_deref()
    }

    /// Returns the 64-byte BIP 39 seed of the payment wallet, wiped when dropped.
    pub fn seed(&self) -> Result<Zeroizing<[u8; 64]>, Error> {
        // `Mnemonic` wipes its phrase and entropy when dropped.
        let mnemonic = match &self.secret {
            Secret::Entropy(entropy) => Mnemonic::<English>::from_entropy(entropy.to_vec()),
            Secret::Phrase(phrase) => {
                // Legacy phrases may carry repeated or unusual whitespace between words.
                let normalized =
                    Zeroizing::new(phrase.split_whitespace().collect::<Vec<_>>().join(" "));
                Mnemonic::<English>::from_phrase(normalized.as_str())
            }
        }
        .map_err(|_| Error::KeyDerivation)?;
        Ok(Zeroizing::new(mnemonic.to_seed("")))
    }

    /// Returns the spending key of the payment wallet, checking that it is on the network
    /// of `params`.
    pub fn spending_key<P: Parameters>(&self, params: &P) -> Result<UnifiedSpendingKey, Error> {
        if params.network_type() != self.network {
            return Err(Error::NetworkMismatch);
        }
        let seed = self.seed()?;
        UnifiedSpendingKey::from_seed(params, seed.as_slice(), AccountId::ZERO)
            .map_err(|_| Error::KeyDerivation)
    }

    /// Returns the Orchard-only address that a payment is funded at.
    pub fn funding_address<P: Parameters>(&self, params: &P) -> Result<String, Error> {
        let ufvk = self.spending_key(params)?.to_unified_full_viewing_key();
        let (address, _) = ufvk
            .default_address(UnifiedAddressRequest::ORCHARD)
            .map_err(|_| Error::KeyDerivation)?;
        Ok(address.encode(params))
    }

    /// Writes the payment as a `v=1` link on `host`, an `https` URL (such as
    /// `https://example.com/`) whose fragment will carry the payment.
    ///
    /// Only payments created with [`LiberatedPayment::new`] can be written. The returned
    /// link carries the payment's secret.
    pub fn to_link(&self, host: &str) -> Result<String, Error> {
        let host = check_host(host)?;
        // `https://example.com#…` is a valid URL, but browsers and link matchers normalise it
        // to `https://example.com/#…`; write the normalised form so every consumer sees one shape.
        let separator = if host[8..].contains('/') { "" } else { "/" };
        let entropy = match (&self.origin, &self.secret) {
            (Origin::V1, Secret::Entropy(entropy)) if entropy.len() == 32 => entropy,
            _ => return Err(Error::UnsupportedVersion),
        };
        let key = Zeroizing::new(
            bech32::encode::<Bech32m>(key_hrp(self.network), entropy)
                .map_err(|_| Error::InvalidField("key"))?,
        );
        let height = u32::from(self.birthday_height).to_string();
        let amount = self.amount.map(format_zec);
        let description = self.description.as_deref().map(percent_encode);
        let mut parts = vec![
            host,
            separator,
            "#v=",
            LINK_VERSION,
            "&key=",
            key.as_str(),
            "&height=",
            &height,
        ];
        if let Some(amount) = &amount {
            parts.extend(["&amount=", amount]);
        }
        if let Some(text) = &description {
            parts.extend(["&desc=", text]);
        }
        // `concat` allocates the exact length once, so no partial copy of the key is left
        // behind in a reallocated buffer.
        Ok(parts.concat())
    }
}

/// Checks that `host` is an `https` URL without a fragment, returning it trimmed.
// `url::Url` is not a librustzcash dependency; this check only needs the scheme and the
// absence of a fragment or whitespace.
pub fn check_host(host: &str) -> Result<&str, Error> {
    let host = host.trim();
    let rest = host
        .get(..8)
        .filter(|scheme| scheme.eq_ignore_ascii_case("https://"))
        .map(|_| &host[8..])
        .ok_or(Error::InvalidField("host"))?;
    if rest.is_empty()
        || rest.starts_with('/')
        || host.contains('#')
        || host.chars().any(char::is_whitespace)
    {
        return Err(Error::InvalidField("host"));
    }
    Ok(host)
}

// No upstream constants exist for these HRPs (checked `zcash_protocol::constants`).
fn key_hrp(network: NetworkType) -> Hrp {
    Hrp::parse_unchecked(match network {
        NetworkType::Main => KEY_HRP_MAIN,
        NetworkType::Test => KEY_HRP_TEST,
        NetworkType::Regtest => KEY_HRP_REGTEST,
    })
}

fn is_legacy_fragment(fragment: &str) -> bool {
    ["v1=", "v2=", "v3="]
        .iter()
        .any(|prefix| fragment.starts_with(prefix))
}

/// An informational field: its value, or `Repeated` once it has been seen twice.
#[derive(Clone, Copy)]
enum Info<'a> {
    Absent,
    Present(&'a str),
    Repeated,
}

impl<'a> Info<'a> {
    fn set(&mut self, value: &'a str) {
        *self = match self {
            Info::Absent => Info::Present(value),
            _ => Info::Repeated,
        };
    }

    fn value(self) -> Option<&'a str> {
        match self {
            Info::Present(value) => Some(value),
            _ => None,
        }
    }
}

fn parse_v1(fragment: &str) -> Result<LiberatedPayment, Error> {
    let mut version = None;
    let mut key = None;
    let mut height = None;
    let mut amount = Info::Absent;
    let mut description = Info::Absent;

    for pair in fragment.split('&') {
        // Empty pairs (`&&`, a leading or trailing `&`) carry nothing.
        if pair.is_empty() {
            continue;
        }
        let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
        let (slot, name) = match name {
            "v" => (&mut version, "v"),
            "key" => (&mut key, "key"),
            "height" => (&mut height, "height"),
            // Informational: a repeated value is ambiguous, so neither is used.
            "amount" => {
                amount.set(value);
                continue;
            }
            "desc" => {
                description.set(value);
                continue;
            }
            // Unknown parameters are ignored so that later versions can add optional ones.
            _ => continue,
        };
        if slot.replace(value).is_some() {
            return Err(Error::DuplicateField(name));
        }
    }

    if version.ok_or(Error::MissingField("v"))? != LINK_VERSION {
        return Err(Error::UnsupportedVersion);
    }

    let key = key.ok_or(Error::MissingField("key"))?;
    let (network, secret) = parse_key(key)?;
    let birthday_height = parse_height(network, height.ok_or(Error::MissingField("height"))?)?;
    let amount = amount.value().and_then(parse_zec);
    let description = description
        .value()
        .and_then(percent_decode)
        .filter(|text| text.len() <= MAX_DESCRIPTION_BYTES)
        .and_then(|text| sanitize_description(&text));

    Ok(LiberatedPayment {
        origin: Origin::V1,
        network,
        secret,
        birthday_height,
        amount,
        description,
    })
}

/// Decodes a Bech32m payment key into its network and 32 bytes of entropy.
fn parse_key(key: &str) -> Result<(NetworkType, Secret), Error> {
    let invalid = Error::InvalidField("key");
    // The same Bech32m entry point `zcash_address` uses. It accepts an all upper-case key
    // (the QR alphanumeric form) and rejects mixed case and Bech32 (non-m) checksums.
    let parsed = CheckedHrpstring::new::<Bech32m>(key).map_err(|_| invalid.clone())?;
    let network = match parsed.hrp().to_lowercase().as_str() {
        KEY_HRP_MAIN => NetworkType::Main,
        KEY_HRP_TEST => NetworkType::Test,
        KEY_HRP_REGTEST => NetworkType::Regtest,
        _ => return Err(Error::UnsupportedNetwork),
    };
    // Non-zero padding bits would give a second spelling of the same secret. The BIP 173
    // padding rule that bech32 implements for segwit applies to any 5-to-8-bit regrouping.
    parsed
        .validate_segwit_padding()
        .map_err(|_| invalid.clone())?;
    let bytes = parsed.byte_iter();
    if bytes.len() != 32 {
        return Err(invalid);
    }
    let mut entropy = Zeroizing::new(vec![0u8; 32]);
    for (out, byte) in entropy.iter_mut().zip(bytes) {
        *out = byte;
    }
    Ok((network, Secret::Entropy(entropy)))
}

/// Parses a canonical decimal height (no sign, no leading zeros) and checks it against
/// [`min_birthday_height`].
fn parse_height(network: NetworkType, text: &str) -> Result<BlockHeight, Error> {
    if text.is_empty() || text.starts_with('0') || !text.bytes().all(|b| b.is_ascii_digit()) {
        return Err(Error::InvalidField("height"));
    }
    let height = text
        .parse::<u32>()
        .map_err(|_| Error::InvalidField("height"))?;
    check_birthday(network, height)
}

fn check_birthday(network: NetworkType, height: u32) -> Result<BlockHeight, Error> {
    let height = BlockHeight::from_u32(height);
    if height < min_birthday_height(network) {
        return Err(Error::InvalidField("height"));
    }
    Ok(height)
}

/// Removes the characters listed at [`LiberatedPayment::description`], returning `None` if
/// nothing but whitespace is left.
fn sanitize_description(text: &str) -> Option<String> {
    let clean = text
        .chars()
        .filter_map(|c| match c {
            '\t' | '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}' => {
                Some(' ')
            }
            '\u{061C}'
            | '\u{200B}'
            | '\u{200E}'
            | '\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{2064}'
            | '\u{2066}'..='\u{206F}'
            | '\u{FEFF}'
            | '\u{FFF9}'..='\u{FFFB}' => None,
            c if c.is_control() => None,
            c => Some(c),
        })
        .collect::<String>();
    (!clean.trim().is_empty()).then_some(clean)
}

/// Parses a decimal ZEC amount with at most eight fractional digits, returning `None` for
/// zero or anything malformed or above `MAX_MONEY`.
// The same grammar as `zip321`'s amount parser, which is private (checked zip321 0.9);
// `zcash_protocol` has no decimal-ZEC parser.
fn parse_zec(text: &str) -> Option<Zatoshis> {
    let (whole, fraction) = text.split_once('.').unwrap_or((text, ""));
    let digits = |s: &str| s.bytes().all(|b| b.is_ascii_digit());
    if whole.is_empty()
        || !digits(whole)
        || !digits(fraction)
        || fraction.len() > 8
        || (text.contains('.') && fraction.is_empty())
    {
        return None;
    }
    let whole: u64 = whole.parse().ok()?;
    let fraction: u64 = format!("{fraction:0<8}").parse().ok()?;
    whole
        .checked_mul(COIN)
        .and_then(|z| z.checked_add(fraction))
        .and_then(|z| Zatoshis::from_u64(z).ok())
        .filter(|z| !z.is_zero())
}

// The same output as `zip321`'s amount renderer, which is private (checked zip321 0.9).
fn format_zec(amount: Zatoshis) -> String {
    let zat = amount.into_u64();
    let fraction = format!("{:08}", zat % COIN);
    let fraction = fraction.trim_end_matches('0');
    if fraction.is_empty() {
        format!("{}", zat / COIN)
    } else {
        format!("{}.{fraction}", zat / COIN)
    }
}

fn percent_encode(text: &str) -> String {
    utf8_percent_encode(text, DESCRIPTION_ENCODE_SET).to_string()
}

/// Decodes a form-encoded value (`+` is a space), returning `None` unless every `%` starts
/// a two-hex-digit escape and the result is UTF-8.
fn percent_decode(text: &str) -> Option<String> {
    // `percent_decode_str` passes malformed escapes (`%ZZ`, `%4`, `%+F`) through literally;
    // reject them instead of guessing.
    let bytes = text.as_bytes();
    let well_formed = bytes
        .iter()
        .enumerate()
        .filter(|(_, b)| **b == b'%')
        .all(|(i, _)| {
            bytes
                .get(i + 1..i + 3)
                .is_some_and(|hex| hex.iter().all(u8::is_ascii_hexdigit))
        });
    if !well_formed {
        return None;
    }
    let text = text.replace('+', " ");
    percent_decode_str(&text)
        .decode_utf8()
        .ok()
        .map(|text| text.into_owned())
}

/// Decodes base64url as the legacy encoding writes it: unpadded, or with exactly the
/// canonical padding. Non-zero trailing bits are rejected. The output is wiped on drop.
fn base64url_decode(text: &str) -> Option<Zeroizing<Vec<u8>>> {
    let engine = if text.ends_with('=') {
        &URL_SAFE
    } else {
        &URL_SAFE_NO_PAD
    };
    // Decode into a buffer this module owns, so a failed decode is wiped as well.
    let mut out = Zeroizing::new(vec![0u8; base64::decoded_len_estimate(text.len())]);
    let len = engine.decode_slice(text, &mut out[..]).ok()?;
    out.truncate(len);
    Some(out)
}

fn parse_legacy(fragment: &str) -> Result<LiberatedPayment, Error> {
    let (origin, payload) = if let Some(p) = fragment.strip_prefix("v3=") {
        (Origin::LegacyV3, p)
    } else if let Some(p) = fragment.strip_prefix("v2=") {
        (Origin::LegacyV2, p)
    } else if let Some(p) = fragment.strip_prefix("v1=") {
        (Origin::LegacyV1, p)
    } else {
        return Err(Error::UnsupportedVersion);
    };
    if payload.is_empty() || payload.contains('&') {
        return Err(Error::InvalidField("payload"));
    }
    let bytes = base64url_decode(payload).ok_or(Error::InvalidField("payload"))?;
    let json = serde_json::from_slice::<serde_json::Value>(&bytes)
        .map_err(|_| Error::InvalidField("payload"))?;
    drop(bytes);
    match origin {
        Origin::LegacyV3 => parse_legacy_v3(json),
        _ => parse_legacy_object(origin, json),
    }
}

fn legacy_network(value: Option<&serde_json::Value>) -> Result<NetworkType, Error> {
    match value.and_then(|v| v.as_str()).map(str::trim) {
        Some("main") => Ok(NetworkType::Main),
        Some(_) => Err(Error::UnsupportedNetwork),
        None => Err(Error::MissingField("network")),
    }
}

fn legacy_u64(value: Option<&serde_json::Value>, name: &'static str) -> Result<u64, Error> {
    match value {
        Some(serde_json::Value::Number(n)) => n.as_u64().ok_or(Error::InvalidField(name)),
        Some(serde_json::Value::String(s)) => {
            let s = s.trim();
            if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
                return Err(Error::InvalidField(name));
            }
            s.parse().map_err(|_| Error::InvalidField(name))
        }
        Some(_) => Err(Error::InvalidField(name)),
        None => Err(Error::MissingField(name)),
    }
}

fn legacy_amount(value: Option<&serde_json::Value>) -> Result<Zatoshis, Error> {
    let zat = legacy_u64(value, "amount")?;
    Zatoshis::from_u64(zat)
        .ok()
        .filter(|z| !z.is_zero())
        .ok_or(Error::InvalidField("amount"))
}

fn legacy_height(
    network: NetworkType,
    value: Option<&serde_json::Value>,
) -> Result<BlockHeight, Error> {
    let height =
        u32::try_from(legacy_u64(value, "height")?).map_err(|_| Error::InvalidField("height"))?;
    check_birthday(network, height)
}

fn legacy_text(value: Option<&serde_json::Value>) -> Option<String> {
    value
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| s.len() <= MAX_DESCRIPTION_BYTES)
        .and_then(sanitize_description)
        .map(|s| s.trim().to_owned())
}

/// Moves a JSON string out of `value`, wiping it if it is not the expected shape.
fn take_secret_string(value: Option<&mut serde_json::Value>) -> Option<Zeroizing<String>> {
    match value.map(std::mem::take) {
        Some(serde_json::Value::String(text)) => Some(Zeroizing::new(text)),
        _ => None,
    }
}

fn parse_legacy_object(origin: Origin, json: serde_json::Value) -> Result<LiberatedPayment, Error> {
    let mut object = match json {
        serde_json::Value::Object(object) => object,
        _ => return Err(Error::InvalidField("payload")),
    };
    // Take the phrase out first so that it is wiped on every error path below.
    let phrase = match object.get_mut("mnemonic") {
        None => return Err(Error::MissingField("mnemonic")),
        value => take_secret_string(value).ok_or(Error::InvalidField("mnemonic"))?,
    };
    let expected = if origin == Origin::LegacyV1 { 1 } else { 2 };
    if object.get("v").and_then(|v| v.as_u64()) != Some(expected) {
        return Err(Error::UnsupportedVersion);
    }
    let network = legacy_network(object.get("network"))?;
    let amount = legacy_amount(object.get("amountZatoshi"))?;
    let birthday_height = legacy_height(network, object.get("birthdayHeight"))?;
    let description = object
        .get("presentation")
        .and_then(|p| legacy_text(p.get("message")));
    let payment = LiberatedPayment {
        origin,
        network,
        secret: Secret::Phrase(phrase),
        birthday_height,
        amount: Some(amount),
        description,
    };
    // Reject phrases that do not decode rather than failing later.
    payment.seed()?;
    Ok(payment)
}

fn parse_legacy_v3(json: serde_json::Value) -> Result<LiberatedPayment, Error> {
    let mut items = match json {
        serde_json::Value::Array(items) if (4..=8).contains(&items.len()) => items,
        _ => return Err(Error::InvalidField("payload")),
    };
    // Take the key out first so that it is wiped on every error path below.
    let encoded = take_secret_string(items.get_mut(1)).ok_or(Error::InvalidField("key"))?;
    let entropy = base64url_decode(&encoded).ok_or(Error::InvalidField("key"))?;
    drop(encoded);
    if !matches!(entropy.len(), 16 | 20 | 24 | 28 | 32) {
        return Err(Error::InvalidField("key"));
    }
    let network = legacy_network(items.first())?;
    let birthday_height = legacy_height(network, items.get(2))?;
    let amount = match items.get(3) {
        Some(serde_json::Value::String(_)) => legacy_amount(items.get(3))?,
        _ => return Err(Error::InvalidField("amount")),
    };
    let description = legacy_text(items.get(6));
    Ok(LiberatedPayment {
        origin: Origin::LegacyV3,
        network,
        secret: Secret::Entropy(entropy),
        birthday_height,
        amount: Some(amount),
        description,
    })
}

#[cfg(test)]
mod tests {
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use bech32::{
        Bech32,
        primitives::iter::{ByteIterExt, Fe32IterExt},
    };
    use zcash_protocol::consensus::{MAIN_NETWORK, TEST_NETWORK};

    use super::*;

    const HOST: &str = "https://example.com/";
    const LEGACY_LINK_BASE: &str = "https://legacy.example/payment-links/open";

    // A published, never-funded reference vector of the legacy `v3` encoding (32 zero
    // bytes of entropy).
    const LEGACY_V3: &str = "https://legacy.example/payment-links/open#v3=WyJtYWluIiwiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsMzQ4MzE0MSwiMTAwMDAwMCIsImtuaWdodE1hZ2ljIiwxMS4xNzQ3LCJJdCdzIGEgZ3JlYXQgZGF5IHRvIHNoaWVsZCB5b3VyIFpFQyDwn5uh77iPIl0";

    fn height(h: u32) -> BlockHeight {
        BlockHeight::from_u32(h)
    }

    fn nu5(network: NetworkType) -> u32 {
        u32::from(min_birthday_height(network))
    }

    /// A minimal mainnet `v=1` link: `(link, base, key parameter)`.
    fn main_link() -> (String, String, String) {
        let link =
            LiberatedPayment::new(NetworkType::Main, &[1; 32], height(3_500_000), None, None)
                .unwrap()
                .to_link(HOST)
                .unwrap();
        let (base, fragment) = link.split_once('#').unwrap();
        let key = fragment.split('&').nth(1).unwrap().to_owned();
        (link.clone(), base.to_owned(), key)
    }

    fn legacy_link(prefix: &str, json: &serde_json::Value) -> String {
        format!(
            "{LEGACY_LINK_BASE}#{prefix}={}",
            URL_SAFE_NO_PAD.encode(json.to_string())
        )
    }

    fn legacy_v2(birthday: u32, message: &str) -> serde_json::Value {
        serde_json::json!({
            "v": 2, "network": "main", "amountZatoshi": "2500000",
            "mnemonic": format!("{}  art", ["abandon"; 23].join(" ")),
            "birthdayHeight": birthday, "label": "Payment link",
            "presentation": {"message": message},
        })
    }

    #[test]
    fn v1_link_round_trip() {
        let secret = derive_payment_secret(&TEST_NETWORK, &[7; 32], 5).unwrap();
        let payment = LiberatedPayment::new(
            NetworkType::Test,
            &secret,
            height(4_000_000),
            Some(Zatoshis::from_u64(12_340_000).unwrap()),
            Some("Hi from Zcash!".into()),
        )
        .unwrap();
        let link = payment.to_link(HOST).unwrap();
        assert!(link.starts_with("https://example.com/#v=1&key=zgifttest1"));
        // A bare host is written with the `/` that browsers add; a path is left alone.
        let bare = payment.to_link("https://example.com").unwrap();
        assert!(bare.starts_with("https://example.com/#v=1&key=zgifttest1"));
        let with_path = payment.to_link("https://example.com/claim").unwrap();
        assert!(with_path.starts_with("https://example.com/claim#v=1&key=zgifttest1"));
        assert!(link.ends_with("&height=4000000&amount=0.1234&desc=Hi%20from%20Zcash%21"));

        let parsed = LiberatedPayment::parse(&link).unwrap();
        assert_eq!(parsed.origin(), Origin::V1);
        assert_eq!(parsed.network(), NetworkType::Test);
        assert_eq!(parsed.birthday_height(), height(4_000_000));
        assert_eq!(parsed.amount(), payment.amount());
        assert_eq!(parsed.description(), Some("Hi from Zcash!"));
        assert_eq!(*parsed.seed().unwrap(), *payment.seed().unwrap());
        assert_eq!(
            parsed.funding_address(&TEST_NETWORK).unwrap(),
            payment.funding_address(&TEST_NETWORK).unwrap()
        );
        assert_eq!(
            parsed.spending_key(&MAIN_NETWORK).unwrap_err(),
            Error::NetworkMismatch
        );
    }

    /// Links written before the move to upstream encoders, pinned byte for byte.
    #[test]
    fn link_encoding_is_unchanged() {
        let payment = LiberatedPayment::new(
            NetworkType::Main,
            &[0xA5; 32],
            height(3_500_000),
            Some(Zatoshis::from_u64(150_000_000).unwrap()),
            Some("Hi from Zcash! \u{1F6E1}\u{FE0F} 100% ~_.-+/".into()),
        )
        .unwrap();
        assert_eq!(
            payment.to_link("https://example.com").unwrap(),
            "https://example.com/#v=1&key=zgift15kj6tfd95kj6tfd95kj6tfd95kj6tfd95kj6tfd95kj6tfd95kjsuax7hg&height=3500000&amount=1.5&desc=Hi%20from%20Zcash%21%20%F0%9F%9B%A1%EF%B8%8F%20100%25%20~_.-%2B%2F"
        );

        let secret = derive_payment_secret(&TEST_NETWORK, &[7; 32], 5).unwrap();
        let payment = LiberatedPayment::new(
            NetworkType::Test,
            &secret,
            height(4_000_000),
            Some(Zatoshis::from_u64(12_340_000).unwrap()),
            Some("Hi from Zcash!".into()),
        )
        .unwrap();
        assert_eq!(
            payment.to_link(HOST).unwrap(),
            "https://example.com/#v=1&key=zgifttest1xzr6q9crzm5zzl6ge2m5ym4wc74ajl96hc6qqy0sh9xhwgvxjfrqlnz3au&height=4000000&amount=0.1234&desc=Hi%20from%20Zcash%21"
        );
        assert_eq!(
            payment.funding_address(&TEST_NETWORK).unwrap(),
            "utest1t2mdpt5zzhunczjk2cggyz8wt7hh09h9a3rmfmatcgntfmg5kyknca2k3d28val00rs93larmf6yp5ycxwqnrvl5h973efddjs88hggf"
        );
    }

    #[test]
    fn minimal_v1_link() {
        let payment =
            LiberatedPayment::new(NetworkType::Main, &[1; 32], height(3_500_000), None, None)
                .unwrap();
        let link = payment.to_link(HOST).unwrap();
        let parsed = LiberatedPayment::parse(&link).unwrap();
        assert_eq!(parsed.amount(), None);
        assert_eq!(parsed.description(), None);
        assert_eq!(parsed.network(), NetworkType::Main);
        // The host is not part of the payment: any `https` URL carries it.
        let moved = link.replacen(HOST, "HTTPS://Pay.Example.org/claim", 1);
        assert_eq!(
            *LiberatedPayment::parse(&moved).unwrap().seed().unwrap(),
            *payment.seed().unwrap()
        );
    }

    #[test]
    fn hosts_are_https_urls_without_a_fragment() {
        let payment =
            LiberatedPayment::new(NetworkType::Main, &[1; 32], height(3_500_000), None, None)
                .unwrap();
        for host in ["https://example.com", " https://example.com/pay?x=1 "] {
            assert_eq!(check_host(host).unwrap(), host.trim());
            assert!(payment.to_link(host).unwrap().starts_with(host.trim()));
        }
        for host in [
            "http://example.com/",
            "https://",
            "https:/",
            "https:///path",
            "https://example.com/#v=1",
            "https://exa mple.com/",
            "example.com",
        ] {
            assert_eq!(
                payment.to_link(host).unwrap_err(),
                Error::InvalidField("host"),
                "{host}"
            );
        }
    }

    #[test]
    fn rejects_malformed_v1_links() {
        let (link, base, key) = main_link();
        let fragment = link.split_once('#').unwrap().1;
        let cases = [
            (
                format!("{base}#v=2&{key}&height=3500000"),
                Error::UnsupportedVersion,
            ),
            (
                format!("{base}#{key}&height=3500000"),
                Error::MissingField("v"),
            ),
            (
                format!("{base}#v&{key}&height=3500000"),
                Error::UnsupportedVersion,
            ),
            (
                format!("{base}#v=1&height=3500000"),
                Error::MissingField("key"),
            ),
            (format!("{base}#v=1&{key}"), Error::MissingField("height")),
            (
                format!("{base}#v=1&{key}&height=0"),
                Error::InvalidField("height"),
            ),
            (
                format!("{base}#v=1&{key}&height=03500000"),
                Error::InvalidField("height"),
            ),
            (
                format!("{base}#v=1&{key}&height=+3500000"),
                Error::InvalidField("height"),
            ),
            (
                format!("{base}#v=1&{key}&height=4294967296"),
                Error::InvalidField("height"),
            ),
            (
                format!("{base}#v=1&{key}&height=3500000&height=3500001"),
                Error::DuplicateField("height"),
            ),
            (
                format!("{base}#v=1&{key}&{key}&height=3500000"),
                Error::DuplicateField("key"),
            ),
            (
                format!("{base}#v=1&{key}x&height=3500000"),
                Error::InvalidField("key"),
            ),
            (
                format!("{base}#v=1&key&height=3500000"),
                Error::InvalidField("key"),
            ),
            (
                format!("http://example.com/#{fragment}"),
                Error::NotAPaymentLink,
            ),
            (fragment.to_string(), Error::NotAPaymentLink),
            (base.to_string(), Error::NotAPaymentLink),
            (
                format!("{link}&desc={}", "a".repeat(MAX_LINK_LENGTH)),
                Error::TooLong,
            ),
        ];
        for (text, error) in cases {
            assert_eq!(LiberatedPayment::parse(&text).unwrap_err(), error, "{text}");
        }
    }

    #[test]
    fn empty_and_unknown_parameters_are_ignored() {
        let (link, base, key) = main_link();
        for text in [
            format!("{link}&future=1"),
            format!("{link}&flag"),
            format!("{link}&"),
            format!("{link}&&"),
            format!("{base}#&v=1&&{key}&height=3500000&"),
        ] {
            let payment = LiberatedPayment::parse(&text).unwrap();
            assert_eq!(payment.birthday_height(), height(3_500_000), "{text}");
        }
    }

    #[test]
    fn keys_are_case_insensitive_but_not_mixed() {
        for network in [NetworkType::Main, NetworkType::Test, NetworkType::Regtest] {
            let payment =
                LiberatedPayment::new(network, &[9; 32], min_birthday_height(network), None, None)
                    .unwrap();
            let link = payment.to_link(HOST).unwrap();
            let key = link
                .split("key=")
                .nth(1)
                .unwrap()
                .split('&')
                .next()
                .unwrap();
            let upper = link.replace(key, &key.to_ascii_uppercase());
            let parsed = LiberatedPayment::parse(&upper).unwrap();
            assert_eq!(parsed.network(), network);
            assert_eq!(*parsed.seed().unwrap(), *payment.seed().unwrap());

            // An upper-case HRP with a lower-case body is mixed case.
            let (hrp, body) = key.split_once('1').unwrap();
            let mixed = link.replace(key, &format!("{}1{body}", hrp.to_ascii_uppercase()));
            assert_eq!(
                LiberatedPayment::parse(&mixed).unwrap_err(),
                Error::InvalidField("key")
            );
        }
    }

    #[test]
    fn keys_must_be_canonical_bech32m_of_32_bytes() {
        let (_, base, _) = main_link();
        let hrp = Hrp::parse_unchecked(KEY_HRP_MAIN);
        let parse =
            |key: String| LiberatedPayment::parse(&format!("{base}#v=1&key={key}&height=3500000"));

        // Bech32 (not Bech32m).
        let bech32 = bech32::encode::<Bech32>(hrp, &[1; 32]).unwrap();
        assert_eq!(parse(bech32).unwrap_err(), Error::InvalidField("key"));

        // Non-zero padding bits spell the same 32 bytes a second way.
        let mut fes = [1u8; 32].iter().copied().bytes_to_fes().collect::<Vec<_>>();
        let last = fes.len() - 1;
        fes[last] = bech32::Fe32::try_from(fes[last].to_u8() | 1).unwrap();
        let padded = fes
            .into_iter()
            .with_checksum::<Bech32m>(&hrp)
            .chars()
            .collect::<String>();
        assert_eq!(parse(padded).unwrap_err(), Error::InvalidField("key"));

        // Wrong lengths.
        for len in [0, 16, 31, 33] {
            let key = bech32::encode::<Bech32m>(hrp, &vec![1; len]).unwrap();
            assert_eq!(parse(key).unwrap_err(), Error::InvalidField("key"), "{len}");
        }

        // Unknown HRP.
        let other = bech32::encode::<Bech32m>(Hrp::parse_unchecked("zother"), &[1; 32]).unwrap();
        assert_eq!(parse(other).unwrap_err(), Error::UnsupportedNetwork);
    }

    #[test]
    fn birthday_height_floor_is_nu5() {
        assert_eq!(nu5(NetworkType::Main), 1_687_104);
        assert_eq!(nu5(NetworkType::Test), 1_842_420);
        assert_eq!(nu5(NetworkType::Regtest), 1);

        for network in [NetworkType::Main, NetworkType::Test, NetworkType::Regtest] {
            let floor = nu5(network);
            assert_eq!(
                LiberatedPayment::new(network, &[2; 32], height(floor - 1), None, None)
                    .unwrap_err(),
                Error::InvalidField("height")
            );
            let link = LiberatedPayment::new(network, &[2; 32], height(floor), None, None)
                .unwrap()
                .to_link(HOST)
                .unwrap();
            assert_eq!(
                LiberatedPayment::parse(&link).unwrap().birthday_height(),
                height(floor)
            );
            let below = link.replace(&format!("height={floor}"), &format!("height={}", floor - 1));
            assert_eq!(
                LiberatedPayment::parse(&below).unwrap_err(),
                Error::InvalidField("height"),
                "{network:?}"
            );
            let top = link.replace(&format!("height={floor}"), "height=4294967295");
            assert!(LiberatedPayment::parse(&top).is_ok());
        }

        // Legacy links use the same floor.
        let floor = nu5(NetworkType::Main);
        assert_eq!(
            LiberatedPayment::parse(&legacy_link("v2", &legacy_v2(floor - 1, "gm"))).unwrap_err(),
            Error::InvalidField("height")
        );
        assert!(LiberatedPayment::parse(&legacy_link("v2", &legacy_v2(floor, "gm"))).is_ok());
    }

    #[test]
    fn bad_informational_fields_are_absent() {
        let (link, ..) = main_link();
        let parse = |extra: &str| LiberatedPayment::parse(&format!("{link}{extra}")).unwrap();
        for extra in [
            "&amount=0",
            "&amount=abc",
            "&amount=",
            "&amount=1.",
            "&amount=.5",
            "&amount=-1",
            "&amount=0.123456789",
            "&amount=21000001",
            "&amount=1&amount=1",
        ] {
            assert_eq!(parse(extra).amount(), None, "{extra}");
        }
        assert_eq!(
            parse("&amount=21000000").amount(),
            Some(Zatoshis::from_u64(21_000_000 * COIN).unwrap())
        );
        assert_eq!(
            parse("&amount=0.00000001").amount(),
            Some(Zatoshis::from_u64(1).unwrap())
        );

        for extra in [
            "&desc=%+F",
            "&desc=hi%ZZ",
            "&desc=hi%4",
            "&desc=100%",
            "&desc=%FF",
            "&desc=",
            "&desc=%20%20",
            "&desc=a&desc=b",
        ] {
            assert_eq!(parse(extra).description(), None, "{extra}");
        }
        assert_eq!(parse("&desc=100%25+sure").description(), Some("100% sure"));
        let max = "a".repeat(MAX_DESCRIPTION_BYTES);
        assert_eq!(
            parse(&format!("&desc={max}")).description(),
            Some(max.as_str())
        );
        assert_eq!(
            parse(&format!("&desc={max}a")).description(),
            None,
            "513 bytes"
        );
    }

    #[test]
    fn descriptions_are_sanitized() {
        let (link, ..) = main_link();
        let parse = |extra: &str| LiberatedPayment::parse(&format!("{link}{extra}")).unwrap();
        assert_eq!(
            parse("&desc=a%E2%80%AEb%0Ac%07d%00e%C2%85f%E2%81%A6g").description(),
            Some("ab cde fg")
        );
        // Raw (unencoded) bidi controls are stripped too.
        assert_eq!(
            parse("&desc=Gift\u{202E}moc.liame\u{200F}").description(),
            Some("Giftmoc.liame")
        );
        assert_eq!(parse("&desc=%E2%80%8F%00%7F").description(), None);
        // Emoji sequences keep their joiners and variation selectors.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{1F6E1}\u{FE0F}";
        assert_eq!(
            parse(&format!("&desc={}", percent_encode(family))).description(),
            Some(family)
        );

        // Legacy messages are sanitized as well.
        let payment =
            LiberatedPayment::parse(&legacy_link("v2", &legacy_v2(3_400_000, " g\u{202E}m\n ")))
                .unwrap();
        assert_eq!(payment.description(), Some("gm"));
        let payment =
            LiberatedPayment::parse(&legacy_link("v2", &legacy_v2(3_400_000, "\u{200E}"))).unwrap();
        assert_eq!(payment.description(), None);

        // Minting refuses text that reading would change.
        for text in ["a\u{202E}b", "line\nbreak", "", "  ", &"a".repeat(513)] {
            assert_eq!(
                LiberatedPayment::new(
                    NetworkType::Main,
                    &[1; 32],
                    height(3_500_000),
                    None,
                    Some(text.to_owned())
                )
                .unwrap_err(),
                Error::InvalidField("desc"),
                "{text:?}"
            );
        }
    }

    #[test]
    fn round_trips_generated_payments() {
        // A fixed xorshift stream keeps the test deterministic.
        let mut state = 0x2545_f491_4f6c_dd1du64;
        let mut next = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        let alphabet: Vec<char> = "aZ09 -._~+%&=#?/é€🛡\u{FE0F}\u{200D}".chars().collect();
        for _ in 0..200 {
            let network =
                [NetworkType::Main, NetworkType::Test, NetworkType::Regtest][(next() % 3) as usize];
            let mut secret = [0u8; 32];
            secret.iter_mut().for_each(|b| *b = next() as u8);
            let birthday = nu5(network) + (next() % 3_000_000) as u32;
            let amount = (next() % 2 == 0)
                .then(|| Zatoshis::from_u64(1 + next() % (21_000_000 * COIN)).unwrap());
            let description = (next() % 2 == 0)
                .then(|| {
                    (0..1 + next() % 40)
                        .map(|_| alphabet[(next() % alphabet.len() as u64) as usize])
                        .collect::<String>()
                })
                .filter(|text| !text.trim().is_empty());
            let payment = LiberatedPayment::new(
                network,
                &secret,
                height(birthday),
                amount,
                description.clone(),
            )
            .unwrap();
            let parsed = LiberatedPayment::parse(&payment.to_link(HOST).unwrap()).unwrap();
            assert_eq!(parsed.network(), network);
            assert_eq!(parsed.birthday_height(), height(birthday));
            assert_eq!(parsed.amount(), amount);
            assert_eq!(parsed.description(), description.as_deref());
            assert_eq!(*parsed.seed().unwrap(), *payment.seed().unwrap());
        }
    }

    #[test]
    fn derivation_is_per_index_and_network() {
        let seed = [3u8; 32];
        let a = derive_payment_secret(&MAIN_NETWORK, &seed, 0).unwrap();
        let b = derive_payment_secret(&MAIN_NETWORK, &seed, 1).unwrap();
        let c = derive_payment_secret(&TEST_NETWORK, &seed, 0).unwrap();
        assert_ne!(*a, *b);
        assert_ne!(*a, *c);
        assert_eq!(*a, *derive_payment_secret(&MAIN_NETWORK, &seed, 0).unwrap());
        assert!(derive_payment_secret(&MAIN_NETWORK, &seed, 1 << 31).is_err());
    }

    /// Pins the registered-derivation context string: a change to it changes every
    /// payment secret, so this vector must only move together with the ZIP.
    #[test]
    fn derivation_vector() {
        let seed = [0u8; 32];
        assert_eq!(
            hex::encode(*derive_payment_secret(&MAIN_NETWORK, &seed, 0).unwrap()),
            "e3d460242ab6029c0665a900cc8622665ed37e8cd10ae5cf6d2a67be86690792"
        );
        assert_eq!(
            hex::encode(*derive_payment_secret(&TEST_NETWORK, &seed, 1).unwrap()),
            "5c7eeb4332d0d1797b0f25ed998d00779ea692cec9db8741ba20f9c7b383a21a"
        );
    }

    /// The BIP 39 English test vector (passphrase `TREZOR`) and the mainnet Orchard-only
    /// address that the derivation expected by other implementations of the legacy encoding
    /// yields for it. Legacy payments are claimed through `spending_key`/`funding_address`,
    /// so these must agree on the derivation path (ZIP 32 account 0, Orchard receiver at
    /// the default diversifier).
    #[test]
    fn orchard_derivation_matches_legacy_bip39_vector() {
        const PHRASE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        const LEGACY_UA: &str = "u16yrmgarlnpx3ktaxq4l8mmc8wwnw3nmml02nujwghr2enf3jggmfjqax44yqts3csnxrtq8pyshk9ryew2zlrp3x5lyc64usqsnwnu0v";
        let seed = Mnemonic::<English>::from_phrase(PHRASE)
            .unwrap()
            .to_seed("TREZOR");
        let ufvk = UnifiedSpendingKey::from_seed(&MAIN_NETWORK, &seed, AccountId::ZERO)
            .unwrap()
            .to_unified_full_viewing_key();
        let (address, _) = ufvk
            .default_address(UnifiedAddressRequest::ORCHARD)
            .unwrap();
        assert_eq!(address.encode(&MAIN_NETWORK), LEGACY_UA);
    }

    #[test]
    fn reads_legacy_v3() {
        let payment = LiberatedPayment::parse(LEGACY_V3).unwrap();
        assert_eq!(payment.origin(), Origin::LegacyV3);
        assert_eq!(payment.network(), NetworkType::Main);
        assert_eq!(payment.birthday_height(), height(3_483_141));
        assert_eq!(
            payment.amount(),
            Some(Zatoshis::from_u64(1_000_000).unwrap())
        );
        assert_eq!(
            payment.description(),
            Some("It's a great day to shield your ZEC 🛡️")
        );
        // 32 zero bytes of entropy is "abandon" x23 + "art".
        let phrase = format!("{} art", ["abandon"; 23].join(" "));
        let expected = Mnemonic::<English>::from_phrase(phrase.as_str())
            .unwrap()
            .to_seed("");
        assert_eq!(*payment.seed().unwrap(), expected);
        assert!(payment.to_link(HOST).is_err());
    }

    #[test]
    fn legacy_padding_is_absent_or_canonical() {
        // Messages of three lengths give payloads needing 0, 1 and 2 padding characters.
        let mut seen = [false; 3];
        for message in ["gm", "gm!", "gm!!"] {
            let link = legacy_link("v2", &legacy_v2(3_400_000, message));
            let canonical = (4 - (link.len() - link.find("v2=").unwrap() - 3) % 4) % 4;
            seen[canonical.min(2)] = true;
            for padding in 0..=5 {
                let padded = format!("{link}{}", "=".repeat(padding));
                let ok = padding == 0 || padding == canonical;
                assert_eq!(
                    LiberatedPayment::parse(&padded).is_ok(),
                    ok,
                    "{message} with {padding} `=`"
                );
            }
        }
        assert_eq!(seen, [true; 3]);

        // Non-zero trailing bits are another spelling of the same payload.
        let link = legacy_link("v2", &legacy_v2(3_400_000, "gm!"));
        let last = link.chars().last().unwrap();
        let mut tweaked = link.clone();
        tweaked.pop();
        tweaked.push(if last == 'A' { 'B' } else { 'A' });
        assert!(LiberatedPayment::parse(&tweaked).is_err());

        // Characters outside the URL-safe alphabet (standard base64's `+` and `/`) are refused.
        for c in ['+', '/'] {
            let link = link.replacen("#v2=", &format!("#v2={c}{c}{c}{c}"), 1);
            assert!(LiberatedPayment::parse(&link).is_err());
        }
    }

    #[test]
    fn reads_legacy_v2_and_v1() {
        let v2 = legacy_v2(3_400_000, "gm");
        let payment = LiberatedPayment::parse(&legacy_link("v2", &v2)).unwrap();
        assert_eq!(payment.origin(), Origin::LegacyV2);
        assert_eq!(
            payment.amount(),
            Some(Zatoshis::from_u64(2_500_000).unwrap())
        );
        assert_eq!(payment.birthday_height(), height(3_400_000));
        assert_eq!(payment.description(), Some("gm"));
        assert_eq!(
            *payment.seed().unwrap(),
            *LiberatedPayment::parse(LEGACY_V3).unwrap().seed().unwrap()
        );

        let phrase = format!("{}  art", ["abandon"; 23].join(" "));
        let v1 = serde_json::json!({
            "v": 1, "network": "main", "amountZatoshi": 1, "mnemonic": phrase,
            "birthdayHeight": "3400000", "label": "", "address": "u1x", "createdAt": "2026-01-01T00:00:00Z",
        });
        let payment = LiberatedPayment::parse(&legacy_link("v1", &v1)).unwrap();
        assert_eq!(payment.origin(), Origin::LegacyV1);

        // A version tag that does not match the fragment prefix is refused.
        assert_eq!(
            LiberatedPayment::parse(&legacy_link("v1", &v2)).unwrap_err(),
            Error::UnsupportedVersion
        );

        // Test-network legacy links are refused.
        let mut testnet = v2.clone();
        testnet["network"] = "test".into();
        assert_eq!(
            LiberatedPayment::parse(&legacy_link("v2", &testnet)).unwrap_err(),
            Error::UnsupportedNetwork
        );

        // A missing or malformed phrase is refused.
        let mut missing = v2.clone();
        missing.as_object_mut().unwrap().remove("mnemonic");
        assert_eq!(
            LiberatedPayment::parse(&legacy_link("v2", &missing)).unwrap_err(),
            Error::MissingField("mnemonic")
        );
        let mut wrong = v2.clone();
        wrong["mnemonic"] = 5.into();
        assert_eq!(
            LiberatedPayment::parse(&legacy_link("v2", &wrong)).unwrap_err(),
            Error::InvalidField("mnemonic")
        );
        wrong["mnemonic"] = "abandon abandon".into();
        assert_eq!(
            LiberatedPayment::parse(&legacy_link("v2", &wrong)).unwrap_err(),
            Error::KeyDerivation
        );
    }

    #[test]
    fn claim_fee_reserve_is_the_zip317_minimum_fee() {
        assert_eq!(CLAIM_FEE_RESERVE.into_u64(), 10_000);
    }

    #[test]
    fn origin_names_are_stable() {
        assert_eq!(Origin::V1.as_str(), "v1");
        assert_eq!(Origin::LegacyV1.as_str(), "legacy-v1");
        assert_eq!(Origin::LegacyV2.as_str(), "legacy-v2");
        assert_eq!(Origin::LegacyV3.as_str(), "legacy-v3");
    }

    #[test]
    fn debug_output_redacts_the_secret() {
        let payment = LiberatedPayment::parse(LEGACY_V3).unwrap();
        let debug = format!("{payment:?}");
        assert!(debug.contains("<redacted>"));
        assert!(!debug.contains("AAAA"));
    }
}
