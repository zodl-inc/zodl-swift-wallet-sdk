use std::{
    ffi::{CStr, CString},
    os::raw::c_char,
};

use ffi_helpers::panic::catch_panic;
use payment_uri::parse_to_json;

use crate::unwrap_exc_or_null;

/// Parses a supported payment URI and returns an internal JSON envelope.
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
        let json = parse_to_json(input).map_err(|_| anyhow::anyhow!("Invalid payment URI"))?;
        Ok(CString::new(json)?.into_raw())
    });
    unwrap_exc_or_null(result)
}
