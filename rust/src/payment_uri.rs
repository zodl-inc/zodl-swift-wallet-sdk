use std::{
    borrow::Cow,
    ffi::{CStr, CString},
    os::raw::c_char,
};

use ffi_helpers::panic::catch_panic;
use payment_uri::{Error, parse_to_json};

use crate::unwrap_exc_or_null;

/// Maps a parse failure to a fixed classification token.
///
/// Deliberately returns a `&'static str` rather than the error's `Display` text: per
/// `AGENTS.md`, error strings that cross the FFI must not echo caller input, and every
/// non-unit variant of [`Error`] carries the offending fragment of the URI. The token lets
/// Swift branch on the cause and log it; the fragment stays on this side of the boundary.
fn classify(error: &Error) -> &'static str {
    match error {
        Error::MissingScheme => "missing_scheme",
        Error::UnsupportedScheme(_) => "unsupported_scheme",
        Error::MissingRecipient => "missing_recipient",
        Error::InvalidAddress(_) => "invalid_address",
        Error::InvalidAmount(_) => "invalid_amount",
        Error::DuplicateParameter(_) => "duplicate_parameter",
        Error::UnsupportedRequiredParameter(_) => "unsupported_required_parameter",
        Error::InvalidEncoding(_) => "invalid_encoding",
        Error::InvalidTransactionLink(_) => "invalid_transaction_link",
        Error::Ethereum(_) => "ethereum",
        // `Error` is #[non_exhaustive]: a variant added upstream maps here instead of breaking
        // the build, and Swift reports it as `.rejected(.unclassified)`.
        _ => "unclassified",
    }
}

/// Applies narrow compatibility fixes for protocol-valid UTXO payment URIs that the pinned
/// `payment_uri` revision otherwise mis-parses.
///
/// The normalized value still goes through the single upstream parser below; this function does
/// not validate an address, amount, or extension itself. It only restores the case-insensitive
/// spellings required by the advertised Bitcoin and Litecoin URI contracts:
///
/// - an all-uppercase bech32 address is folded to lowercase before upstream address validation;
/// - Litecoin query keys are folded to lowercase while their values remain byte-for-byte intact.
fn normalize_utxo_compatibility(input: &str) -> Cow<'_, str> {
    let Some((scheme, payload)) = input.split_once(':') else {
        return Cow::Borrowed(input);
    };
    let is_bitcoin = scheme.eq_ignore_ascii_case("bitcoin");
    let is_litecoin = scheme.eq_ignore_ascii_case("litecoin");
    if !is_bitcoin && !is_litecoin {
        return Cow::Borrowed(input);
    }

    let (address, query) = payload
        .split_once('?')
        .map_or((payload, None), |(address, query)| (address, Some(query)));
    let normalized_address = normalize_uppercase_bech32(address, is_bitcoin);
    let normalized_query = query.map(|query| {
        if is_litecoin {
            lowercase_query_keys(query)
        } else {
            Cow::Borrowed(query)
        }
    });

    let changed = matches!(&normalized_address, Cow::Owned(_))
        || matches!(&normalized_query, Some(Cow::Owned(_)));
    if !changed {
        return Cow::Borrowed(input);
    }

    let mut normalized = String::with_capacity(input.len());
    normalized.push_str(scheme);
    normalized.push(':');
    normalized.push_str(normalized_address.as_ref());
    if let Some(query) = normalized_query {
        normalized.push('?');
        normalized.push_str(query.as_ref());
    }
    Cow::Owned(normalized)
}

fn normalize_uppercase_bech32(address: &str, is_bitcoin: bool) -> Cow<'_, str> {
    if address.bytes().any(|byte| byte.is_ascii_lowercase()) {
        return Cow::Borrowed(address);
    }

    let has_known_hrp = if is_bitcoin {
        ["BC1", "TB1", "BCRT1"]
            .iter()
            .any(|prefix| address.starts_with(prefix))
    } else {
        ["LTC1", "TLTC1", "RLTC1"]
            .iter()
            .any(|prefix| address.starts_with(prefix))
    };

    if has_known_hrp {
        Cow::Owned(address.to_ascii_lowercase())
    } else {
        Cow::Borrowed(address)
    }
}

fn lowercase_query_keys(query: &str) -> Cow<'_, str> {
    if !query.split('&').any(|parameter| {
        parameter
            .split_once('=')
            .map_or(parameter, |(key, _)| key)
            .bytes()
            .any(|byte| byte.is_ascii_uppercase())
    }) {
        return Cow::Borrowed(query);
    }

    let mut normalized = String::with_capacity(query.len());
    for (index, parameter) in query.split('&').enumerate() {
        if index > 0 {
            normalized.push('&');
        }
        let (key, value) = parameter
            .split_once('=')
            .map_or((parameter, None), |(key, value)| (key, Some(value)));
        normalized.push_str(&key.to_ascii_lowercase());
        if let Some(value) = value {
            normalized.push('=');
            normalized.push_str(value);
        }
    }
    Cow::Owned(normalized)
}

/// Parses a supported payment URI and returns an internal JSON envelope.
///
/// On failure the last-error slot holds a classification token from [`classify`], or the
/// panic message when the parser itself panicked -- the two are distinguishable, so an
/// upstream crash is not reported to the user as an ordinary bad URI.
///
/// The returned string must be freed with [`zcashlc_string_free`](crate::zcashlc_string_free).
///
/// # Safety
///
/// `input` must point to a null-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_payment_uri_parse(input: *const c_char) -> *mut c_char {
    let result = catch_panic(|| {
        let input = unsafe { CStr::from_ptr(input) }.to_str()?;
        let normalized = normalize_utxo_compatibility(input);
        let json = parse_to_json(normalized.as_ref())
            .map_err(|e| anyhow::anyhow!("payment URI rejected: {}", classify(&e)))?;
        Ok(CString::new(json)?.into_raw())
    });
    unwrap_exc_or_null(result)
}

#[cfg(test)]
mod tests {
    use super::normalize_utxo_compatibility;

    #[test]
    fn normalizes_uppercase_bech32_addresses_for_upstream_validation() {
        assert_eq!(
            normalize_utxo_compatibility(
                "bitcoin:BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4?amount=1"
            ),
            "bitcoin:bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4?amount=1"
        );
        assert_eq!(
            normalize_utxo_compatibility(
                "litecoin:TLTC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KLFSUQ0?amount=1"
            ),
            "litecoin:tltc1qw508d6qejxtdg4y5r3zarvary0c5xw7klfsuq0?amount=1"
        );
    }

    #[test]
    fn normalizes_litecoin_query_keys_without_touching_values() {
        assert_eq!(
            normalize_utxo_compatibility(
                "litecoin:LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA?Amount=1.2500&Label=CaseSensitive"
            ),
            "litecoin:LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA?amount=1.2500&label=CaseSensitive"
        );
        assert_eq!(
            normalize_utxo_compatibility(
                "litecoin:LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA?REQ-Unknown=KeepThis"
            ),
            "litecoin:LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA?req-unknown=KeepThis"
        );
    }

    #[test]
    fn leaves_other_protocols_and_mixed_case_bech32_for_upstream() {
        let ethereum = "ethereum:0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359";
        assert_eq!(normalize_utxo_compatibility(ethereum), ethereum);

        let mixed_case = "bitcoin:bc1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4";
        assert_eq!(normalize_utxo_compatibility(mixed_case), mixed_case);
    }
}
