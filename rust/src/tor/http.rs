use std::future::Future;

#[cfg(test)]
#[path = "http_transport_tests.rs"]
mod transport_tests;

pub(crate) async fn with_http_timeout<T>(
    timeout_ms: u64,
    operation: impl Future<Output = anyhow::Result<T>>,
) -> anyhow::Result<T> {
    if timeout_ms == 0 {
        anyhow::bail!("Tor HTTP timeout must be positive");
    }

    tokio::time::timeout(std::time::Duration::from_millis(timeout_ms), operation)
        .await
        .map_err(|_| anyhow::anyhow!("Tor HTTP request timed out"))?
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
}
