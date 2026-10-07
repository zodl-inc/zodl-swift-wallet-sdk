//! The C surface for reading gift card links (see [`crate::liberated_payment`]).
//!
//! A gift card is a liberated payment (ZIP 324) as the SDK presents it to apps. Parsing is
//! stateless: it touches no database and no network. A link carries a spending secret, so no
//! error reported from here ever includes any part of the input.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use ffi_helpers::panic::catch_panic;
use secrecy::zeroize::Zeroize;
use zcash_protocol::consensus::{MAIN_NETWORK, NetworkType, TEST_NETWORK};

use crate::liberated_payment::{self, LiberatedPayment, Origin};
use crate::{NETWORK_ID_MAINNET, NETWORK_ID_TESTNET, unwrap_exc_or_null};

/// The encoding a gift card link was read from.
///
/// cbindgen:prefix-with-name
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GiftCardOrigin {
    /// A `v=1` link: `https://<host>#v=1&key=…&height=…`.
    V1,
    /// A legacy `v1=` JSON payload at `/payment-links/open#v1=`.
    LegacyV1,
    /// A legacy `v2=` JSON payload at `/payment-links/open#v2=`.
    LegacyV2,
    /// A legacy `v3=` JSON payload at `/payment-links/open#v3=`.
    LegacyV3,
}

impl From<Origin> for GiftCardOrigin {
    fn from(origin: Origin) -> Self {
        match origin {
            Origin::V1 => GiftCardOrigin::V1,
            Origin::LegacyV1 => GiftCardOrigin::LegacyV1,
            Origin::LegacyV2 => GiftCardOrigin::LegacyV2,
            Origin::LegacyV3 => GiftCardOrigin::LegacyV3,
        }
    }
}

/// Why [`zcashlc_parse_gift_card_link`] could not read a gift card link.
///
/// The values are stable, so callers can tell the cases apart without reading the error
/// message, which is meant for humans and may change.
///
/// cbindgen:prefix-with-name
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GiftCardLinkError {
    /// The text is not a gift card link of any kind this code reads.
    NotAGiftLink,
    /// The text is a gift card link of a version this code does not read.
    UnsupportedVersion,
    /// The card is for a network the SDK cannot redeem on (regtest, or an unknown one).
    WrongNetwork,
    /// The link's birthday height is malformed or below the network's NU5 activation height.
    /// Cards hold Orchard funds only, which cannot exist before NU5.
    InvalidBirthday,
    /// The link is malformed in any other way: a missing, repeated or invalid field, a bad key,
    /// or text that is too long or not UTF-8.
    InvalidLink,
}

impl From<&liberated_payment::Error> for GiftCardLinkError {
    fn from(error: &liberated_payment::Error) -> Self {
        use liberated_payment::Error;
        match error {
            Error::NotAPaymentLink => GiftCardLinkError::NotAGiftLink,
            Error::UnsupportedVersion => GiftCardLinkError::UnsupportedVersion,
            Error::UnsupportedNetwork | Error::NetworkMismatch => GiftCardLinkError::WrongNetwork,
            Error::InvalidField("height") => GiftCardLinkError::InvalidBirthday,
            Error::MissingField(_)
            | Error::DuplicateField(_)
            | Error::InvalidField(_)
            | Error::TooLong
            | Error::KeyDerivation => GiftCardLinkError::InvalidLink,
        }
    }
}

/// A parse failure: the category reported through the out-parameter, and the message stored
/// as the last error. The message never includes any part of the link.
struct ParseFailure {
    kind: GiftCardLinkError,
    message: String,
}

impl ParseFailure {
    fn new(kind: GiftCardLinkError, message: impl Into<String>) -> Self {
        ParseFailure {
            kind,
            message: message.into(),
        }
    }
}

impl From<liberated_payment::Error> for ParseFailure {
    fn from(error: liberated_payment::Error) -> Self {
        ParseFailure::new((&error).into(), error.to_string())
    }
}

/// A gift card read from a link.
///
/// Obtain via [`zcashlc_parse_gift_card_link`] and free with [`zcashlc_free_gift_card`], which
/// also zeroes the seed.
///
/// # Safety
///
/// - `funding_address` is a non-null, null-terminated UTF-8 string.
/// - `description` is null when the link has no description, and otherwise a non-null,
///   null-terminated UTF-8 string.
#[repr(C)]
pub struct GiftCardLink {
    /// The encoding the link was read from.
    origin: GiftCardOrigin,
    /// The network the card is on, as a network id (`0` testnet, `1` mainnet).
    network_id: u32,
    /// The height from which to scan for the card's funds.
    birthday_height: u32,
    /// Whether the link states an amount.
    has_amount: bool,
    /// The amount, in zatoshis, that the link claims the card holds. Zero when `has_amount` is
    /// false. Informational only: the funds found on chain are authoritative.
    amount: u64,
    /// The link's description, or null.
    description: *mut c_char,
    /// The Orchard-only default address of the card wallet, which the card is funded at.
    funding_address: *mut c_char,
    /// The 64-byte BIP 39 seed of the card wallet (ZIP 32 account 0, empty passphrase).
    seed: [u8; 64],
}

/// Reads a gift card link of any supported kind.
///
/// Returns null on failure. The reason is then written to `error_out` (when it is non-null), and
/// a message for humans is available via `zcashlc_last_error_message`. Neither ever includes any
/// part of the link. Regtest cards are refused because the SDK does not support that network.
///
/// # Safety
///
/// - `link` must be non-null and must point to a null-terminated UTF-8 string.
/// - The memory referenced by `link` must not be mutated for the duration of the function call.
/// - `error_out` must be null or valid for a write of one [`GiftCardLinkError`].
/// - Call [`zcashlc_free_gift_card`] to free the returned pointer, which zeroes the seed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_parse_gift_card_link(
    link: *const c_char,
    error_out: *mut GiftCardLinkError,
) -> *mut GiftCardLink {
    let mut kind = GiftCardLinkError::InvalidLink;
    let res = catch_panic(std::panic::AssertUnwindSafe(|| {
        let link = unsafe { CStr::from_ptr(link) }.to_str();
        match parse(link) {
            Ok(card) => Ok(Box::into_raw(card)),
            Err(failure) => {
                kind = failure.kind;
                Err(anyhow::anyhow!(failure.message))
            }
        }
    }));
    let ptr = unwrap_exc_or_null(res);
    if ptr.is_null() && !error_out.is_null() {
        unsafe { error_out.write(kind) };
    }
    ptr
}

fn parse(link: Result<&str, std::str::Utf8Error>) -> Result<Box<GiftCardLink>, ParseFailure> {
    let link = link.map_err(|_| {
        ParseFailure::new(
            GiftCardLinkError::InvalidLink,
            "gift card link is not valid UTF-8",
        )
    })?;
    let card = LiberatedPayment::parse(link)?;

    let (network_id, funding_address) = match card.network() {
        NetworkType::Main => (NETWORK_ID_MAINNET, card.funding_address(&MAIN_NETWORK)?),
        NetworkType::Test => (NETWORK_ID_TESTNET, card.funding_address(&TEST_NETWORK)?),
        NetworkType::Regtest => {
            return Err(ParseFailure::new(
                GiftCardLinkError::WrongNetwork,
                "gift card link is for an unsupported network",
            ));
        }
    };
    let c_string = |text: String| {
        CString::new(text).map_err(|_| {
            ParseFailure::new(
                GiftCardLinkError::InvalidLink,
                "gift card link has an invalid `desc`",
            )
        })
    };
    // The module sanitizes the description (it never contains NUL or other control
    // characters), so it is passed through as is.
    let description = card
        .description()
        .map(|text| c_string(text.to_owned()))
        .transpose()?
        .map_or(std::ptr::null_mut(), CString::into_raw);
    let funding_address = match c_string(funding_address) {
        Ok(address) => address.into_raw(),
        Err(failure) => {
            if !description.is_null() {
                drop(unsafe { CString::from_raw(description) });
            }
            return Err(failure);
        }
    };
    let amount = card.amount();

    // The seed is written straight into the boxed struct, so the only copy outside the
    // module's own (wiped) buffer is the one `zcashlc_free_gift_card` zeroes.
    let mut out = Box::new(GiftCardLink {
        origin: card.origin().into(),
        network_id,
        birthday_height: u32::from(card.birthday_height()),
        has_amount: amount.is_some(),
        amount: amount.map_or(0, |a| a.into_u64()),
        description,
        funding_address,
        seed: [0; 64],
    });
    match card.seed() {
        Ok(seed) => out.seed.copy_from_slice(seed.as_slice()),
        Err(error) => {
            unsafe { zcashlc_free_gift_card(Box::into_raw(out)) };
            return Err(error.into());
        }
    }
    Ok(out)
}

/// Frees a [`GiftCardLink`] returned by [`zcashlc_parse_gift_card_link`], zeroing its seed.
///
/// # Safety
///
/// - `ptr` must be null or a pointer returned by [`zcashlc_parse_gift_card_link`] that has not
///   already been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_gift_card(ptr: *mut GiftCardLink) {
    if ptr.is_null() {
        return;
    }
    let mut card = unsafe { Box::from_raw(ptr) };
    card.seed.zeroize();
    if !card.description.is_null() {
        drop(unsafe { CString::from_raw(card.description) });
    }
    if !card.funding_address.is_null() {
        drop(unsafe { CString::from_raw(card.funding_address) });
    }
}

#[cfg(test)]
mod tests {
    use bip0039::{English, Mnemonic};
    use zcash_protocol::consensus::{BlockHeight, NetworkUpgrade, Parameters};

    use super::*;

    const HOST: &str = "https://gift.zodl.com/";

    // A published, never-funded reference vector of the legacy `v3` encoding (32 zero bytes of
    // entropy), as in `liberated_payment.rs`.
    const LEGACY_V3: &str = "https://legacy.example/payment-links/open#v3=WyJtYWluIiwiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsMzQ4MzE0MSwiMTAwMDAwMCIsImtuaWdodE1hZ2ljIiwxMS4xNzQ3LCJJdCdzIGEgZ3JlYXQgZGF5IHRvIHNoaWVsZCB5b3VyIFpFQyDwn5uh77iPIl0";

    fn parse_link(link: &str) -> Result<*mut GiftCardLink, (GiftCardLinkError, String)> {
        let link = CString::new(link).unwrap();
        // A value no parse failure reports, so that a missing write would show.
        let mut kind = GiftCardLinkError::NotAGiftLink;
        let ptr = unsafe { zcashlc_parse_gift_card_link(link.as_ptr(), &mut kind) };
        if ptr.is_null() {
            let message = ffi_helpers::error_handling::take_last_error()
                .map(|e| format!("{e:#}"))
                .unwrap_or_default();
            Err((kind, message))
        } else {
            Ok(ptr)
        }
    }

    fn string(ptr: *mut c_char) -> Option<String> {
        (!ptr.is_null()).then(|| unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned())
    }

    fn v1_link(network: NetworkType, height: u32) -> String {
        LiberatedPayment::new(network, &[9; 32], BlockHeight::from_u32(height), None, None)
            .unwrap()
            .to_link(HOST)
            .unwrap()
    }

    fn key_of(link: &str) -> String {
        link.split('&')
            .find_map(|pair| pair.strip_prefix("key="))
            .unwrap()
            .to_owned()
    }

    #[test]
    fn parses_the_legacy_v3_vector() {
        let ptr = parse_link(LEGACY_V3).unwrap();
        let card = unsafe { &*ptr };
        assert_eq!(card.origin, GiftCardOrigin::LegacyV3);
        assert_eq!(card.network_id, NETWORK_ID_MAINNET);
        assert_eq!(card.birthday_height, 3_483_141);
        assert!(card.has_amount);
        assert_eq!(card.amount, 1_000_000);
        assert_eq!(
            string(card.description).as_deref(),
            Some("It's a great day to shield your ZEC 🛡️")
        );
        let phrase = format!("{} art", ["abandon"; 23].join(" "));
        let expected = Mnemonic::<English>::from_phrase(phrase.as_str())
            .unwrap()
            .to_seed("");
        assert_eq!(card.seed, expected);
        let address = string(card.funding_address).unwrap();
        assert!(address.starts_with("u1"));
        assert_eq!(
            address,
            LiberatedPayment::parse(LEGACY_V3)
                .unwrap()
                .funding_address(&MAIN_NETWORK)
                .unwrap()
        );
        unsafe { zcashlc_free_gift_card(ptr) };
    }

    #[test]
    fn parses_a_v1_testnet_link() {
        let card = LiberatedPayment::new(
            NetworkType::Test,
            &[9; 32],
            BlockHeight::from_u32(3_000_000),
            None,
            None,
        )
        .unwrap();
        let ptr = parse_link(&card.to_link(HOST).unwrap()).unwrap();
        let parsed = unsafe { &*ptr };
        assert_eq!(parsed.origin, GiftCardOrigin::V1);
        assert_eq!(parsed.network_id, NETWORK_ID_TESTNET);
        assert_eq!(parsed.birthday_height, 3_000_000);
        assert!(!parsed.has_amount);
        assert_eq!(parsed.amount, 0);
        assert!(parsed.description.is_null());
        assert_eq!(parsed.seed, *card.seed().unwrap());
        assert!(
            string(parsed.funding_address)
                .unwrap()
                .starts_with("utest1")
        );
        unsafe { zcashlc_free_gift_card(ptr) };
    }

    #[test]
    fn the_description_is_the_sanitized_one() {
        let base = v1_link(NetworkType::Test, 3_000_000);
        // Bidi override, line feed, BEL and NUL, percent-encoded as a link would carry them.
        let ptr = parse_link(&format!("{base}&desc=a%E2%80%AEb%0Ac%07d%00e")).unwrap();
        let card = unsafe { &*ptr };
        assert_eq!(string(card.description).as_deref(), Some("ab cde"));
        unsafe { zcashlc_free_gift_card(ptr) };
    }

    #[test]
    fn birthdays_below_nu5_are_refused_with_their_own_code() {
        for (network, params_nu5) in [
            (
                NetworkType::Main,
                MAIN_NETWORK.activation_height(NetworkUpgrade::Nu5).unwrap(),
            ),
            (
                NetworkType::Test,
                TEST_NETWORK.activation_height(NetworkUpgrade::Nu5).unwrap(),
            ),
        ] {
            let nu5 = u32::from(params_nu5);
            let key = key_of(&v1_link(network, nu5));
            let link = |height: &str| format!("{HOST}#v=1&key={key}&height={height}");

            for height in ["1", "419199", &(nu5 - 1).to_string(), "0", "-5", "abc"] {
                let (kind, message) = parse_link(&link(height)).unwrap_err();
                assert_eq!(kind, GiftCardLinkError::InvalidBirthday, "{height}");
                assert!(!message.contains(&key[6..]), "{message}");
            }
            let ptr = parse_link(&link(&nu5.to_string())).unwrap();
            assert_eq!(unsafe { &*ptr }.birthday_height, nu5);
            unsafe { zcashlc_free_gift_card(ptr) };
        }
    }

    #[test]
    fn refuses_bad_links_with_a_stable_code_without_echoing_them() {
        let regtest = v1_link(NetworkType::Regtest, 1);
        let mainnet = v1_link(NetworkType::Main, 3_000_000);
        let key = key_of(&mainnet);
        let cases = [
            (regtest, GiftCardLinkError::WrongNetwork),
            (
                "https://example.com/no-fragment".to_owned(),
                GiftCardLinkError::NotAGiftLink,
            ),
            // The host is not part of the link, but it must be an `https` URL.
            (
                format!("http://gift.zodl.com/#v=1&key={key}&height=3000000"),
                GiftCardLinkError::NotAGiftLink,
            ),
            (
                format!("https://gift.zodl.com/#v=2&key={key}&height=3000000"),
                GiftCardLinkError::UnsupportedVersion,
            ),
            (
                format!("https://gift.zodl.com/#v=1&key={key}x&height=3000000"),
                GiftCardLinkError::InvalidLink,
            ),
            (
                format!("https://gift.zodl.com/#v=1&key={key}"),
                GiftCardLinkError::InvalidLink,
            ),
            (
                "https://gift.zodl.com/#v=1".to_owned(),
                GiftCardLinkError::InvalidLink,
            ),
        ];
        for (link, expected) in cases {
            let (kind, message) = parse_link(&link).unwrap_err();
            assert_eq!(kind, expected, "{link}");
            assert!(!message.is_empty());
            assert!(!message.contains(&key[6..]), "{message}");
        }

        // A null `error_out` is allowed.
        let link = CString::new("not a link").unwrap();
        let ptr = unsafe { zcashlc_parse_gift_card_link(link.as_ptr(), std::ptr::null_mut()) };
        assert!(ptr.is_null());
        unsafe { zcashlc_free_gift_card(std::ptr::null_mut()) };
    }
}
