// The caller guarantees that nonempty input is valid for reads during this call.
pub(crate) unsafe fn post_body(
    body: *const u8,
    length: usize,
) -> http_body_util::Full<bytes::Bytes> {
    // Hyper drives the connection in a detached task that may still be sending
    // after an early response or deadline returns control to the FFI caller.
    // Full clones retain the owned bytes for every backend retry.
    let data = if length == 0 {
        bytes::Bytes::new()
    } else {
        bytes::Bytes::copy_from_slice(unsafe { std::slice::from_raw_parts(body, length) })
    };
    http_body_util::Full::new(data)
}

#[cfg(test)]
#[path = "http_post_body_tests.rs"]
mod post_body_tests;

use std::future::Future;

#[cfg(test)]
#[path = "http_network_tests.rs"]
pub(crate) mod network_tests;

#[cfg(test)]
#[path = "http_transport_tests.rs"]
mod transport_tests;

#[derive(Debug)]
pub(crate) struct HttpDeadline;
impl std::fmt::Display for HttpDeadline {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Tor HTTP request timed out")
    }
}
impl std::error::Error for HttpDeadline {}

pub(crate) async fn with_http_timeout<T>(
    timeout_ms: u64,
    operation: impl Future<Output = anyhow::Result<T>>,
) -> anyhow::Result<T> {
    if timeout_ms == 0 {
        anyhow::bail!("Tor HTTP timeout must be positive");
    }

    tokio::time::timeout(std::time::Duration::from_millis(timeout_ms), operation)
        .await
        .map_err(|_| anyhow::Error::new(HttpDeadline))?
}

#[cfg(test)]
mod tests {
    use std::{
        future::{self, poll_fn},
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        },
        task::Poll,
        time::Duration,
    };

    use bytes::Bytes;

    use super::with_http_timeout;
    use crate::tor::TorRuntime;
    use crate::{
        ffi, zcashlc_clear_last_error, zcashlc_error_message_utf8, zcashlc_last_error_length,
        zcashlc_tor_http_get, zcashlc_tor_http_get_with_timeout, zcashlc_tor_http_post,
        zcashlc_tor_http_post_bounded, zcashlc_tor_http_post_once_bounded,
    };

    struct Dropped(Arc<AtomicBool>);

    impl Drop for Dropped {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    struct PendingBody {
        polled: Arc<AtomicBool>,
        dropped: Arc<AtomicBool>,
    }

    impl PendingBody {
        async fn collect(self) -> Bytes {
            self.polled.store(true, Ordering::SeqCst);
            future::pending().await
        }
    }

    impl Drop for PendingBody {
        fn drop(&mut self) {
            self.dropped.store(true, Ordering::SeqCst);
        }
    }

    fn last_error_message() -> Option<String> {
        let error_len = zcashlc_last_error_length();
        if error_len == 0 {
            return None;
        }

        let mut error = vec![0u8; error_len as usize];
        let copied = unsafe {
            zcashlc_error_message_utf8(error.as_mut_ptr().cast::<std::ffi::c_char>(), error_len)
        };
        assert_eq!(copied, error_len);
        Some(
            unsafe { std::ffi::CStr::from_ptr(error.as_ptr().cast::<std::ffi::c_char>()) }
                .to_str()
                .expect("the native error is UTF-8")
                .to_owned(),
        )
    }

    #[tokio::test(start_paused = true)]
    async fn deadline_drops_a_pending_request() {
        let dropped = Arc::new(AtomicBool::new(false));
        let guard = Dropped(dropped.clone());

        let result: anyhow::Result<()> = with_http_timeout(10, async move {
            let _guard = guard;
            future::pending().await
        })
        .await;

        assert_eq!(
            result
                .expect_err("the pending request must time out")
                .to_string(),
            "Tor HTTP request timed out"
        );
        assert!(dropped.load(Ordering::SeqCst));
    }

    #[tokio::test(start_paused = true)]
    async fn deadline_error_reaches_the_same_thread_native_error_buffer() {
        zcashlc_clear_last_error();
        let timeout_error = with_http_timeout(10, future::pending::<anyhow::Result<()>>())
            .await
            .expect_err("the pending request must time out");

        let result: Result<(), ()> = ffi_helpers::panic::catch_panic(|| Err(timeout_error));

        assert!(result.is_err());
        assert_eq!(
            last_error_message().as_deref(),
            Some("Tor HTTP request timed out")
        );
        zcashlc_clear_last_error();
    }

    #[tokio::test(start_paused = true)]
    async fn deadline_includes_response_body_collection() {
        let headers_received = Arc::new(AtomicBool::new(false));
        let body_polled = Arc::new(AtomicBool::new(false));
        let body_dropped = Arc::new(AtomicBool::new(false));
        let observed_headers = headers_received.clone();
        let observed_body_poll = body_polled.clone();
        let observed_body_drop = body_dropped.clone();

        let result = with_http_timeout(10, async move {
            headers_received.store(true, Ordering::SeqCst);
            let body = PendingBody {
                polled: body_polled,
                dropped: body_dropped,
            };

            anyhow::Ok(body.collect().await)
        })
        .await;

        assert_eq!(
            result
                .expect_err("body collection must share the request deadline")
                .to_string(),
            "Tor HTTP request timed out"
        );
        assert!(observed_headers.load(Ordering::SeqCst));
        assert!(observed_body_poll.load(Ordering::SeqCst));
        assert!(observed_body_drop.load(Ordering::SeqCst));
    }

    #[tokio::test(start_paused = true)]
    async fn operation_completing_before_deadline_succeeds() {
        let result = with_http_timeout(10, async {
            tokio::time::sleep(Duration::from_millis(9)).await;
            anyhow::Ok(Bytes::from_static(b"complete"))
        })
        .await;

        assert_eq!(
            result.expect("the body completes before expiry"),
            b"complete"[..]
        );
    }

    #[tokio::test(start_paused = true)]
    async fn zero_timeout_is_rejected_without_polling_the_operation() {
        let polled = Arc::new(AtomicBool::new(false));
        let observed_poll = polled.clone();
        let operation = poll_fn(move |_cx| {
            polled.store(true, Ordering::SeqCst);
            Poll::Ready(anyhow::Ok(()))
        });

        let result = with_http_timeout(0, operation).await;

        assert_eq!(
            result
                .expect_err("a zero timeout must be rejected")
                .to_string(),
            "Tor HTTP timeout must be positive"
        );
        assert!(!observed_poll.load(Ordering::SeqCst));
    }

    #[test]
    fn ffi_signatures_keep_legacy_get_and_post_compatible() {
        let _legacy_get: unsafe extern "C" fn(
            *mut TorRuntime,
            *const std::ffi::c_char,
            *const ffi::HttpRequestHeader,
            usize,
            u8,
        ) -> *mut ffi::HttpResponseBytes = zcashlc_tor_http_get;
        let _bounded_get: unsafe extern "C" fn(
            *mut TorRuntime,
            *const std::ffi::c_char,
            *const ffi::HttpRequestHeader,
            usize,
            u8,
            u64,
        ) -> *mut ffi::HttpResponseBytes = zcashlc_tor_http_get_with_timeout;
        let _legacy_post: unsafe extern "C" fn(
            *mut TorRuntime,
            *const std::ffi::c_char,
            *const ffi::HttpRequestHeader,
            usize,
            *const u8,
            usize,
            u8,
        ) -> *mut ffi::HttpResponseBytes = zcashlc_tor_http_post;
        let _bounded_post: unsafe extern "C" fn(
            *mut TorRuntime,
            *const std::ffi::c_char,
            *const ffi::HttpRequestHeader,
            usize,
            *const u8,
            usize,
            u8,
            usize,
        ) -> *mut ffi::HttpResponseBytes = zcashlc_tor_http_post_bounded;
        let _post_once: unsafe extern "C" fn(
            *mut TorRuntime,
            *const std::ffi::c_char,
            *const ffi::HttpRequestHeader,
            usize,
            *const u8,
            usize,
            usize,
        ) -> *mut ffi::HttpResponseBytes = zcashlc_tor_http_post_once_bounded;
    }

    #[test]
    fn bounded_get_rejects_zero_through_the_same_thread_error_buffer() {
        zcashlc_clear_last_error();
        let url = std::ffi::CString::new("https://example.com").expect("the URL contains no NUL");
        let headers = std::ptr::NonNull::<ffi::HttpRequestHeader>::dangling().as_ptr();

        let response = unsafe {
            zcashlc_tor_http_get_with_timeout(std::ptr::null_mut(), url.as_ptr(), headers, 0, 0, 0)
        };

        assert!(response.is_null());
        assert_eq!(
            last_error_message().as_deref(),
            Some("Tor HTTP timeout must be positive")
        );
        zcashlc_clear_last_error();
    }
    #[tokio::test(start_paused = true)]
    async fn classified_post_deadline_drops_body_and_retains_rejection() {
        use http_body_util::StreamBody;
        for status in [200, 403, 413, 426, 429] {
            let dropped = Arc::new(AtomicBool::new(false));
            let owner = Dropped(dropped.clone());
            let body = StreamBody::new(futures::stream::poll_fn(move |_| {
                let _ = &owner;
                Poll::<
                    Option<
                        Result<
                            hyper::body::Frame<Bytes>,
                            zcash_client_backend::tor::http::HttpError,
                        >,
                    >,
                >::Pending
            }));
            let (result, outcome) = crate::tor_http_classified_response(
                1024,
                10,
                crate::retry_if_unsent,
                |guard| async move {
                    assert!(
                        guard
                            .filter(Ok(http::StatusCode::from_u16(status).unwrap()))
                            .is_none()
                    );
                    Ok(http::Response::builder()
                        .status(status)
                        .header("Retry-After", "17")
                        .body(crate::TorHttpGetBody::Incoming(body))
                        .unwrap())
                },
            )
            .await;
            assert!(result.is_err());
            assert_eq!(outcome.kind, 1);
            assert_eq!(outcome.http_status, status);
            assert!(outcome.retry_not_before_ns > 0 || status != 429);
            assert!(dropped.load(Ordering::SeqCst));
        }
    }

    #[tokio::test]
    async fn classified_requests_distinguish_transport_from_configuration() {
        use http_body_util::Empty;
        use zcash_client_backend::tor::{Error, http::HttpError};
        for (error, kind) in [
            (Error::Http(HttpError::NonHttpUrl), 3),
            (Error::Io(std::io::Error::other("unreachable")), 2),
        ] {
            let (result, outcome) = crate::tor_http_classified_response(
                1024,
                20,
                crate::retry_if_unsent,
                |_| async move {
                    Err::<
                        http::Response<
                            crate::TorHttpGetBody<
                                http_body_util::combinators::MapErr<
                                    Empty<Bytes>,
                                    fn(std::convert::Infallible) -> HttpError,
                                >,
                            >,
                        >,
                        _,
                    >(error)
                },
            )
            .await;
            assert!(result.is_err());
            assert_eq!(outcome.kind, kind);
        }
    }

    #[test]
    fn classified_ffi_rejects_invalid_budget_without_runtime_or_dispatch() {
        let mut outcome = crate::FfiTorHttpOutcome::default();
        let result = unsafe {
            crate::zcashlc_tor_http_post_once_with_timeout(
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                1024,
                0,
                &mut outcome,
            )
        };
        assert!(result.is_null());
        assert_eq!(outcome.kind, 3);
        let result = unsafe {
            crate::zcashlc_tor_http_get_classified_with_timeout(
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                0,
                1024,
                0,
                &mut outcome,
            )
        };
        assert!(result.is_null());
        assert_eq!(outcome.kind, 3);
    }

    #[tokio::test]
    async fn classified_pause_is_anchored_before_body_failure() {
        use futures::StreamExt;
        use http_body_util::StreamBody;
        use std::sync::atomic::AtomicU64;
        for delay in [1u64, 120] {
            let head_time = Arc::new(AtomicU64::new(0));
            let captured = head_time.clone();
            let (result, outcome) = crate::tor_http_classified_response(
                1024,
                100,
                crate::retry_if_unsent,
                |guard| async move {
                    guard.filter(Ok(http::StatusCode::TOO_MANY_REQUESTS));
                    captured.store(
                        guard.status.observed_at_ns.load(Ordering::Relaxed),
                        Ordering::Relaxed,
                    );
                    let body = StreamBody::new(
                        futures::stream::once(async {
                            tokio::time::sleep(Duration::from_millis(20)).await;
                            Err::<hyper::body::Frame<Bytes>, _>(
                                zcash_client_backend::tor::http::HttpError::Timeout(
                                    zcash_client_backend::tor::http::TimeoutPhase::ResponseBody,
                                ),
                            )
                        })
                        .boxed(),
                    );
                    Ok(http::Response::builder()
                        .status(429)
                        .header("Retry-After", delay)
                        .body(crate::TorHttpGetBody::Incoming(body))
                        .unwrap())
                },
            )
            .await;
            assert!(result.is_err());
            assert_eq!(
                outcome.retry_not_before_ns,
                head_time.load(Ordering::Relaxed) + delay * 1_000_000_000
            );
        }
    }

    #[tokio::test(start_paused = true)]
    async fn legacy_pause_and_body_deadline_start_at_parser_admission() {
        use futures::StreamExt;
        use http_body_util::StreamBody;
        use std::sync::atomic::AtomicU64;
        for fail in [false, true] {
            let head_time = Arc::new(AtomicU64::new(0));
            let captured = head_time.clone();
            let start = tokio::time::Instant::now();
            let result = crate::tor_http_get_response(
                1024,
                None,
                crate::retry_if_unsent,
                |guard, explicit| async move {
                    guard.filter(Ok(http::StatusCode::TOO_MANY_REQUESTS));
                    captured.store(
                        guard.status.observed_at_ns.load(Ordering::Relaxed),
                        Ordering::Relaxed,
                    );
                    let body = StreamBody::new(
                        futures::stream::once(async move {
                            tokio::time::sleep(Duration::from_secs(if fail { 2 } else { 90 }))
                                .await;
                            Err::<hyper::body::Frame<Bytes>, _>(
                                zcash_client_backend::tor::http::HttpError::Timeout(
                                    zcash_client_backend::tor::http::TimeoutPhase::ResponseBody,
                                ),
                            )
                        })
                        .boxed(),
                    );
                    let parsed = guard.parse_get(body, explicit).await?;
                    tokio::time::sleep(Duration::from_secs(10)).await;
                    Ok(http::Response::builder()
                        .status(429)
                        .header("Retry-After", "120")
                        .body(parsed)
                        .unwrap())
                },
            )
            .await;
            assert!(result.is_err());
            assert_eq!(
                crate::zcashlc_tor_http_last_outcome().retry_not_before_ns,
                head_time.load(Ordering::Relaxed) + 120_000_000_000
            );
            assert_eq!(
                tokio::time::Instant::now() - start,
                Duration::from_secs(if fail { 12 } else { 60 })
            );
            assert!(matches!(
                result
                    .unwrap_err()
                    .downcast_ref::<zcash_client_backend::tor::Error>(),
                Some(zcash_client_backend::tor::Error::Http(
                    zcash_client_backend::tor::http::HttpError::Timeout(
                        zcash_client_backend::tor::http::TimeoutPhase::ResponseBody
                    )
                ))
            ));
        }
    }

    #[test]
    fn legacy_http_outcome_is_reset_and_thread_local() {
        crate::set_tor_http_outcome(crate::FfiTorHttpOutcome {
            kind: 2,
            ..Default::default()
        });
        assert_eq!(crate::zcashlc_tor_http_last_outcome().kind, 2);
        let other = std::thread::spawn(|| crate::zcashlc_tor_http_last_outcome().kind)
            .join()
            .unwrap();
        assert_eq!(other, 5);
        let url = std::ffi::CString::new("https://example.com").unwrap();
        let headers = std::ptr::NonNull::<ffi::HttpRequestHeader>::dangling().as_ptr();
        let result = unsafe {
            crate::zcashlc_tor_http_post_once_bounded(
                std::ptr::null_mut(),
                url.as_ptr(),
                headers,
                0,
                std::ptr::NonNull::<u8>::dangling().as_ptr(),
                0,
                1,
            )
        };
        assert!(result.is_null());
        assert_eq!(crate::zcashlc_tor_http_last_outcome().kind, 3);
    }
}
