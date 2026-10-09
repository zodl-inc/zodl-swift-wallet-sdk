//! C ABI onto the shared OHTTP client core (`zodl-ohttp-client`, `ClientProfile::IOS`).
//!
//! The Swift SDK keeps the I/O of an Oblivious HTTP exchange (URLSession or Tor, the relay
//! tables, the key-configuration cache, the retry loop) and delegates everything that is
//! protocol to the core: the signed key-configuration envelope and the key selection, the
//! Binary HTTP codec, the HPKE sealing, the classification of the relay's answer and the
//! opening of the sealed response.
//!
//! Per request there are two calls, [`zcashlc_ohttp_encapsulate`] before the post and
//! [`zcashlc_ohttp_complete`] after it, and one [`zcashlc_ohttp_verify_key_config`] per key
//! fetch.
//!
//! The response secret never crosses the boundary. [`zcashlc_ohttp_encapsulate`] boxes the
//! chunked `ChunkedResponseOpener` and returns an opaque [`OhttpOpener`] handle;
//! [`zcashlc_ohttp_complete`] takes that handle by value, consumes it whatever the outcome, and
//! so the single-use rule of the core holds across the boundary. A handle whose post failed
//! before `complete` is called is released with [`zcashlc_ohttp_opener_free`]. Every attempt
//! must call `zcashlc_ohttp_encapsulate` again: the gateway answers a repeated nonce with 409.
//!
//! Errors follow the crate's convention: a failed call returns null and leaves the error in the
//! thread-local last error. The text is the core's fixed `Display` of the failure, which does not
//! quote the request or the response body.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::AssertUnwindSafe;
use std::ptr;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zodl_ohttp_client::{
    BhttpRequest, BhttpResponse, CONTENT_TYPE_CHUNKED_REQ, CONTENT_TYPE_CHUNKED_RES,
    ChunkedResponseOpener, ClientProfile, KEY_BYTES, KeyConfig, Network, OuterOutcome, OuterPolicy,
    OuterResponse, ResponseEvent, check_size, classify_outer_response, encapsulate_chunked_request,
    encode_bhttp_request, pack_fields, signed_config_url, unpack_fields, verify_signed_config,
};

use crate::{free_ptr_from_vec, ptr_from_vec, unwrap_exc_or_null, zcashlc_string_free};

/// The `kind` of an [`OhttpOutcome`]: the sealed answer opened.
const OUTCOME_RESPONSE: u32 = 0;
/// The `kind` of an [`OhttpOutcome`]: the gateway does not know the key configuration.
const OUTCOME_REFETCH_KEY: u32 = 1;
/// The `kind` of an [`OhttpOutcome`]: the relay or the gateway refused the request.
const OUTCOME_REFUSED: u32 = 2;
/// The `kind` of an [`OhttpOutcome`]: a success status not labelled `message/ohttp-chunked-res`.
const OUTCOME_WRONG_MEDIA_TYPE: u32 = 3;

/// Opens the response to one sealed request, and no other.
///
/// Obtained from [`zcashlc_ohttp_encapsulate`]. Single use: [`zcashlc_ohttp_complete`] consumes
/// it, and [`zcashlc_ohttp_opener_free`] releases one that was never completed. The secret it
/// holds is zeroized when it is dropped.
pub struct OhttpOpener {
    inner: ChunkedResponseOpener,
}

/// The gateway's key, checked and selected out of a signed envelope.
///
/// Freed with [`zcashlc_free_ohttp_key`].
#[repr(C)]
pub struct OhttpKey {
    /// `key_id || X25519 public key`, public data to be kept by the caller next to
    /// `not_after` and handed back to [`zcashlc_ohttp_encapsulate`].
    key: [u8; 33],
    /// The end of the envelope's validity, Unix seconds.
    not_after: u64,
    /// The network the envelope was checked for: 0 mainnet, 1 testnet.
    network: u8,
}

/// A sealed request and what opens its answer.
///
/// Freed with [`zcashlc_free_ohttp_sealed`], which frees `body` and, if `opener` is still set,
/// the opener too. A caller that takes the opener out sets the field to null first.
#[repr(C)]
pub struct OhttpSealed {
    /// The body to post to the relay as `message/ohttp-chunked-req`.
    body: *mut u8,
    body_len: usize,
    /// Opens the answer; never null on return.
    opener: *mut OhttpOpener,
}

/// What the relay's answer came to.
///
/// Freed with [`zcashlc_free_ohttp_outcome`].
///
/// `kind` is `0` for an opened response (`status`, `headers`, `trailers` and `body` are the
/// backend's), `1` when the key configuration must be fetched again and the request sealed
/// afresh, `2` when the relay or the gateway refused (`status` is the outer status, `detail`
/// the start of its body) and `3` for a success status not labelled `message/ohttp-chunked-res`
/// (`detail` is the `Content-Type` received). Fields a kind does not use are null and zero.
#[repr(C)]
pub struct OhttpOutcome {
    kind: u32,
    status: u16,
    /// Header fields of an opened response, packed by `pack_fields`: for each name and value a
    /// 4-byte big-endian length and the bytes.
    headers: *mut u8,
    headers_len: usize,
    /// Trailer fields of an opened response, packed like `headers`.
    trailers: *mut u8,
    trailers_len: usize,
    body: *mut u8,
    body_len: usize,
    /// NUL-terminated, or null.
    detail: *mut c_char,
}

/// The client's own headers on its relay requests and its key-configuration cache rules, as
/// the core's profile sets them.
///
/// Freed with [`zcashlc_free_ohttp_profile_info`].
#[repr(C)]
pub struct OhttpProfileInfo {
    /// Headers of the post of a sealed request (without a trace id), packed by `pack_fields`.
    post_headers: *mut u8,
    post_headers_len: usize,
    /// Headers of the fetch of the signed key configuration (without a trace id), packed.
    key_fetch_headers: *mut u8,
    key_fetch_headers_len: usize,
    /// Seconds before `not_after` from which a cached key configuration is no longer used.
    cache_refresh_margin_secs: u64,
    /// Whether the cached key configuration is dropped before the fetch that replaces it.
    drop_before_refetch: bool,
    /// Whether the key-configuration fetch carries the trace id as the post does.
    trace_on_key_fetch: bool,
}

fn profile_from_id(id: u32) -> anyhow::Result<ClientProfile> {
    ClientProfile::by_id(id).ok_or_else(|| anyhow!("unknown OHTTP profile {id}"))
}

/// `len` bytes at `ptr`, or nothing when `len` is zero (the pointer may then be null).
///
/// # Safety
///
/// - When `len` is non-zero, `ptr` must be non-null and valid for reads for `len` bytes, with an
///   alignment of `1`, and the memory must not be mutated while the slice is in use.
unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> anyhow::Result<&'a [u8]> {
    if len == 0 {
        Ok(&[])
    } else if ptr.is_null() {
        Err(anyhow!("null pointer with a non-zero length"))
    } else {
        Ok(unsafe { std::slice::from_raw_parts(ptr, len) })
    }
}

/// A C string from `text`, with any interior NUL replaced.
fn c_string(text: &str) -> *mut c_char {
    CString::new(text.replace('\0', "\u{fffd}"))
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}

fn as_fields(list: Vec<(&'static str, String)>) -> Vec<(Vec<u8>, Vec<u8>)> {
    list.into_iter()
        .map(|(name, value)| (name.as_bytes().to_vec(), value.into_bytes()))
        .collect()
}

/// Checks the signed key-configuration envelope `json` fetched for the gateway `host` under the
/// profile `profile` (2 for iOS), and selects the gateway's key out of it.
///
/// The network, and so the pinned signing key, follows from `host` under the profile's rule. The
/// envelope is checked for its version, network, key id, validity window at `now_secs` (Unix
/// seconds), size and signature, and refused if it repeats a field name.
///
/// Returns null on failure (see the module documentation); the result is freed with
/// [`zcashlc_free_ohttp_key`].
///
/// # Safety
///
/// - `host` must be valid for reads for `host_len` bytes and `json` for `json_len` bytes, each
///   with an alignment of `1`, or null when the length is zero.
/// - The memory referenced by `host` and `json` must not be mutated for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_verify_key_config(
    profile: u32,
    host: *const u8,
    host_len: usize,
    json: *const u8,
    json_len: usize,
    now_secs: u64,
) -> *mut OhttpKey {
    let res = catch_panic(|| {
        let profile = profile_from_id(profile)?;
        let host = std::str::from_utf8(unsafe { bytes(host, host_len)? })
            .map_err(|_| anyhow!("the gateway host is not UTF-8"))?;
        let json = unsafe { bytes(json, json_len)? };

        let network = profile.network_rule.network_for(host)?;
        let signed = verify_signed_config(json, network, now_secs, &profile.signed_config)?;
        let key = KeyConfig::select_with(&signed.document, &profile.key_selection)?;

        Ok(Box::into_raw(Box::new(OhttpKey {
            key: key.to_bytes(),
            not_after: signed.not_after,
            network: match network {
                Network::Mainnet => 0,
                Network::Testnet => 1,
            },
        })))
    });
    unwrap_exc_or_null(res)
}

/// Frees an [`OhttpKey`].
///
/// # Safety
///
/// - `ptr` must be null or a pointer returned by [`zcashlc_ohttp_verify_key_config`] that has
///   not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_ohttp_key(ptr: *mut OhttpKey) {
    if !ptr.is_null() {
        drop(unsafe { Box::from_raw(ptr) });
    }
}

/// Encodes a request as Binary HTTP and seals it to the gateway key `key`, with a fresh
/// ephemeral key: call it again for every attempt, a retry included.
///
/// `headers` holds the request's header fields packed by `pack_fields` (for each name and value a
/// 4-byte big-endian length and the bytes); names are lower-cased by the profile. The text
/// arguments are bytes: the caller decides how its strings become bytes.
///
/// Returns null on failure, including a sealed request above the profile's limit (10 MiB); the
/// result is freed with [`zcashlc_free_ohttp_sealed`].
///
/// # Safety
///
/// - `key` must be non-null and valid for reads for 33 bytes (`OhttpKey::key`).
/// - Each `(pointer, length)` pair must be valid for reads for its length, with an alignment of
///   `1`, or null when the length is zero.
/// - The memory referenced by these pointers must not be mutated for the duration of the call.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn zcashlc_ohttp_encapsulate(
    profile: u32,
    key: *const u8,
    method: *const u8,
    method_len: usize,
    scheme: *const u8,
    scheme_len: usize,
    authority: *const u8,
    authority_len: usize,
    path: *const u8,
    path_len: usize,
    headers: *const u8,
    headers_len: usize,
    body: *const u8,
    body_len: usize,
) -> *mut OhttpSealed {
    let res = catch_panic(|| {
        let profile = profile_from_id(profile)?;
        if key.is_null() {
            return Err(anyhow!("missing gateway key"));
        }
        let key = KeyConfig::from_bytes(unsafe { std::slice::from_raw_parts(key, KEY_BYTES) })
            .ok_or_else(|| anyhow!("malformed gateway key"))?;

        let request = BhttpRequest {
            method: unsafe { bytes(method, method_len)? }.to_vec(),
            scheme: unsafe { bytes(scheme, scheme_len)? }.to_vec(),
            authority: unsafe { bytes(authority, authority_len)? }.to_vec(),
            path: unsafe { bytes(path, path_len)? }.to_vec(),
            headers: unpack_fields(unsafe { bytes(headers, headers_len)? })?,
            body: unsafe { bytes(body, body_len)? }.to_vec(),
        };

        // Encode the request as Binary HTTP
        let encoded_request = encode_bhttp_request(&request, &profile.encode)?;

        // The gateway and the relay answer 413 above the cap: refuse here, before the HPKE work.
        check_size(
            encoded_request.len(),
            profile.limits.max_sealed_request_bytes,
        )?;

        // Encapsulate as chunked OHTTP
        let (sealed_body, response_opener) = encapsulate_chunked_request(&key, &encoded_request)?;
        let (body, body_len) = ptr_from_vec(sealed_body);
        let opener = Box::into_raw(Box::new(OhttpOpener {
            inner: response_opener,
        }));

        Ok(Box::into_raw(Box::new(OhttpSealed {
            body,
            body_len,
            opener,
        })))
    });
    unwrap_exc_or_null(res)
}

/// Frees an [`OhttpSealed`], its `body` and, if the field is still set, its `opener`.
///
/// # Safety
///
/// - `ptr` must be null or a pointer returned by [`zcashlc_ohttp_encapsulate`] that has not been
///   freed.
/// - A non-null `opener` field must not have been passed to [`zcashlc_ohttp_complete`] or
///   [`zcashlc_ohttp_opener_free`]: the caller that does so sets the field to null first.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_ohttp_sealed(ptr: *mut OhttpSealed) {
    if !ptr.is_null() {
        let sealed = unsafe { Box::from_raw(ptr) };
        free_ptr_from_vec(sealed.body, sealed.body_len);
        if !sealed.opener.is_null() {
            drop(unsafe { Box::from_raw(sealed.opener) });
        }
    }
}

/// What follows the post of a sealed request: classifies the relay's answer and, for a sealed
/// one, opens it and decodes the Binary HTTP response.
///
/// `outer_status` and `content_type` (NUL-terminated UTF-8, or null) are those of the relay's
/// answer and `body` is its whole body. `attempt` is 0 for the first post of a request and 1 for
/// the post after an outcome of kind `1`.
///
/// **Consumes `opener` in every case**, errors included: it must not be used or freed again.
///
/// Returns null on failure (a sealed answer that is too large, does not open, or is not a
/// response); the result is freed with [`zcashlc_free_ohttp_outcome`].
///
/// # Safety
///
/// - `opener` must be a pointer returned in [`OhttpSealed::opener`] by
///   [`zcashlc_ohttp_encapsulate`] that has not been completed or freed.
/// - `content_type` must be null or a NUL-terminated string.
/// - `body` must be valid for reads for `body_len` bytes, with an alignment of `1`, or null when
///   `body_len` is zero, and must not be mutated for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_complete(
    profile: u32,
    opener: *mut OhttpOpener,
    outer_status: u16,
    content_type: *const c_char,
    body: *const u8,
    body_len: usize,
    attempt: u32,
) -> *mut OhttpOutcome {
    // SAFETY: the pointer is the only state the closure reads. A panic leaves nothing to observe
    // through it: the opener is taken out of its box before anything else can fail, and is
    // dropped (and zeroized) with the closure's frame on every path.
    let opener = AssertUnwindSafe(opener);

    let res = catch_panic(|| {
        let opener = *opener;
        if opener.is_null() {
            return Err(anyhow!("missing OHTTP opener"));
        }
        let OhttpOpener { inner } = *unsafe { Box::from_raw(opener) };
        let profile = profile_from_id(profile)?;
        let content_type = if content_type.is_null() {
            None
        } else {
            Some(
                unsafe { CStr::from_ptr(content_type) }
                    .to_str()
                    .map_err(|_| anyhow!("the content type is not UTF-8"))?,
            )
        };

        // Classify the outer response using the iOS policy
        let sealed = unsafe { bytes(body, body_len)? };
        let outer_response = OuterResponse {
            status: outer_status,
            content_type,
            body: sealed,
        };
        let outer_outcome = classify_outer_response(&OuterPolicy::IOS, &outer_response, attempt);

        // Process based on classification
        let outcome = match outer_outcome {
            OuterOutcome::Sealed => {
                // Decode the chunked response
                let mut decoder = inner.decoder();
                let mut events = decoder.push(sealed)?;
                events.extend(decoder.finish()?);

                // Collect events into BhttpResponse
                let mut status = None;
                let mut headers = Vec::new();
                let mut body = Vec::new();
                let mut trailers = Vec::new();
                for event in events {
                    match event {
                        ResponseEvent::Head {
                            status: s,
                            headers: h,
                        } => {
                            status = Some(s);
                            headers = h
                                .into_iter()
                                .map(|(n, v)| (n.into_bytes(), v.into_bytes()))
                                .collect();
                        }
                        ResponseEvent::Data(d) => body.extend_from_slice(&d),
                        ResponseEvent::Trailers(t) => {
                            trailers = t
                                .into_iter()
                                .map(|(n, v)| (n.into_bytes(), v.into_bytes()))
                                .collect();
                        }
                        ResponseEvent::End => {}
                    }
                }
                let bhttp_response = BhttpResponse {
                    informational: vec![],
                    status: status.ok_or_else(|| anyhow!("no status in response"))?,
                    headers,
                    trailers,
                    body,
                };
                outcome_from_response(bhttp_response)?
            }
            OuterOutcome::RefetchKeyConfig => {
                let mut outcome = OhttpOutcome {
                    kind: OUTCOME_REFETCH_KEY,
                    status: 0,
                    headers: ptr::null_mut(),
                    headers_len: 0,
                    trailers: ptr::null_mut(),
                    trailers_len: 0,
                    body: ptr::null_mut(),
                    body_len: 0,
                    detail: ptr::null_mut(),
                };
                outcome
            }
            OuterOutcome::Refused { status, detail } => {
                let mut outcome = OhttpOutcome {
                    kind: OUTCOME_REFUSED,
                    status,
                    headers: ptr::null_mut(),
                    headers_len: 0,
                    trailers: ptr::null_mut(),
                    trailers_len: 0,
                    body: ptr::null_mut(),
                    body_len: 0,
                    detail: c_string(&detail),
                };
                outcome
            }
            OuterOutcome::WrongMediaType { content_type } => {
                let mut outcome = OhttpOutcome {
                    kind: OUTCOME_WRONG_MEDIA_TYPE,
                    status: 0,
                    headers: ptr::null_mut(),
                    headers_len: 0,
                    trailers: ptr::null_mut(),
                    trailers_len: 0,
                    body: ptr::null_mut(),
                    body_len: 0,
                    detail: c_string(&content_type),
                };
                outcome
            }
        };

        Ok(Box::into_raw(Box::new(outcome)))
    });
    unwrap_exc_or_null(res)
}

fn outcome_from_response(response: BhttpResponse) -> anyhow::Result<OhttpOutcome> {
    let (headers, headers_len) = ptr_from_vec(pack_fields(&response.headers)?);
    let (trailers, trailers_len) = ptr_from_vec(pack_fields(&response.trailers)?);
    let (body, body_len) = ptr_from_vec(response.body);
    Ok(OhttpOutcome {
        kind: OUTCOME_RESPONSE,
        status: response.status,
        headers,
        headers_len,
        trailers,
        trailers_len,
        body,
        body_len,
        detail: ptr::null_mut(),
    })
}

/// Frees an [`OhttpOutcome`] and everything it owns.
///
/// # Safety
///
/// - `ptr` must be null or a pointer returned by [`zcashlc_ohttp_complete`] that has not been
///   freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_ohttp_outcome(ptr: *mut OhttpOutcome) {
    if !ptr.is_null() {
        let outcome = unsafe { Box::from_raw(ptr) };
        free_ptr_from_vec(outcome.headers, outcome.headers_len);
        free_ptr_from_vec(outcome.trailers, outcome.trailers_len);
        free_ptr_from_vec(outcome.body, outcome.body_len);
        unsafe { zcashlc_string_free(outcome.detail) };
    }
}

/// Releases an [`OhttpOpener`] whose post failed, so that [`zcashlc_ohttp_complete`] was never
/// called for it. A completed opener is already consumed and must not be passed here.
///
/// # Safety
///
/// - `ptr` must be null or a pointer returned in [`OhttpSealed::opener`] by
///   [`zcashlc_ohttp_encapsulate`] that has not been completed or freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_opener_free(ptr: *mut OhttpOpener) {
    if !ptr.is_null() {
        drop(unsafe { Box::from_raw(ptr) });
    }
}

/// The URL of the signed key configuration of the relay at `relay_url`, under the profile's rule.
///
/// Returns null on failure; the string is freed with `zcashlc_string_free`.
///
/// # Safety
///
/// - `relay_url` must be valid for reads for `relay_url_len` bytes, with an alignment of `1`, or
///   null when the length is zero, and must not be mutated for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_signed_config_url(
    profile: u32,
    relay_url: *const u8,
    relay_url_len: usize,
) -> *mut c_char {
    let res = catch_panic(|| {
        let profile = profile_from_id(profile)?;
        let relay_url = std::str::from_utf8(unsafe { bytes(relay_url, relay_url_len)? })
            .map_err(|_| anyhow!("the relay URL is not UTF-8"))?;
        let url = signed_config_url(relay_url, profile.signed_config_url)?;
        Ok(CString::new(url)?.into_raw())
    });
    unwrap_exc_or_null(res)
}

/// Returns the relay URL for a given gateway host, or null if the host is not a known gateway.
/// The built-in mapping can be overridden at build time via environment variables
/// `ZODL_OHTTP_RELAY_URL_MAINNET` and `ZODL_OHTTP_RELAY_URL_TESTNET`.
///
/// The string is freed with `zcashlc_string_free`.
///
/// # Safety
///
/// - `gateway_host` must be valid for reads for `gateway_host_len` bytes, with an alignment of `1`,
///   or null when the length is zero, and must not be mutated for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_relay_url_for(
    gateway_host: *const u8,
    gateway_host_len: usize,
) -> *mut c_char {
    let res = catch_panic(|| {
        let gateway_host = std::str::from_utf8(unsafe { bytes(gateway_host, gateway_host_len)? })
            .map_err(|_| anyhow!("the gateway host is not UTF-8"))?;
        match zodl_ohttp_client::relay_for(gateway_host) {
            Some(relay_url) => Ok(CString::new(relay_url)?.into_raw()),
            None => Ok(ptr::null_mut()),
        }
    });
    unwrap_exc_or_null(res)
}

/// The client's own request headers and key-configuration cache rules under the profile.
///
/// Returns null for an unknown profile; the result is freed with
/// [`zcashlc_free_ohttp_profile_info`].
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ohttp_profile_info(profile: u32) -> *mut OhttpProfileInfo {
    let res = catch_panic(|| {
        let profile = profile_from_id(profile)?;
        let (post_headers, post_headers_len) =
            ptr_from_vec(pack_fields(&as_fields(profile.headers.relay_post(None)))?);
        let (key_fetch_headers, key_fetch_headers_len) =
            ptr_from_vec(pack_fields(&as_fields(profile.headers.key_fetch(None)))?);

        Ok(Box::into_raw(Box::new(OhttpProfileInfo {
            post_headers,
            post_headers_len,
            key_fetch_headers,
            key_fetch_headers_len,
            cache_refresh_margin_secs: profile.cache.refresh_margin_secs,
            drop_before_refetch: profile.cache.drop_before_refetch,
            trace_on_key_fetch: profile.headers.trace_on_key_fetch,
        })))
    });
    unwrap_exc_or_null(res)
}

/// Frees an [`OhttpProfileInfo`].
///
/// # Safety
///
/// - `ptr` must be null or a pointer returned by [`zcashlc_ohttp_profile_info`] that has not been
///   freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_free_ohttp_profile_info(ptr: *mut OhttpProfileInfo) {
    if !ptr.is_null() {
        let info = unsafe { Box::from_raw(ptr) };
        free_ptr_from_vec(info.post_headers, info.post_headers_len);
        free_ptr_from_vec(info.key_fetch_headers, info.key_fetch_headers_len);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{zcashlc_clear_last_error, zcashlc_last_error_length};

    /// The profile number of iOS (`ClientProfile::IOS`).
    const IOS: u32 = 2;

    #[test]
    fn the_key_is_33_bytes_as_the_header_declares() {
        assert_eq!(KEY_BYTES, 33);
        assert_eq!(std::mem::size_of::<[u8; 33]>(), KEY_BYTES);
    }

    /// A gateway key: id 7 and the X25519 base point, a valid public key.
    fn gateway_key() -> [u8; 33] {
        let mut key = [0; 33];
        key[0] = 7;
        key[1] = 9;
        key
    }

    unsafe fn slice<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
        unsafe { bytes(ptr, len) }.unwrap()
    }

    fn seal(path: &[u8], key: &[u8; 33]) -> *mut OhttpSealed {
        let headers = pack_fields(&[(b"x-test".to_vec(), b"1".to_vec())]).unwrap();
        unsafe {
            zcashlc_ohttp_encapsulate(
                IOS,
                key.as_ptr(),
                b"GET".as_ptr(),
                3,
                b"https".as_ptr(),
                5,
                b"gateway.example".as_ptr(),
                15,
                path.as_ptr(),
                path.len(),
                headers.as_ptr(),
                headers.len(),
                ptr::null(),
                0,
            )
        }
    }

    /// Takes the opener out of `sealed`, as the Swift wrapper does, and frees the rest.
    fn take_opener(sealed: *mut OhttpSealed) -> (*mut OhttpOpener, Vec<u8>) {
        assert!(!sealed.is_null());
        let (opener, body) = unsafe {
            let s = &mut *sealed;
            let opener = std::mem::replace(&mut s.opener, ptr::null_mut());
            (opener, slice(s.body, s.body_len).to_vec())
        };
        unsafe { zcashlc_free_ohttp_sealed(sealed) };
        assert!(!opener.is_null());
        (opener, body)
    }

    fn complete(
        opener: *mut OhttpOpener,
        status: u16,
        body: &[u8],
        attempt: u32,
    ) -> *mut OhttpOutcome {
        unsafe {
            zcashlc_ohttp_complete(
                IOS,
                opener,
                status,
                ptr::null(),
                body.as_ptr(),
                body.len(),
                attempt,
            )
        }
    }

    fn detail(outcome: &OhttpOutcome) -> String {
        unsafe { CStr::from_ptr(outcome.detail) }
            .to_str()
            .unwrap()
            .to_string()
    }

    #[test]
    fn profile_info_is_the_ios_profile() {
        let info = zcashlc_ohttp_profile_info(IOS);
        assert!(!info.is_null());
        {
            let info = unsafe { &*info };
            let post =
                unpack_fields(unsafe { slice(info.post_headers, info.post_headers_len) }).unwrap();
            let post: Vec<(String, String)> = post
                .into_iter()
                .map(|(n, v)| (String::from_utf8(n).unwrap(), String::from_utf8(v).unwrap()))
                .collect();
            assert_eq!(
                post,
                vec![
                    (
                        "Content-Type".to_string(),
                        CONTENT_TYPE_CHUNKED_REQ.to_string()
                    ),
                    ("Accept".to_string(), CONTENT_TYPE_CHUNKED_RES.to_string()),
                    ("Accept-Encoding".to_string(), "identity".to_string()),
                ]
            );
            let fetch =
                unpack_fields(unsafe { slice(info.key_fetch_headers, info.key_fetch_headers_len) })
                    .unwrap();
            assert_eq!(
                fetch,
                vec![(b"Accept".to_vec(), b"application/ohttp-keys".to_vec())]
            );
            assert_eq!(info.cache_refresh_margin_secs, 0);
            assert!(info.drop_before_refetch);
            assert!(info.trace_on_key_fetch);
        }
        unsafe { zcashlc_free_ohttp_profile_info(info) };
    }

    #[test]
    fn an_unknown_profile_is_an_error() {
        zcashlc_clear_last_error();
        assert!(zcashlc_ohttp_profile_info(99).is_null());
        assert!(zcashlc_last_error_length() > 0);
        zcashlc_clear_last_error();
    }

    #[test]
    fn the_signed_config_url_replaces_the_relay_suffix_and_does_not_trim_a_slash() {
        for (relay, expected) in [
            (
                "https://relay.example/relay",
                "https://relay.example/ohttp-configs/signed",
            ),
            (
                "https://relay.example/relay/",
                "https://relay.example/relay//ohttp-configs/signed",
            ),
            (
                "https://relay.example",
                "https://relay.example/ohttp-configs/signed",
            ),
        ] {
            let url = unsafe { zcashlc_ohttp_signed_config_url(IOS, relay.as_ptr(), relay.len()) };
            assert!(!url.is_null());
            assert_eq!(unsafe { CStr::from_ptr(url) }.to_str().unwrap(), expected);
            unsafe { zcashlc_string_free(url) };
        }
    }

    #[test]
    fn a_bad_envelope_is_an_error() {
        let host = "ohttp-gateway-testnet.example";
        for json in [&b"not json"[..], b"{}", b""] {
            zcashlc_clear_last_error();
            let key = unsafe {
                zcashlc_ohttp_verify_key_config(
                    IOS,
                    host.as_ptr(),
                    host.len(),
                    json.as_ptr(),
                    json.len(),
                    1_700_000_000,
                )
            };
            assert!(key.is_null());
            assert!(zcashlc_last_error_length() > 0);
        }
        zcashlc_clear_last_error();
    }

    #[test]
    fn every_attempt_is_sealed_afresh() {
        let key = gateway_key();
        let (first, first_body) = take_opener(seal(b"/x", &key));
        let (second, second_body) = take_opener(seal(b"/x", &key));
        // The gateway key id leads the message; the ephemeral key and the ciphertext differ.
        assert_eq!(first_body[0], 7);
        assert_eq!(second_body[0], 7);
        assert_ne!(first_body, second_body);
        unsafe {
            zcashlc_ohttp_opener_free(first);
            zcashlc_ohttp_opener_free(second);
        }
    }

    #[test]
    fn encapsulate_refuses_a_malformed_key_and_a_malformed_header_list() {
        zcashlc_clear_last_error();
        assert!(
            unsafe {
                zcashlc_ohttp_encapsulate(
                    IOS,
                    ptr::null(),
                    ptr::null(),
                    0,
                    ptr::null(),
                    0,
                    ptr::null(),
                    0,
                    ptr::null(),
                    0,
                    ptr::null(),
                    0,
                    ptr::null(),
                    0,
                )
            }
            .is_null()
        );
        assert!(zcashlc_last_error_length() > 0);
        zcashlc_clear_last_error();

        let key = gateway_key();
        let truncated = [0, 0, 0, 9, b'x'];
        assert!(
            unsafe {
                zcashlc_ohttp_encapsulate(
                    IOS,
                    key.as_ptr(),
                    b"GET".as_ptr(),
                    3,
                    b"https".as_ptr(),
                    5,
                    b"gateway.example".as_ptr(),
                    15,
                    b"/".as_ptr(),
                    1,
                    truncated.as_ptr(),
                    truncated.len(),
                    ptr::null(),
                    0,
                )
            }
            .is_null()
        );
        assert!(zcashlc_last_error_length() > 0);
        zcashlc_clear_last_error();
    }

    #[test]
    fn an_outer_400_or_422_is_retried_once_whatever_the_body() {
        let key = gateway_key();
        for status in [400, 422] {
            let (opener, _) = take_opener(seal(b"/x", &key));
            let outcome = complete(opener, status, b"anything", 0);
            assert!(!outcome.is_null());
            assert_eq!(unsafe { &*outcome }.kind, OUTCOME_REFETCH_KEY);
            unsafe { zcashlc_free_ohttp_outcome(outcome) };

            // The second one is permanent.
            let (opener, _) = take_opener(seal(b"/x", &key));
            let outcome = complete(opener, status, b"still no", 1);
            assert!(!outcome.is_null());
            let outcome_ref = unsafe { &*outcome };
            assert_eq!(outcome_ref.kind, OUTCOME_REFUSED);
            assert_eq!(outcome_ref.status, status);
            assert_eq!(detail(outcome_ref), "still no");
            unsafe { zcashlc_free_ohttp_outcome(outcome) };
        }
    }

    #[test]
    fn a_409_is_never_retried_and_the_detail_is_cut_at_the_window() {
        let key = gateway_key();
        let (opener, _) = take_opener(seal(b"/x", &key));
        let body = vec![b'a'; 300];
        let outcome = complete(opener, 409, &body, 0);
        assert!(!outcome.is_null());
        let outcome_ref = unsafe { &*outcome };
        assert_eq!(outcome_ref.kind, OUTCOME_REFUSED);
        assert_eq!(outcome_ref.status, 409);
        assert_eq!(detail(outcome_ref).len(), 200);
        unsafe { zcashlc_free_ohttp_outcome(outcome) };
    }

    #[test]
    fn a_sealed_answer_that_does_not_open_is_an_error_and_the_opener_is_consumed() {
        let key = gateway_key();
        for body in [vec![], vec![0u8; 31], vec![0u8; 64]] {
            zcashlc_clear_last_error();
            let (opener, _) = take_opener(seal(b"/x", &key));
            let outcome = complete(opener, 200, &body, 0);
            assert!(outcome.is_null());
            assert!(zcashlc_last_error_length() > 0);
        }
        zcashlc_clear_last_error();
    }

    #[test]
    fn a_request_over_the_cap_is_too_large_before_it_is_sealed() {
        use zodl_ohttp_client::Limits;

        zcashlc_clear_last_error();
        let key = gateway_key();
        let body = vec![0u8; 10 * 1024 * 1024];
        let headers = pack_fields(&[(b"x-test".to_vec(), b"1".to_vec())]).unwrap();
        let sealed = unsafe {
            zcashlc_ohttp_encapsulate(
                IOS,
                key.as_ptr(),
                b"POST".as_ptr(),
                4,
                b"https".as_ptr(),
                5,
                b"gateway.example".as_ptr(),
                15,
                b"/large".as_ptr(),
                6,
                headers.as_ptr(),
                headers.len(),
                body.as_ptr(),
                body.len(),
            )
        };
        assert!(sealed.is_null());
        assert!(zcashlc_last_error_length() > 0);
        assert_eq!(Limits::IOS.max_sealed_request_bytes, Some(10 * 1024 * 1024));
        zcashlc_clear_last_error();
    }

    #[test]
    fn a_missing_opener_is_an_error() {
        zcashlc_clear_last_error();
        assert!(complete(ptr::null_mut(), 200, b"", 0).is_null());
        assert!(zcashlc_last_error_length() > 0);
        zcashlc_clear_last_error();
    }
}
