//! Scoped user-initiated QoS boost for the global rayon proving pool.
//!
//! `zcashlc_init_on_load` starts every rayon worker at UTILITY QoS so that
//! background proving (the app-open migration prove sweep, the overnight
//! BGTask path) cannot starve the UI. Voting proofs run on the same pool but
//! are the opposite workload: the user is parked on a progress screen waiting
//! for exactly this computation. These FFI entry points let the Swift layer
//! raise every worker to USER_INITIATED for the duration of an interactive
//! proving session and drop back to UTILITY afterwards, so the sweep's
//! demotion survives untouched outside those windows.
//!
//! Sessions are refcounted: `begin` boosts on the 0→1 edge, `end` releases on
//! the 1→0 edge, and an unmatched `end` is a saturating no-op. While a session
//! is open the boost is pool-wide: every job the pool runs — including any
//! background proving that overlaps the session — executes on boosted workers.
//! Workers are recorded from the pool's `start_handler`; `build_global()` does
//! NOT wait for start handlers, so registration may still be in flight when
//! the first session begins. Registration is therefore self-correcting: a
//! worker that registers while a session is active has its override started
//! immediately and released with everyone else's on the session's last end.

use std::sync::Mutex;

struct BoostCore {
    workers: Vec<usize>,
    sessions: usize,
    overrides: Vec<usize>,
    leaked_overrides: usize,
}

impl BoostCore {
    const fn new() -> Self {
        BoostCore {
            workers: Vec::new(),
            sessions: 0,
            overrides: Vec::new(),
            leaked_overrides: 0,
        }
    }

    fn register_worker(&mut self, thread: usize, start_override: impl Fn(usize) -> usize) {
        self.workers.push(thread);
        if self.sessions > 0 {
            let token = start_override(thread);
            if token != 0 {
                self.overrides.push(token);
            }
        }
    }

    /// Returns the new session count. `start_override` runs once per worker on
    /// the 0→1 edge only; a returned 0 (null token) means the OS rejected the
    /// override for that worker and nothing is stored for release.
    fn begin(&mut self, start_override: impl Fn(usize) -> usize) -> usize {
        self.sessions += 1;
        if self.sessions == 1 {
            self.overrides = self
                .workers
                .iter()
                .map(|&worker| start_override(worker))
                .filter(|&token| token != 0)
                .collect();
        }
        self.sessions
    }

    /// Returns the new session count. `end_override` runs once per stored
    /// token on the 1→0 edge only; an unmatched call is a saturating no-op.
    fn end(&mut self, end_override: impl Fn(usize) -> bool) -> usize {
        if self.sessions == 0 {
            return 0;
        }
        self.sessions -= 1;
        if self.sessions == 0 {
            for token in self.overrides.drain(..) {
                if !end_override(token) {
                    self.leaked_overrides += 1;
                }
            }
        }
        self.sessions
    }

    fn override_count(&self) -> usize {
        self.overrides.len()
    }

    fn worker_count(&self) -> usize {
        self.workers.len()
    }

    fn leaked_override_count(&self) -> usize {
        self.leaked_overrides
    }

    fn active(&self) -> usize {
        self.sessions
    }
}

static CORE: Mutex<BoostCore> = Mutex::new(BoostCore::new());

/// Record the calling thread as a proving-pool worker. Call from the rayon
/// `start_handler` only.
#[cfg(target_vendor = "apple")]
pub(crate) fn register_current_thread() {
    // `pthread_t` is an opaque pointer on Darwin; stored pointer-width and
    // never dereferenced on the Rust side. Declared function-local (as
    // `zcashlc_init_on_load` already does for `pthread_set_qos_class_self_np`
    // in lib.rs) rather than at module scope: a module-scope `pub` extern
    // block here is picked up by cbindgen's header scan and leaks into the
    // generated public C header, where it collides with the system's own
    // <pthread.h> prototype for the same symbol.
    unsafe extern "C" {
        fn pthread_self() -> usize;
    }
    let thread = unsafe { pthread_self() };
    CORE.lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .register_worker(thread, logged_start_override);
}

/// Raise `worker` to USER_INITIATED QoS, returning the override token (0 if
/// the OS rejected the override).
#[cfg(target_vendor = "apple")]
fn start_qos_override(worker: usize) -> usize {
    // Function-local for the same reason as `register_current_thread`.
    unsafe extern "C" {
        fn pthread_override_qos_class_start_np(
            thread: usize,
            qos_class: core::ffi::c_uint,
            relative_priority: core::ffi::c_int,
        ) -> usize;
    }
    const QOS_CLASS_USER_INITIATED: core::ffi::c_uint = 0x19;
    unsafe { pthread_override_qos_class_start_np(worker, QOS_CLASS_USER_INITIATED, 0) }
}

/// Release a QoS override token returned by `start_qos_override`. Returns
/// whether the OS accepted the release; a refused release leaves the worker
/// boosted for the process lifetime.
#[cfg(target_vendor = "apple")]
fn end_qos_override(qos_override: usize) -> bool {
    // Function-local for the same reason as `register_current_thread`.
    unsafe extern "C" {
        fn pthread_override_qos_class_end_np(qos_override: usize) -> core::ffi::c_int;
    }
    unsafe { pthread_override_qos_class_end_np(qos_override) == 0 }
}

/// `start_qos_override` plus a visible failure: a worker the OS refuses to
/// boost would otherwise vanish silently from the session.
#[cfg(target_vendor = "apple")]
fn logged_start_override(worker: usize) -> usize {
    let token = start_qos_override(worker);
    if token == 0 {
        tracing::warn!(worker, "interactive QoS override start rejected by the OS");
    }
    token
}

/// Begin an interactive proving session, boosting every recorded pool worker
/// to USER_INITIATED QoS. Refcounted; pair every call with
/// `zcashlc_proving_interactive_end`.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_proving_interactive_begin() {
    let mut core = CORE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    #[cfg(target_vendor = "apple")]
    {
        let sessions = core.begin(logged_start_override);
        if sessions == 1 {
            tracing::debug!(
                boosted = core.override_count(),
                workers = core.worker_count(),
                "interactive proving boost applied"
            );
        }
    }
    #[cfg(not(target_vendor = "apple"))]
    core.begin(|_| 0);
}

/// End an interactive proving session. The boost is released when the last
/// outstanding session ends; calling without a matching begin is a no-op.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_proving_interactive_end() {
    let mut core = CORE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    #[cfg(target_vendor = "apple")]
    {
        let had_sessions = core.active() > 0;
        let sessions = core.end(|token| {
            let released = end_qos_override(token);
            if !released {
                tracing::warn!(
                    "interactive QoS override release failed; worker stays boosted for process lifetime"
                );
            }
            released
        });
        if had_sessions && sessions == 0 {
            tracing::debug!(
                leaked_total = core.leaked_override_count(),
                "interactive proving boost released"
            );
        }
    }
    #[cfg(not(target_vendor = "apple"))]
    core.end(|_| true);
}

/// Number of interactive proving sessions currently outstanding. Diagnostic
/// and test visibility only.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_proving_interactive_active() -> i32 {
    i32::try_from(
        CORE.lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .active(),
    )
    .unwrap_or(i32::MAX)
}

#[cfg(test)]
mod tests {
    use super::BoostCore;
    use std::cell::RefCell;

    #[test]
    fn begin_boosts_each_worker_once_and_refcounts_sessions() {
        let mut core = BoostCore::new();
        core.register_worker(11, |_| 0);
        core.register_worker(22, |_| 0);

        let started = RefCell::new(Vec::new());
        let start = |worker: usize| {
            started.borrow_mut().push(worker);
            worker + 1000
        };
        assert_eq!(core.begin(&start), 1);
        assert_eq!(core.begin(&start), 2);
        assert_eq!(*started.borrow(), vec![11, 22]);

        let ended = RefCell::new(Vec::new());
        let stop = |token: usize| {
            ended.borrow_mut().push(token);
            true
        };
        assert_eq!(core.end(&stop), 1);
        assert!(ended.borrow().is_empty());
        assert_eq!(core.end(&stop), 0);
        assert_eq!(*ended.borrow(), vec![1011, 1022]);
    }

    #[test]
    fn end_without_begin_is_a_saturating_no_op() {
        let mut core = BoostCore::new();
        core.register_worker(11, |_| 0);

        let stop_calls = RefCell::new(0usize);
        assert_eq!(
            core.end(|_| {
                *stop_calls.borrow_mut() += 1;
                true
            }),
            0
        );
        assert_eq!(*stop_calls.borrow(), 0);
        assert_eq!(core.active(), 0);
    }

    #[test]
    fn failed_override_tokens_are_not_released() {
        let mut core = BoostCore::new();
        core.register_worker(11, |_| 0);
        core.register_worker(22, |_| 0);

        core.begin(|worker| if worker == 11 { 0 } else { 2022 });
        let ended = RefCell::new(Vec::new());
        core.end(|token| {
            ended.borrow_mut().push(token);
            true
        });
        assert_eq!(*ended.borrow(), vec![2022]);
    }

    #[test]
    fn workers_registered_mid_session_are_boosted_immediately() {
        let mut core = BoostCore::new();
        let started = RefCell::new(Vec::new());
        let start = |worker: usize| {
            started.borrow_mut().push(worker);
            worker + 1000
        };
        core.register_worker(11, &start);
        assert!(started.borrow().is_empty());
        core.begin(&start);
        core.register_worker(22, &start);
        assert_eq!(*started.borrow(), vec![11, 22]);

        let ended = RefCell::new(Vec::new());
        core.end(|token| {
            ended.borrow_mut().push(token);
            true
        });
        assert_eq!(*ended.borrow(), vec![1011, 1022]);
    }

    #[test]
    fn failed_release_counts_a_leak_and_keeps_sessions_consistent() {
        let mut core = BoostCore::new();
        core.register_worker(11, |_| 0);
        core.register_worker(22, |_| 0);
        core.begin(|worker| worker + 1000);
        assert_eq!(core.override_count(), 2);
        assert_eq!(core.end(|token| token != 1011), 0);
        assert_eq!(core.leaked_override_count(), 1);
        assert_eq!(core.override_count(), 0);
        assert_eq!(core.active(), 0);
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn qos_override_start_and_end_succeed_on_a_real_thread() {
        unsafe extern "C" {
            fn pthread_self() -> usize;
            fn pthread_override_qos_class_start_np(
                thread: usize,
                qos_class: core::ffi::c_uint,
                relative_priority: core::ffi::c_int,
            ) -> usize;
            fn pthread_override_qos_class_end_np(qos_override: usize) -> core::ffi::c_int;
        }
        const QOS_CLASS_USER_INITIATED: core::ffi::c_uint = 0x19;

        let thread = unsafe { pthread_self() };
        let token =
            unsafe { pthread_override_qos_class_start_np(thread, QOS_CLASS_USER_INITIATED, 0) };
        assert_ne!(token, 0);
        assert_eq!(unsafe { pthread_override_qos_class_end_np(token) }, 0);
    }
}
