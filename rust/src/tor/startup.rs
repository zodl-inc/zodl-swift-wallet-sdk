//! Owned, cancellable Tor creation. The worker is always joined before job destruction.
use std::{
    future::Future,
    sync::{Arc, Condvar, Mutex},
    thread::JoinHandle,
    time::Instant,
};
use tokio::sync::watch;
use tor_rtcompat::{PreferredRuntime, ToplevelBlockOn};

pub(crate) const PENDING: u32 = 0;
pub(crate) const READY: u32 = 1;
pub(crate) const FAILED: u32 = 2;
pub(crate) const TIMED_OUT: u32 = 3;
pub(crate) const CANCELLED: u32 = 4;
pub(crate) const TAKEN: u32 = ZCASHLC_TOR_STARTUP_TAKEN;
pub(crate) const INVALID: u32 = 6;

struct State<T> {
    status: u32,
    value: Option<T>,
    finished: bool,
}
struct Shared<T> {
    state: Mutex<State<T>>,
    finished: Condvar,
}

pub(crate) struct StartupJob<T> {
    shared: Arc<Shared<T>>,
    cancel: watch::Sender<bool>,
    worker: Option<JoinHandle<()>>,
}

impl<T: Send + 'static> StartupJob<T> {
    pub(crate) fn begin<F, Fut>(deadline: Instant, create: F) -> Self
    where
        F: FnOnce(PreferredRuntime) -> Fut + Send + 'static,
        Fut: Future<Output = Result<T, ()>>,
    {
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                status: PENDING,
                value: None,
                finished: false,
            }),
            finished: Condvar::new(),
        });
        let (cancel, mut cancelled) = watch::channel(false);
        let output = Arc::clone(&shared);
        let worker = std::thread::Builder::new().name("tor-startup".into()).spawn(move || {
            let mut result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                if *cancelled.borrow() { return (CANCELLED, None); }
                if Instant::now() >= deadline { return (TIMED_OUT, None); }
                let Ok(runtime) = PreferredRuntime::create() else { return (FAILED, None); };
                runtime.block_on(async {
                    // Construct only inside the selected branch so expired work never starts.
                    tokio::select! {
                        biased;
                        _ = cancelled.changed() => (CANCELLED, None),
                        _ = tokio::time::sleep_until(tokio::time::Instant::from_std(deadline)) => (TIMED_OUT, None),
                        result = async { create(runtime.clone()).await } => {
                            if Instant::now() >= deadline { (TIMED_OUT, None) }
                            else { match result { Ok(value) => (READY, Some(value)), Err(()) => (FAILED, None) } }
                        }
                    }
                })
            })).unwrap_or((FAILED, None));
            let mut state = output.state.lock().unwrap_or_else(|p| p.into_inner());
            if state.status == PENDING {
                state.status = result.0;
                state.value = result.1.take();
            }
            drop(result);
            // The future and any unclaimed result are dropped before wait returns.
            state.finished = true;
            output.finished.notify_all();
        });
        let worker = match worker {
            Ok(worker) => Some(worker),
            Err(_) => {
                let mut state = shared.state.lock().unwrap_or_else(|p| p.into_inner());
                state.status = FAILED;
                state.finished = true;
                None
            }
        };
        Self {
            shared,
            cancel,
            worker,
        }
    }
}

impl<T> StartupJob<T> {
    pub(crate) fn cancel(&self) {
        let mut state = self.shared.state.lock().unwrap_or_else(|p| p.into_inner());
        if state.status == PENDING || state.status == READY {
            state.status = CANCELLED;
            state.value.take();
            self.cancel.send_replace(true);
        }
    }

    pub(crate) fn wait(&self) -> u32 {
        let mut state = self.shared.state.lock().unwrap_or_else(|p| p.into_inner());
        while !state.finished {
            state = self
                .shared
                .finished
                .wait(state)
                .unwrap_or_else(|p| p.into_inner());
        }
        state.status
    }

    pub(crate) fn take(&self) -> (u32, Option<T>) {
        let mut state = self.shared.state.lock().unwrap_or_else(|p| p.into_inner());
        if state.status == READY && state.finished {
            let value = state.value.take();
            state.status = TAKEN;
            (READY, value)
        } else {
            (
                if state.finished {
                    state.status
                } else {
                    PENDING
                },
                None,
            )
        }
    }
}

impl<T> Drop for StartupJob<T> {
    fn drop(&mut self) {
        self.cancel();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

/// Opaque startup owner. Cancel/wait/take use shared borrows and may run concurrently.
pub struct FfiTorStartupJob {
    pub(crate) job: StartupJob<super::TorRuntime>,
}

/// Startup status: pending (0), ready (1), failed (2), timed out (3), cancelled (4),
/// already taken (5), invalid/null argument (6). These are Tor failures, never OHTTP evidence.
pub const ZCASHLC_TOR_STARTUP_PENDING: u32 = 0;
pub const ZCASHLC_TOR_STARTUP_READY: u32 = 1;
pub const ZCASHLC_TOR_STARTUP_FAILED: u32 = 2;
pub const ZCASHLC_TOR_STARTUP_TIMED_OUT: u32 = 3;
pub const ZCASHLC_TOR_STARTUP_CANCELLED: u32 = 4;
pub const ZCASHLC_TOR_STARTUP_TAKEN: u32 = 5;
pub const ZCASHLC_TOR_STARTUP_INVALID: u32 = 6;

/// Owned result transfer. Only READY carries a runtime; release it with zcashlc_free_tor_runtime.
#[repr(C)]
pub struct FfiTorStartupResultV1 {
    pub status: u32,
    pub runtime: *mut super::TorRuntime,
}

/// Begin one worker with a deadline established before worker admission. Copies the directory.
/// No thread-local error transport: null means invalid input/budget; other failures live in the job.
/// # Safety
/// Directory must be non-null and readable for tor_dir_len bytes for this call only.
/// Free the returned job exactly once, after all concurrent job calls have returned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_tor_startup_begin_v1(
    tor_dir: *const u8,
    tor_dir_len: usize,
    remaining_ms: u64,
) -> *mut FfiTorStartupJob {
    let now = Instant::now();
    let Some(deadline) = now.checked_add(std::time::Duration::from_millis(remaining_ms)) else {
        return std::ptr::null_mut();
    };
    if tor_dir.is_null() || tor_dir_len == 0 {
        return std::ptr::null_mut();
    }
    std::panic::catch_unwind(|| {
        use std::os::unix::ffi::OsStrExt;
        let dir = std::path::PathBuf::from(std::ffi::OsStr::from_bytes(unsafe {
            std::slice::from_raw_parts(tor_dir, tor_dir_len)
        }));
        let job = StartupJob::begin(deadline, move |runtime| async move {
            let client = zcash_client_backend::tor::Client::create(
                &dir,
                |permissions: &mut fs_mistrust::MistrustBuilder| {
                    if cfg!(target_os = "ios") {
                        permissions.dangerously_trust_everyone();
                    }
                },
            )
            .await
            .map_err(|_| ())?;
            Ok(super::TorRuntime { runtime, client })
        });
        Box::into_raw(Box::new(FfiTorStartupJob { job }))
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Interrupts the actual bootstrap future and discards an unclaimed successful runtime.
/// # Safety
/// Job must be null or live. May race wait/take/cancel, but never free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_tor_startup_cancel_v1(job: *const FfiTorStartupJob) {
    if let Some(job) = unsafe { job.as_ref() } {
        job.job.cancel();
    }
}

/// Blocks until the worker has dropped the bootstrap future and retained its typed result.
/// # Safety
/// Job must be null or live. May race cancel/wait/take, but never free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_tor_startup_wait_v1(job: *const FfiTorStartupJob) -> u32 {
    unsafe { job.as_ref() }.map_or(INVALID, |job| job.job.wait())
}

/// Transfers the successful runtime at most once. Does not block; pending returns PENDING.
/// # Safety
/// Job must be null or live. May race cancel/wait/take, but never free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_tor_startup_take_v1(
    job: *const FfiTorStartupJob,
) -> FfiTorStartupResultV1 {
    let (status, runtime) = unsafe { job.as_ref() }.map_or((INVALID, None), |job| job.job.take());
    FfiTorStartupResultV1 {
        status,
        runtime: runtime.map_or(std::ptr::null_mut(), |runtime| {
            Box::into_raw(Box::new(runtime))
        }),
    }
}

/// Cancels, joins the worker, and releases any unclaimed result before returning.
/// # Safety
/// Job must be null or a live returned pointer; no other call may access it during/after free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_tor_startup_free_v1(job: *mut FfiTorStartupJob) {
    if !job.is_null() {
        drop(unsafe { Box::from_raw(job) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    use std::time::{Duration, Instant};

    struct Resource(Arc<AtomicUsize>);
    impl Drop for Resource {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[test]
    fn tor_startup_cancel_drops_pending_bootstrap_before_wait_returns() {
        let drops = Arc::new(AtomicUsize::new(0));
        let resource = Resource(drops.clone());
        let (admitted, ready) = std::sync::mpsc::channel();
        let job = StartupJob::<Resource>::begin(
            Instant::now() + Duration::from_secs(60),
            move |_| async move {
                let _resource = resource;
                admitted.send(()).unwrap();
                std::future::pending().await
            },
        );
        ready.recv_timeout(Duration::from_secs(2)).unwrap();
        std::thread::scope(|scope| {
            let waiter = scope.spawn(|| job.wait());
            job.cancel();
            assert_eq!(waiter.join().unwrap(), CANCELLED);
        });
        assert_eq!(drops.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn tor_startup_deadline_includes_worker_admission() {
        let job = StartupJob::<()>::begin(Instant::now(), |_| async {
            panic!("expired work admitted")
        });
        assert_eq!(job.wait(), TIMED_OUT);
    }

    #[test]
    fn tor_startup_pending_deadline_drops_future() {
        let drops = Arc::new(AtomicUsize::new(0));
        let resource = Resource(drops.clone());
        let job = StartupJob::<Resource>::begin(
            Instant::now() + Duration::from_millis(100),
            move |_| async move {
                let _resource = resource;
                std::future::pending().await
            },
        );
        assert_eq!(job.wait(), TIMED_OUT);
        assert_eq!(drops.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn tor_startup_take_transfers_exactly_once_and_survives_cancel() {
        let drops = Arc::new(AtomicUsize::new(0));
        let resource = Resource(drops.clone());
        let job = StartupJob::begin(Instant::now() + Duration::from_secs(2), move |_| async {
            Ok(resource)
        });
        assert_eq!(job.wait(), READY);
        let (status, resource) = job.take();
        assert_eq!(status, READY);
        assert_eq!(job.take().0, TAKEN);
        job.cancel();
        drop(job);
        assert_eq!(drops.load(Ordering::SeqCst), 0);
        drop(resource);
        assert_eq!(drops.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn tor_startup_cancel_success_race_releases_unclaimed_result_once() {
        for _ in 0..30 {
            let drops = Arc::new(AtomicUsize::new(0));
            let resource = Resource(drops.clone());
            let job = StartupJob::begin(Instant::now() + Duration::from_secs(2), move |_| async {
                Ok(resource)
            });
            job.cancel();
            assert_eq!(job.wait(), CANCELLED);
            assert!(job.take().1.is_none());
            drop(job);
            assert_eq!(drops.load(Ordering::SeqCst), 1);
        }
    }

    #[test]
    fn tor_startup_free_before_take_drops_success_once() {
        let drops = Arc::new(AtomicUsize::new(0));
        let resource = Resource(drops.clone());
        let job = StartupJob::begin(Instant::now() + Duration::from_secs(2), move |_| async {
            Ok(resource)
        });
        assert_eq!(job.wait(), READY);
        drop(job);
        assert_eq!(drops.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn tor_startup_failure_is_owned_sanitized_status() {
        let job = StartupJob::<()>::begin(Instant::now() + Duration::from_secs(2), |_| async {
            Err(())
        });
        assert_eq!(job.wait(), FAILED);
        assert_eq!(job.take().0, FAILED);
    }
}
