//! Opt-in real Tor/FFI tests: cargo test tor::http::network_tests -- --ignored --nocapture
//!
//! TOR_HTTP_TEST_BASE_URL defaults to https://httpbin.org and must supply /get.
//! TOR_HTTP_TEST_BODY_URL defaults to /drip?numbytes=32&duration=10&delay=0.
//! It must immediately flush successful headers, then stream for longer than 4 seconds.
//! TOR_HTTP_TEST_RETRY_URL is required for the retry test: a publicly reachable HTTPS
//! endpoint with a normally trusted certificate (or HTTP), reachable from Tor exits.
//! On the first request wait 3 seconds, then close without response headers; on subsequent
//! requests keep the transport open without headers for at least 10 seconds. State
//! should be unique to this test run (for example a fresh URL token). HTTP 500 does
//! not meet this contract because the production retry filter retries errors only.
//! TOR_HTTP_TEST_ERROR_PAGE_URL defaults to /drip?numbytes=1000000&code=429&duration=20&delay=0.
//! It must answer a non-2xx status with a body well past 64 KiB, spread over the duration.
//!
//! The Rust test harness has no dynamic skip result. A TOR STAGE-SKIP diagnostic
//! means prerequisite unavailable, not passed live coverage, even if harness says ok.

use std::{
    cell::RefCell,
    ffi::{CStr, CString},
    os::unix::ffi::OsStrExt,
    ptr,
    sync::{Arc, Mutex, mpsc},
    time::{Duration, Instant},
};

use crate::{ffi, tor::TorRuntime};

#[derive(Default)]
struct Stages {
    retry_errors: usize,
    body_entries: usize,
    status: Option<u16>,
    first_retry_at: Option<Instant>,
    /// The bound the production collector chose when it entered, i.e. with the status the retry
    /// filter had recorded by then (`SeenStatus`).
    body_limit: Option<usize>,
}

// block_on polls this pipeline on the FFI caller thread. Per-thread counters avoid
// attributing unrelated unit-test traffic to a live request. No production API.
thread_local! {
    static STAGES: RefCell<Option<Stages>> = const { RefCell::new(None) };
}

pub(crate) fn observe_retry(result: Result<u16, ()>) {
    STAGES.with_borrow_mut(|stages| {
        if let Some(stages) = stages {
            stages.retry_errors += usize::from(result.is_err());
            if result.is_err() {
                stages.first_retry_at.get_or_insert_with(Instant::now);
            }
            stages.status = result.ok();
        }
    });
}

pub(crate) fn observe_body(max_bytes: usize) {
    STAGES.with_borrow_mut(|stages| {
        if let Some(stages) = stages {
            stages.body_entries += 1;
            stages.body_limit = Some(max_bytes);
        }
    });
}

struct NativeFixture {
    runtime: *mut TorRuntime,
    _directory: tempfile::TempDir,
}

impl NativeFixture {
    fn prepare() -> Result<Self, String> {
        let directory = tempfile::Builder::new()
            .prefix("bounded-tor-native-")
            .tempdir()
            .map_err(|error| error.to_string())?;
        let path = directory.path().as_os_str().as_bytes();
        let runtime = unsafe { crate::zcashlc_create_tor_runtime(path.as_ptr(), path.len()) };
        if runtime.is_null() {
            return Err(last_error());
        }
        Ok(Self {
            runtime,
            _directory: directory,
        })
    }

    fn get(&mut self, url: &str, retries: u8, timeout_ms: u64) -> Result<(), String> {
        self.get_response(url, retries, timeout_ms).map(|_| ())
    }

    /// The real FFI GET; returns the response's status and body length.
    fn get_response(
        &mut self,
        url: &str,
        retries: u8,
        timeout_ms: u64,
    ) -> Result<(u16, usize), String> {
        let url = CString::new(url).expect("fixture URL contains no NUL");
        let headers = ptr::NonNull::<ffi::HttpRequestHeader>::dangling().as_ptr();
        let response = unsafe {
            crate::zcashlc_tor_http_get_with_timeout(
                self.runtime,
                url.as_ptr(),
                headers,
                0,
                retries,
                timeout_ms,
            )
        };
        if response.is_null() {
            // Must remain on the native call's thread, before any other FFI call.
            Err(last_error())
        } else {
            let status_and_body_len = unsafe { &*response }.status_and_body_len();
            unsafe { ffi::zcashlc_free_http_response_bytes(response) };
            Ok(status_and_body_len)
        }
    }
}

impl Drop for NativeFixture {
    fn drop(&mut self) {
        unsafe { crate::zcashlc_free_tor_runtime(self.runtime) };
    }
}

fn last_error() -> String {
    let length = crate::zcashlc_last_error_length();
    if length <= 0 {
        return "native call failed without an error message".to_owned();
    }
    let mut buffer = vec![0; length as usize];
    let copied = unsafe { crate::zcashlc_error_message_utf8(buffer.as_mut_ptr(), length) };
    assert_eq!(copied, length);
    let error = unsafe { CStr::from_ptr(buffer.as_ptr()) }
        .to_string_lossy()
        .into_owned();
    crate::zcashlc_clear_last_error();
    error
}

/// A timed-out constructor keeps its directory and native resources on its own
/// thread until it returns. Never free a handle concurrently with native work.
fn guarded_live_test(test: impl FnOnce(&mut NativeFixture) + Send + 'static) {
    let phase = Arc::new(Mutex::new("bootstrap"));
    let observed_phase = phase.clone();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let mut fixture = match NativeFixture::prepare() {
                Ok(fixture) => fixture,
                Err(error) => {
                    eprintln!("TOR STAGE-SKIP: bootstrap prerequisite: {error}");
                    return;
                }
            };
            *phase.lock().unwrap() = "warmup";
            let base = fixture_base();
            STAGES.with_borrow_mut(|stages| *stages = Some(Stages::default()));
            match fixture.get(&format!("{base}/get"), 0, 30_000) {
                Ok(())
                    if STAGES.with_borrow(|stages| stages.as_ref().unwrap().status)
                        == Some(200) => {}
                result => {
                    eprintln!("TOR STAGE-SKIP: HTTP warmup prerequisite: {result:?}");
                    return;
                }
            }
            eprintln!("TOR STAGE: bootstrap and real FFI HTTP warmup reached");
            *phase.lock().unwrap() = "assertions and cleanup";
            test(&mut fixture);
            drop(fixture);
        }));
        let _ = tx.send(outcome);
    });
    match rx.recv_timeout(Duration::from_secs(100)) {
        Ok(Ok(())) => {}
        Ok(Err(panic)) => std::panic::resume_unwind(panic),
        Err(mpsc::RecvTimeoutError::Timeout) => {
            let phase = *observed_phase.lock().unwrap();
            if phase == "bootstrap" {
                eprintln!(
                    "TOR STAGE-SKIP: bootstrap exceeded 100s; worker retains native resources until return"
                );
            } else {
                panic!(
                    "TOR RUN GUARD: {phase} exceeded 100s; run incomplete, active native resources not freed"
                );
            }
        }
        Err(error) => panic!("native worker ended unexpectedly: {error}"),
    }
}

fn fixture_base() -> String {
    std::env::var("TOR_HTTP_TEST_BASE_URL")
        .unwrap_or_else(|_| "https://httpbin.org".to_owned())
        .trim_end_matches('/')
        .to_owned()
}

// Break caught: moving body collection outside the original native deadline.
#[test]
#[ignore = "requires a live Tor bootstrap and streaming HTTP fixture"]
fn real_ffi_body_collection_shares_original_deadline() {
    guarded_live_test(|fixture| {
        let url = std::env::var("TOR_HTTP_TEST_BODY_URL")
            .unwrap_or_else(|_| format!("{}/drip?numbytes=32&duration=10&delay=0", fixture_base()));
        STAGES.with_borrow_mut(|stages| *stages = Some(Stages::default()));
        let start = Instant::now();
        let result = fixture.get(&url, 0, 4_000);
        let elapsed = start.elapsed();
        let stages = STAGES.with_borrow_mut(|stages| stages.take().unwrap());
        if stages.body_entries == 0 {
            eprintln!(
                "TOR STAGE-SKIP: body collector never entered; elapsed={elapsed:?}, result={result:?}"
            );
            return;
        }
        assert_eq!(stages.body_entries, 1);
        assert_eq!(
            result.expect_err("streaming body must time out"),
            "Tor HTTP request timed out"
        );
        assert!(
            elapsed < Duration::from_secs(10),
            "original 4s budget was extended: {elapsed:?}"
        );
        eprintln!("TOR EVIDENCE: actual FFI body entered, timeout after {elapsed:?}");
    });
}

// Break caught: native retries get fresh full budgets instead of sharing one deadline.
#[test]
#[ignore = "requires live Tor and controlled response-dropping TOR_HTTP_TEST_RETRY_URL"]
fn real_ffi_retry_uses_original_deadline() {
    let Ok(url) = std::env::var("TOR_HTTP_TEST_RETRY_URL") else {
        eprintln!(
            "TOR STAGE-SKIP: TOR_HTTP_TEST_RETRY_URL absent; controlled transport-drop fixture required (see module contract)"
        );
        return;
    };
    guarded_live_test(move |fixture| {
        STAGES.with_borrow_mut(|stages| *stages = Some(Stages::default()));
        let start = Instant::now();
        let result = fixture.get(&url, 3, 5_000);
        let elapsed = start.elapsed();
        let stages = STAGES.with_borrow_mut(|stages| stages.take().unwrap());
        if stages.retry_errors == 0 {
            eprintln!(
                "TOR STAGE-SKIP: retry filter never observed an error; elapsed={elapsed:?}, result={result:?}"
            );
            return;
        }
        let first_retry_elapsed = stages.first_retry_at.unwrap().duration_since(start);
        if first_retry_elapsed < Duration::from_secs(2) {
            eprintln!(
                "TOR STAGE-SKIP: fixture dropped too soon to distinguish a refreshed retry budget: {first_retry_elapsed:?}"
            );
            return;
        }
        assert!(
            stages.retry_errors > 0,
            "must observe a real retry decision before interpreting elapsed time"
        );
        assert_eq!(
            result.expect_err("retried request must time out"),
            "Tor HTTP request timed out"
        );
        assert!(
            elapsed < Duration::from_secs(7),
            "original 5s retry budget was extended: {elapsed:?}"
        );
        eprintln!(
            "TOR EVIDENCE: retry errors={}, timeout after {elapsed:?}",
            stages.retry_errors
        );
    });
}

// Break caught: zcash_client_backend no longer calls the retry filter with the final response's
// status before it hands the body to the collector (the collector would then read an error page
// up to the caller's ceiling). The local transport tests exercise the same guard with the
// crate's call order replayed by hand; this one runs the crate's own `http_request`.
#[test]
#[ignore = "requires a live Tor bootstrap and a large, slow error-page fixture"]
fn real_ffi_error_page_is_cut_at_the_fixed_guard() {
    guarded_live_test(|fixture| {
        let url = std::env::var("TOR_HTTP_TEST_ERROR_PAGE_URL").unwrap_or_else(|_| {
            format!(
                "{}/drip?numbytes=1000000&code=429&duration=20&delay=0",
                fixture_base()
            )
        });
        STAGES.with_borrow_mut(|stages| *stages = Some(Stages::default()));
        let start = Instant::now();
        let result = fixture.get_response(&url, 0, 30_000);
        let elapsed = start.elapsed();
        let stages = STAGES.with_borrow_mut(|stages| stages.take().unwrap());
        // Whatever the fixture answered (a timeout included), a collector that entered did so
        // with the status the retry filter had recorded for that response, and with the bound
        // that status selects. Checked before any skip: this is the regression this test is for.
        if stages.body_entries > 0 {
            assert!(
                stages.status.is_some(),
                "the collector entered before the retry filter saw the final response: {result:?}"
            );
            let expected_bound = match stages.status {
                Some(200..=299) => crate::TOR_HTTP_MAX_RESPONSE_BYTES,
                _ => crate::TOR_HTTP_MAX_ERROR_BODY_BYTES,
            };
            assert_eq!(
                stages.body_limit,
                Some(expected_bound),
                "the collector's bound does not follow the status the filter recorded ({:?})",
                stages.status
            );
        }
        // Fixture availability is read off the FFI result (the response's own status), never
        // off the retry filter: a crate that stopped calling the filter must fail above or below,
        // not skip.
        let (status, body_len) = match result {
            Ok((status, body_len)) if status == 429 => (status, body_len),
            result => {
                eprintln!("TOR STAGE-SKIP: fixture did not answer 429; result={result:?}");
                return;
            }
        };
        assert_eq!(
            stages.status,
            Some(status),
            "the retry filter must have seen the final response's status"
        );
        assert_eq!(stages.body_entries, 1);
        assert_eq!(
            stages.body_limit,
            Some(crate::TOR_HTTP_MAX_ERROR_BODY_BYTES),
            "the collector must enter after the filter recorded the final 429"
        );
        assert_eq!(body_len, 0, "the cut error page comes back empty");
        assert!(
            elapsed < Duration::from_secs(15),
            "the 20 s drip was read to its end instead of stopping at 64 KiB: {elapsed:?}"
        );
        eprintln!("TOR EVIDENCE: real FFI 429 page cut at the guard after {elapsed:?}");
    });
}
