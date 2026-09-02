use std::{
    ffi::{CStr, CString},
    os::raw::c_char,
};

use ffi_helpers::panic::catch_panic;
use payment_uri::{parse_to_json, Error};

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
        let json = parse_to_json(input)
            .map_err(|e| anyhow::anyhow!("payment URI rejected: {}", classify(&e)))?;
        Ok(CString::new(json)?.into_raw())
    });
    unwrap_exc_or_null(result)
}
