//! The compiled list of third-party hosts a gateway is taken to carry until its own list was
//! fetched. The installed lists (`ohttp_config.rs`) start from it.
//!
//! The C ABI of the lists (`zcashlc_ohttp_third_party_*`) is here too. The Swift transport asks
//! which authority a host is carried as, reports the gateway's answers, and runs the refresh
//! exchange itself: [`zcashlc_ohttp_third_party_begin_refresh`] hands out a refresh handle with
//! the request to send, and [`zcashlc_ohttp_third_party_finish_refresh`] or
//! [`zcashlc_ohttp_third_party_fail_refresh`] ends it. `is_testnet == false` is mainnet. Every
//! function answers as if nothing were carried while OHTTP is off for the network. No function
//! logs or returns a host list.

use std::ffi::CString;
use std::os::raw::c_char;
use std::panic::AssertUnwindSafe;
use std::ptr;
use std::sync::Arc;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use slipstream_core::ohttp::{
    HostListRefresh, NetworkType, RefreshOutcome, ThirdPartyHostLists, is_unknown_authority,
};
use zodl_ohttp_client::Response;

use crate::ohttp::bytes;
use crate::ohttp_config::installed_third_party_hosts;
use crate::{unwrap_exc_or, unwrap_exc_or_null};

/// The third-party hosts a gateway is taken to carry until its own list was fetched.
pub(crate) const BOOTSTRAP_THIRD_PARTY_HOSTS: &[&str] = &[
    // Vote servers
    "vote.zodl.com",
    "prod.vote-chain-primary.valargroup.org",
    "voting.valargroup.dev",
    "ru.zcash.space",
    "147-182-192-212.sslip.io",
    "134-209-215-69.sslip.io",
    "mnval01.zcash.legends.sh",
    "zvote-1.stardust.rest",
    "zvote.zodl.com",
    "zvote.keplr.app",
    "zvote.zfnd.org",
    "v.ombie.cash",
    "svote.zcashlabs.com",
    "207-180-214-226.sslip.io",
    "vote.atlasstaking.com",
    "zvote.polkachu.com",
    "zvote.cros-nest.net",
    "vote.infra.cypherpunk.com",
    // PIR endpoints (delegation): fail closed through OHTTP when Tor is OFF and
    // the servers are predefined.
    "lb-pir-primary.valargroup.org",
    "lb-pir-backup.valargroup.org",
    "zpir-1.stardust.rest",
];

fn network_of(is_testnet: bool) -> NetworkType {
    if is_testnet {
        NetworkType::Test
    } else {
        NetworkType::Main
    }
}

/// The code `zcashlc_ohttp_third_party_finish_refresh` and `..._fail_refresh` answer.
fn outcome_code(outcome: RefreshOutcome) -> u32 {
    match outcome {
        RefreshOutcome::Updated => 0,
        RefreshOutcome::NotModified => 1,
        RefreshOutcome::Kept(_) => 2,
        _ => 3,
    }
}

/// A refresh of one network's host list that is running: the request to send, and the means to
/// end it. Free it with [`zcashlc_ohttp_third_party_free_refresh`] unless it was finished.
///
/// It keeps the lists it began at, so a configuration installed meanwhile is not touched by it.
pub struct OhttpHostListRefresh {
    lists: Arc<ThirdPartyHostLists>,
    network: NetworkType,
    /// Taken when the refresh ends.
    refresh: Option<HostListRefresh>,
    authority: CString,
    path: CString,
    if_none_match: Option<CString>,
}

impl OhttpHostListRefresh {
    /// Ends the refresh with the gateway's answer, or as failed when there is none.
    fn end(&mut self, response: Option<&Response>) -> RefreshOutcome {
        let Some(refresh) = self.refresh.take() else {
            return RefreshOutcome::Superseded;
        };
        let Some(hosts) = self.lists.hosts(self.network) else {
            return RefreshOutcome::Superseded;
        };
        match response {
            Some(response) => hosts.finish_refresh(refresh, Some(response)),
            None => hosts.fail_refresh(refresh, None),
        }
    }
}

impl Drop for OhttpHostListRefresh {
    /// A refresh that was not finished fails, so that its list is free again.
    fn drop(&mut self) {
        self.end(None);
    }
}

/// The `:authority` to send a request for `host` with, in lower case, when the gateway of the
/// network carries `host`; null when it does not, when OHTTP is off for the network, or when
/// `host` is not UTF-8. The result is freed with `zcashlc_string_free`.
///
/// # Safety
///
/// - `host` must be valid for reads for `host_len` bytes, with an alignment of `1`, or null when
///   the length is zero.
/// - The memory referenced by `host` must not be mutated for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_third_party_carried_authority(
    is_testnet: bool,
    host: *const u8,
    host_len: usize,
) -> *mut c_char {
    let res = catch_panic(|| {
        let host = std::str::from_utf8(unsafe { bytes(host, host_len)? })
            .map_err(|_| anyhow!("the host is not UTF-8"))?;
        let lists = installed_third_party_hosts();
        let authority = lists
            .hosts(network_of(is_testnet))
            .and_then(|hosts| hosts.carried_authority(host));
        Ok(authority
            .and_then(|authority| CString::new(authority).ok())
            .map_or(ptr::null_mut(), CString::into_raw))
    });
    unwrap_exc_or_null(res)
}

/// Whether a refresh of the list is worth running before a host that is not carried is refused.
/// When true, begin a refresh and ask for the authority again before refusing. False when OHTTP
/// is off for the network.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ohttp_third_party_refresh_before_refusing(is_testnet: bool) -> bool {
    let res = catch_panic(|| {
        Ok(installed_third_party_hosts()
            .hosts(network_of(is_testnet))
            .is_some_and(|hosts| hosts.refresh_before_refusing()))
    });
    unwrap_exc_or(res, false)
}

/// Whether a refresh of the list is running. A host that is not carried may be in the list it
/// brings, so a refusal while one runs is temporary. False when OHTTP is off for the network.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ohttp_third_party_is_refreshing(is_testnet: bool) -> bool {
    let res = catch_panic(|| {
        Ok(installed_third_party_hosts()
            .hosts(network_of(is_testnet))
            .is_some_and(|hosts| hosts.is_refreshing()))
    });
    unwrap_exc_or(res, false)
}

/// Reports the gateway's answer to a request for `host`: `status` and `body` of the inner
/// response. Returns true when the answer is `403 unknown authority` for a host of the list
/// held and a refresh was asked for (begin one, and use another server of the service now).
/// False otherwise, and when OHTTP is off for the network.
///
/// # Safety
///
/// - `host` must be valid for reads for `host_len` bytes and `body` for `body_len` bytes, each
///   with an alignment of `1`, or null when the length is zero.
/// - The memory referenced by `host` and `body` must not be mutated for the duration of the
///   call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_third_party_note_answer(
    is_testnet: bool,
    host: *const u8,
    host_len: usize,
    status: u16,
    body: *const u8,
    body_len: usize,
) -> bool {
    let res = catch_panic(|| {
        let host = std::str::from_utf8(unsafe { bytes(host, host_len)? })
            .map_err(|_| anyhow!("the host is not UTF-8"))?;
        let body = unsafe { bytes(body, body_len)? };
        let response = Response {
            status,
            headers: Vec::new(),
            body: body.to_vec(),
        };
        if !is_unknown_authority(&response) {
            return Ok(false);
        }
        Ok(installed_third_party_hosts()
            .hosts(network_of(is_testnet))
            .is_some_and(|hosts| hosts.report_unknown_authority(host)))
    });
    unwrap_exc_or(res, false)
}

/// Begins a refresh of the list when one is due, and returns its handle: the request to send is
/// read with the `zcashlc_ohttp_third_party_refresh_*` accessors. Null when none is due, when one
/// is running, or when OHTTP is off for the network. The handle is ended with
/// [`zcashlc_ohttp_third_party_finish_refresh`] or [`zcashlc_ohttp_third_party_fail_refresh`], or
/// freed with [`zcashlc_ohttp_third_party_free_refresh`].
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ohttp_third_party_begin_refresh(
    is_testnet: bool,
) -> *mut OhttpHostListRefresh {
    let res = catch_panic(|| {
        let network = network_of(is_testnet);
        let lists = installed_third_party_hosts();
        let Some(hosts) = lists.hosts(network) else {
            return Ok(ptr::null_mut());
        };
        let Some(gateway_host) = lists.gateway_host(network).map(str::to_owned) else {
            return Ok(ptr::null_mut());
        };
        let Some(refresh) = hosts.begin_refresh() else {
            return Ok(ptr::null_mut());
        };
        let request = refresh.request(&gateway_host);
        let handle = OhttpHostListRefresh {
            authority: CString::new(request.authority)?,
            path: CString::new(request.path)?,
            if_none_match: request
                .headers
                .iter()
                .find(|(name, _)| name.eq_ignore_ascii_case("if-none-match"))
                .map(|(_, value)| CString::new(value.as_str()))
                .transpose()?,
            lists: Arc::clone(&lists),
            network,
            refresh: Some(refresh),
        };
        Ok(Box::into_raw(Box::new(handle)))
    });
    unwrap_exc_or_null(res)
}

/// The `:authority` of the refresh request: the gateway's own host. Null for a null handle. The
/// pointer is borrowed from the handle and is valid until the handle is ended or freed.
///
/// # Safety
///
/// - `refresh` must be null or a pointer returned by [`zcashlc_ohttp_third_party_begin_refresh`]
///   that has not been ended or freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_third_party_refresh_authority(
    refresh: *const OhttpHostListRefresh,
) -> *const c_char {
    match unsafe { refresh.as_ref() } {
        Some(refresh) => refresh.authority.as_ptr(),
        None => ptr::null(),
    }
}

/// The path of the refresh request. Null for a null handle. The pointer is borrowed from the
/// handle and is valid until the handle is ended or freed.
///
/// # Safety
///
/// - `refresh` must be null or a pointer returned by [`zcashlc_ohttp_third_party_begin_refresh`]
///   that has not been ended or freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_third_party_refresh_path(
    refresh: *const OhttpHostListRefresh,
) -> *const c_char {
    match unsafe { refresh.as_ref() } {
        Some(refresh) => refresh.path.as_ptr(),
        None => ptr::null(),
    }
}

/// The `if-none-match` header value of the refresh request, quoted as it is sent. Null when the
/// request carries none, and for a null handle. The pointer is borrowed from the handle and is
/// valid until the handle is ended or freed.
///
/// # Safety
///
/// - `refresh` must be null or a pointer returned by [`zcashlc_ohttp_third_party_begin_refresh`]
///   that has not been ended or freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_third_party_refresh_if_none_match(
    refresh: *const OhttpHostListRefresh,
) -> *const c_char {
    match unsafe { refresh.as_ref() } {
        Some(refresh) => refresh
            .if_none_match
            .as_ref()
            .map_or(ptr::null(), |value| value.as_ptr()),
        None => ptr::null(),
    }
}

/// Ends the refresh with the gateway's answer, `status` and `body` of the inner response, and
/// consumes the handle. Returns 0 when the list was replaced, 1 when the gateway confirmed the
/// list held, 2 when the list held was kept (and a backoff began), and 3 when nothing was
/// changed (a null handle, or a refresh that was superseded).
///
/// # Safety
///
/// - `refresh` must be null or a pointer returned by [`zcashlc_ohttp_third_party_begin_refresh`]
///   that has not been ended or freed; it must not be used after the call.
/// - `body` must be valid for reads for `body_len` bytes, with an alignment of `1`, or null when
///   the length is zero.
/// - The memory referenced by `body` must not be mutated for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_third_party_finish_refresh(
    refresh: *mut OhttpHostListRefresh,
    status: u16,
    body: *const u8,
    body_len: usize,
) -> u32 {
    if refresh.is_null() {
        return 3;
    }
    let mut refresh = unsafe { Box::from_raw(refresh) };
    let res = catch_panic(AssertUnwindSafe(|| {
        // A body that cannot be read fails the refresh, as an exchange that failed would.
        let response = unsafe { bytes(body, body_len) }.ok().map(|body| Response {
            status,
            headers: Vec::new(),
            body: body.to_vec(),
        });
        Ok(outcome_code(refresh.end(response.as_ref())))
    }));
    unwrap_exc_or(res, 3)
}

/// Ends the refresh as failed (the exchange failed or was given up) and consumes the handle: the
/// list held is kept and a backoff begins. Returns 2, or 3 for a null handle or a refresh that
/// was superseded.
///
/// # Safety
///
/// - `refresh` must be null or a pointer returned by [`zcashlc_ohttp_third_party_begin_refresh`]
///   that has not been ended or freed; it must not be used after the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_third_party_fail_refresh(
    refresh: *mut OhttpHostListRefresh,
) -> u32 {
    if refresh.is_null() {
        return 3;
    }
    let mut refresh = unsafe { Box::from_raw(refresh) };
    let res = catch_panic(AssertUnwindSafe(|| Ok(outcome_code(refresh.end(None)))));
    unwrap_exc_or(res, 3)
}

/// Frees a refresh handle. A refresh that was not ended counts as failed.
///
/// # Safety
///
/// - `refresh` must be null or a pointer returned by [`zcashlc_ohttp_third_party_begin_refresh`]
///   that has not been ended or freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_third_party_free_refresh(
    refresh: *mut OhttpHostListRefresh,
) {
    if !refresh.is_null() {
        drop(unsafe { Box::from_raw(refresh) });
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::CStr;

    use slipstream_core::ohttp::NoHostList;

    use super::*;
    use crate::ohttp_config::{example, install_for_test, lock_installed_networks};
    use crate::zcashlc_string_free;
    use zodl_ohttp_client::OhttpNetworks;

    fn carried(is_testnet: bool, host: &str) -> Option<String> {
        let ptr = unsafe {
            zcashlc_ohttp_third_party_carried_authority(is_testnet, host.as_ptr(), host.len())
        };
        if ptr.is_null() {
            return None;
        }
        let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
        unsafe { zcashlc_string_free(ptr) };
        Some(text)
    }

    fn list_body(hosts: &[&str]) -> Vec<u8> {
        let entries: Vec<String> = hosts
            .iter()
            .map(|host| format!(r#"{{"host":"{host}","routes":["*"]}}"#))
            .collect();
        format!(
            r#"{{"version":1,"revision":"r1","scope":"all","max_age_secs":3600,"hosts":[{}]}}"#,
            entries.join(",")
        )
        .into_bytes()
    }

    fn begin(is_testnet: bool) -> *mut OhttpHostListRefresh {
        zcashlc_ohttp_third_party_begin_refresh(is_testnet)
    }

    fn finish(handle: *mut OhttpHostListRefresh, status: u16, body: &[u8]) -> u32 {
        unsafe {
            zcashlc_ohttp_third_party_finish_refresh(handle, status, body.as_ptr(), body.len())
        }
    }

    fn note(is_testnet: bool, host: &str, status: u16, body: &[u8]) -> bool {
        unsafe {
            zcashlc_ohttp_third_party_note_answer(
                is_testnet,
                host.as_ptr(),
                host.len(),
                status,
                body.as_ptr(),
                body.len(),
            )
        }
    }

    fn text(ptr: *const c_char) -> Option<String> {
        (!ptr.is_null()).then(|| unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned())
    }

    /// Installs the example configuration and a list that carries `vote.example.org` on mainnet.
    fn install_list_with_example_host() {
        install_for_test(example::networks());
        let handle = begin(false);
        assert!(!handle.is_null());
        assert_eq!(finish(handle, 200, &list_body(&["vote.example.org"])), 0);
    }

    #[test]
    fn a_bootstrap_host_is_carried_in_lower_case() {
        let _guard = lock_installed_networks();
        install_for_test(example::networks());
        assert_eq!(
            carried(false, "VOTE.ZODL.COM").as_deref(),
            Some("vote.zodl.com")
        );
        assert_eq!(
            carried(true, "VOTE.ZODL.COM").as_deref(),
            Some("vote.zodl.com")
        );
        assert_eq!(carried(false, "unknown.example.org"), None);
        assert_eq!(carried(false, ""), None);
    }

    #[test]
    fn ohttp_off_answers_nothing() {
        let _guard = lock_installed_networks();
        install_for_test(OhttpNetworks::default());
        assert_eq!(carried(false, "vote.zodl.com"), None);
        assert!(begin(false).is_null());
        assert!(!zcashlc_ohttp_third_party_refresh_before_refusing(false));
        assert!(!zcashlc_ohttp_third_party_is_refreshing(false));
        assert!(!note(false, "vote.zodl.com", 403, b"unknown authority"));
    }

    #[test]
    fn a_refresh_asks_the_gateway_and_installs_the_list() {
        let _guard = lock_installed_networks();
        install_for_test(example::networks());
        assert!(zcashlc_ohttp_third_party_refresh_before_refusing(false));
        let handle = begin(false);
        assert!(!handle.is_null());
        unsafe {
            assert_eq!(
                text(zcashlc_ohttp_third_party_refresh_authority(handle)).as_deref(),
                Some(example::MAINNET.gateway_host)
            );
            assert_eq!(
                text(zcashlc_ohttp_third_party_refresh_path(handle)).as_deref(),
                Some("/ohttp-gateway/v1/third-party-hosts")
            );
            assert!(zcashlc_ohttp_third_party_refresh_if_none_match(handle).is_null());
        }
        assert!(zcashlc_ohttp_third_party_is_refreshing(false));
        assert!(begin(false).is_null());

        assert_eq!(finish(handle, 200, &list_body(&["vote.example.org"])), 0);
        assert!(carried(false, "vote.example.org").is_some());
        assert_eq!(carried(false, "vote.zodl.com"), None);
        assert!(carried(true, "vote.zodl.com").is_some());
        assert!(!zcashlc_ohttp_third_party_is_refreshing(false));
        assert!(begin(false).is_null());
        assert!(!zcashlc_ohttp_third_party_refresh_before_refusing(false));
    }

    #[test]
    fn a_failed_refresh_keeps_the_bootstrap_and_backs_off() {
        let _guard = lock_installed_networks();
        install_for_test(example::networks());
        let handle = begin(false);
        assert!(!handle.is_null());
        assert_eq!(unsafe { zcashlc_ohttp_third_party_fail_refresh(handle) }, 2);
        assert!(carried(false, "vote.zodl.com").is_some());
        assert!(begin(false).is_null());

        install_for_test(example::networks());
        let handle = begin(false);
        assert!(!handle.is_null());
        assert_eq!(finish(handle, 404, b""), 2);
    }

    #[test]
    fn a_freed_handle_fails_its_refresh() {
        let _guard = lock_installed_networks();
        install_for_test(example::networks());
        let handle = begin(false);
        assert!(!handle.is_null());
        unsafe { zcashlc_ohttp_third_party_free_refresh(handle) };
        assert!(!zcashlc_ohttp_third_party_is_refreshing(false));
        assert!(begin(false).is_null());
    }

    #[test]
    fn an_unknown_authority_answer_for_a_listed_host_asks_for_a_refresh() {
        let _guard = lock_installed_networks();
        install_list_with_example_host();
        assert!(note(false, "vote.example.org", 403, b"unknown authority"));
        assert!(!note(false, "vote.example.org", 403, b"unknown authority"));
        let handle = begin(false);
        assert!(!handle.is_null());
        assert_eq!(unsafe { zcashlc_ohttp_third_party_fail_refresh(handle) }, 2);
        assert!(!note(false, "vote.example.org", 200, b"unknown authority"));
        assert!(!note(false, "other.example.org", 403, b"unknown authority"));
    }

    #[test]
    fn a_refresh_finished_after_reconfiguration_does_not_touch_the_new_lists() {
        let _guard = lock_installed_networks();
        install_for_test(example::networks());
        let handle = begin(false);
        assert!(!handle.is_null());
        install_for_test(example::networks());
        finish(handle, 200, &list_body(&["vote.example.org"]));
        assert_eq!(carried(false, "vote.example.org"), None);
        assert!(carried(false, "vote.zodl.com").is_some());
    }

    #[test]
    fn null_handles_are_refused_quietly() {
        unsafe {
            assert_eq!(
                zcashlc_ohttp_third_party_finish_refresh(ptr::null_mut(), 200, ptr::null(), 0),
                3
            );
            assert_eq!(zcashlc_ohttp_third_party_fail_refresh(ptr::null_mut()), 3);
            zcashlc_ohttp_third_party_free_refresh(ptr::null_mut());
            assert!(zcashlc_ohttp_third_party_refresh_authority(ptr::null()).is_null());
            assert!(zcashlc_ohttp_third_party_refresh_path(ptr::null()).is_null());
            assert!(zcashlc_ohttp_third_party_refresh_if_none_match(ptr::null()).is_null());
        }
    }

    #[test]
    fn outcome_codes() {
        assert_eq!(outcome_code(RefreshOutcome::Updated), 0);
        assert_eq!(outcome_code(RefreshOutcome::NotModified), 1);
        assert_eq!(outcome_code(RefreshOutcome::Kept(None)), 2);
        assert_eq!(
            outcome_code(RefreshOutcome::Kept(Some(NoHostList::TooLarge))),
            2
        );
        assert_eq!(outcome_code(RefreshOutcome::Superseded), 3);
        assert_eq!(outcome_code(RefreshOutcome::NotDue), 3);
        assert_eq!(outcome_code(RefreshOutcome::Running), 3);
    }

    #[test]
    fn the_bootstrap_list_is_21_plain_lower_case_hosts() {
        assert_eq!(BOOTSTRAP_THIRD_PARTY_HOSTS.len(), 21);
        let holder = slipstream_core::ohttp::ThirdPartyHosts::new(BOOTSTRAP_THIRD_PARTY_HOSTS);
        assert_eq!(holder.bootstrap_len(), 21);
        for host in BOOTSTRAP_THIRD_PARTY_HOSTS {
            assert_eq!(holder.carried_authority(host).as_deref(), Some(*host));
            assert!(!host.contains(':'));
        }
        assert!(!holder.is_carried("evil.vote.zodl.com"));
        assert!(!holder.is_carried("valargroup.org"));
    }
}
