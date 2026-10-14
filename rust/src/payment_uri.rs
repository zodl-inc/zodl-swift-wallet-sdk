use std::{
    borrow::Cow,
    ffi::{CStr, CString},
    os::raw::c_char,
};

use eip681::parse::RawTransactionRequest;
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
/// not validate an address, amount, or extension itself. It only restores all-uppercase bech32
/// addresses, which are valid encodings used to keep QR codes in alphanumeric mode.
///
/// Query keys are deliberately left alone. Litecoin follows BIP-21's case-sensitive key rules,
/// so changing `req-Amount` to `req-amount` would change an unknown required parameter into a
/// recognised one.
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
    if matches!(&normalized_address, Cow::Borrowed(_)) {
        return Cow::Borrowed(input);
    }

    let mut normalized = String::with_capacity(input.len());
    normalized.push_str(scheme);
    normalized.push(':');
    normalized.push_str(normalized_address.as_ref());
    if let Some(query) = query {
        normalized.push('?');
        normalized.push_str(query);
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

/// Returns whether an Ethereum payment URI contains a hexadecimal address whose payload is not
/// exactly 20 bytes.
///
/// The pinned `eip681` revision parses `0x` followed by *at least* 40 hex digits, and its ERC-55
/// adapter accidentally treats the distinct `IncorrectEthAddressLen` error as success. Checking
/// the URI before delegation also prevents a future adapter-only fix from turning the malformed
/// request into `TransactionRequest::Unrecognised`, because that enum deliberately swallows typed
/// conversion errors. This remains deliberately narrow: ENS names and non-address ABI parameters
/// still go through the upstream parser unchanged.
fn has_invalid_ethereum_address_length(input: &str) -> bool {
    let Some((scheme, payload)) = input.split_once(':') else {
        return false;
    };
    if !scheme.eq_ignore_ascii_case("ethereum") {
        return false;
    }

    let payload = payload.strip_prefix("pay-").unwrap_or(payload);
    let target_end = payload
        .find(|character| matches!(character, '@' | '/' | '?'))
        .unwrap_or(payload.len());
    if has_invalid_hex_address_length(&payload[..target_end]) {
        return true;
    }

    payload.split_once('?').is_some_and(|(_, query)| {
        query.split('&').any(|parameter| {
            parameter.split_once('=').is_some_and(|(key, value)| {
                key == "address" && has_invalid_hex_address_length(value)
            })
        })
    })
}

fn has_invalid_hex_address_length(candidate: &str) -> bool {
    let Some(hex_digits) = candidate.strip_prefix("0x") else {
        return false;
    };
    hex_digits.bytes().all(|byte| byte.is_ascii_hexdigit()) && hex_digits.len() != 40
}

/// Returns whether the pinned EIP-681 parser would lose a validation error while projecting its
/// typed result into the JSON envelope.
///
/// `Erc20Request::chain_id()` turns an overflowing explicit id into `None`, and the native request
/// getters turn conflicting `value`, `gas`/`gasLimit`, or `gasPrice` parameters into `None`.
/// Running the low-level parser's checked accessors first preserves the difference between an
/// omitted field and an invalid one. Equal duplicate values remain accepted by those accessors.
fn has_invalid_ethereum_semantics(input: &str) -> bool {
    let Some((scheme, payload)) = input.split_once(':') else {
        return false;
    };
    if !scheme.eq_ignore_ascii_case("ethereum") {
        return false;
    }

    let canonical = format!("ethereum:{payload}");
    let Ok((remaining, request)) = RawTransactionRequest::parse(&canonical) else {
        return false;
    };
    if !remaining.is_empty() {
        return false;
    }

    if request
        .chain_id
        .as_ref()
        .is_some_and(|chain_id| chain_id.as_u64().is_err())
    {
        return true;
    }

    request.parameters.as_ref().is_some_and(|parameters| {
        parameters.value().is_err()
            || parameters.gas_limit().is_err()
            || parameters.gas_price().is_err()
    })
}

/// Returns whether an SPL-token amount is too large to fit the `u64` carried by every SPL transfer
/// instruction, even at the smallest precision capable of expressing the supplied decimal.
fn has_unrepresentable_spl_amount(input: &str) -> bool {
    let Some((scheme, payload)) = input.split_once(':') else {
        return false;
    };
    if !scheme.eq_ignore_ascii_case("solana") {
        return false;
    }
    let Some((_, query)) = payload.split_once('?') else {
        return false;
    };

    let mut amount = None;
    let mut amount_count = 0;
    let mut spl_token_count = 0;
    for parameter in query.split('&') {
        let (key, value) = parameter.split_once('=').unwrap_or((parameter, ""));
        match key {
            "amount" => {
                amount_count += 1;
                amount = Some(value);
            }
            "spl-token" => spl_token_count += 1,
            _ => {}
        }
    }

    // Let the upstream parser classify duplicates and malformed decimal text itself.
    if amount_count != 1 || spl_token_count != 1 {
        return false;
    }
    amount
        .and_then(minimal_atomic_value_fits_u64)
        .is_some_and(|fits| !fits)
}

/// Checks the integer obtained by expressing a decimal at its minimal exact precision.
///
/// Trailing fractional zeros do not require precision. Comparing the remaining digits directly
/// avoids computing `10^scale`, which would overflow for a tiny value such as 1e-20 even though
/// its exact atomic numerator is just one.
fn minimal_atomic_value_fits_u64(value: &str) -> Option<bool> {
    let (whole, fraction) = value
        .split_once('.')
        .map_or((value, None), |(whole, fraction)| (whole, Some(fraction)));
    if whole.is_empty()
        || !whole.bytes().all(|byte| byte.is_ascii_digit())
        || fraction.is_some_and(|digits| {
            digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit())
        })
    {
        return None;
    }

    let fraction = fraction.unwrap_or("").trim_end_matches('0');
    let digits = format!("{whole}{fraction}");
    let significant = digits.trim_start_matches('0');
    if significant.is_empty() {
        return Some(true);
    }
    Some(significant.parse::<u64>().is_ok())
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
        if has_invalid_ethereum_address_length(input) {
            anyhow::bail!("payment URI rejected: invalid_address");
        }
        if has_invalid_ethereum_semantics(input) {
            anyhow::bail!("payment URI rejected: ethereum");
        }
        if has_unrepresentable_spl_amount(input) {
            anyhow::bail!("payment URI rejected: invalid_amount");
        }
        let normalized = normalize_utxo_compatibility(input);
        let json = parse_to_json(normalized.as_ref())
            .map_err(|e| anyhow::anyhow!("payment URI rejected: {}", classify(&e)))?;
        Ok(CString::new(json)?.into_raw())
    });
    unwrap_exc_or_null(result)
}

#[cfg(test)]
mod tests {
    use super::{
        has_invalid_ethereum_address_length, has_invalid_ethereum_semantics,
        has_unrepresentable_spl_amount, minimal_atomic_value_fits_u64,
        normalize_utxo_compatibility,
    };

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
    fn preserves_litecoin_query_key_case() {
        assert_eq!(
            normalize_utxo_compatibility(
                "litecoin:LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA?Amount=1.2500&Label=CaseSensitive"
            ),
            "litecoin:LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA?Amount=1.2500&Label=CaseSensitive"
        );
        assert_eq!(
            normalize_utxo_compatibility(
                "litecoin:LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA?REQ-Unknown=KeepThis"
            ),
            "litecoin:LT2KVaAy1ppRuxRgrS5RNU3vBsy7RibPeA?REQ-Unknown=KeepThis"
        );
    }

    #[test]
    fn leaves_other_protocols_and_mixed_case_bech32_for_upstream() {
        let ethereum = "ethereum:0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359";
        assert_eq!(normalize_utxo_compatibility(ethereum), ethereum);

        let mixed_case = "bitcoin:bc1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4";
        assert_eq!(normalize_utxo_compatibility(mixed_case), mixed_case);
    }

    #[test]
    fn rejects_overlength_ethereum_targets_and_address_parameters() {
        let overlength = format!("0x{}", "a".repeat(41));
        let valid = format!("0x{}", "b".repeat(40));

        assert!(has_invalid_ethereum_address_length(&format!(
            "ethereum:{overlength}"
        )));
        assert!(has_invalid_ethereum_address_length(&format!(
            "ethereum:{overlength}/transfer?address={valid}&uint256=1"
        )));
        assert!(has_invalid_ethereum_address_length(&format!(
            "ethereum:{valid}/transfer?address={overlength}&uint256=1"
        )));
        assert!(has_invalid_ethereum_address_length(&format!(
            "ethereum:{overlength}/approve?address={valid}&uint256=1"
        )));
    }

    #[test]
    fn permits_exact_ethereum_addresses_ens_names_and_non_address_values() {
        let valid = format!("0x{}", "a".repeat(40));
        let long_uint256 = format!("0x{}", "f".repeat(64));

        assert!(!has_invalid_ethereum_address_length(&format!(
            "ethereum:pay-{valid}@1?value=1"
        )));
        assert!(!has_invalid_ethereum_address_length(
            "ethereum:alice.eth/transfer?address=bob.eth&uint256=1"
        ));
        assert!(!has_invalid_ethereum_address_length(&format!(
            "ethereum:{valid}/custom?bytes32={long_uint256}"
        )));
        assert!(!has_invalid_ethereum_address_length(&format!(
            "bitcoin:{long_uint256}"
        )));
    }

    #[test]
    fn rejects_ethereum_semantics_that_typed_getters_would_erase() {
        let address = "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359";
        let token = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";

        assert!(has_invalid_ethereum_semantics(&format!(
            "ethereum:{token}@18446744073709551616/transfer?address={address}&uint256=1"
        )));
        assert!(has_invalid_ethereum_semantics(&format!(
            "ethereum:{address}?value=1&value=2"
        )));
        assert!(has_invalid_ethereum_semantics(&format!(
            "ethereum:{address}?gas=21000&gasLimit=22000"
        )));

        assert!(!has_invalid_ethereum_semantics(&format!(
            "ethereum:{address}?value=1&value=1"
        )));
        assert!(!has_invalid_ethereum_semantics(&format!(
            "ethereum:{address}?gas=21000&gasLimit=21000"
        )));
    }

    #[test]
    fn rejects_only_universally_unrepresentable_spl_amounts() {
        let recipient = "mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN";
        let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";

        assert!(has_unrepresentable_spl_amount(&format!(
            "solana:{recipient}?amount=99999999999999999999999999999&spl-token={mint}"
        )));
        assert!(has_unrepresentable_spl_amount(&format!(
            "solana:{recipient}?amount=18446744073709551615.1&spl-token={mint}"
        )));
        assert!(!has_unrepresentable_spl_amount(&format!(
            "solana:{recipient}?amount=18446744073709551615.0&spl-token={mint}"
        )));
        assert!(!has_unrepresentable_spl_amount(&format!(
            "solana:{recipient}?amount=0.00000000000000000001&spl-token={mint}"
        )));
        assert!(!has_unrepresentable_spl_amount(&format!(
            "solana:{recipient}?amount=99999999999999999999999999999"
        )));

        assert_eq!(minimal_atomic_value_fits_u64("1.2300"), Some(true));
        assert_eq!(
            minimal_atomic_value_fits_u64("0.00000000000000000001"),
            Some(true)
        );
        assert_eq!(
            minimal_atomic_value_fits_u64("18446744073709551615"),
            Some(true)
        );
        assert_eq!(
            minimal_atomic_value_fits_u64("18446744073709551616"),
            Some(false)
        );
        assert_eq!(minimal_atomic_value_fits_u64("1."), None);
    }
}
