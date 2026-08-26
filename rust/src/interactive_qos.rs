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
//! the 1→0 edge, and an unmatched `end` is a saturating no-op. Workers are
//! recorded once, from the pool's `start_handler`; a thread that registers
//! while a session is already active is only picked up by the next session,
//! which is fine because the pool is fully built during
//! `zcashlc_init_on_load`, long before any proving session can begin.

use std::sync::Mutex;

struct BoostCore {
    workers: Vec<usize>,
    sessions: usize,
    overrides: Vec<usize>,
}

impl BoostCore {
    const fn new() -> Self {
        BoostCore {
            workers: Vec::new(),
            sessions: 0,
            overrides: Vec::new(),
        }
    }

    fn register_worker(&mut self, thread: usize) {
        self.workers.push(thread);
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
    fn end(&mut self, end_override: impl Fn(usize)) -> usize {
        if self.sessions == 0 {
            return 0;
        }
        self.sessions -= 1;
        if self.sessions == 0 {
            for token in self.overrides.drain(..) {
                end_override(token);
            }
        }
        self.sessions
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
    CORE.lock().unwrap().register_worker(thread);
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

/// Release a QoS override token returned by `start_qos_override`.
#[cfg(target_vendor = "apple")]
fn end_qos_override(qos_override: usize) {
    // Function-local for the same reason as `register_current_thread`.
    unsafe extern "C" {
        fn pthread_override_qos_class_end_np(qos_override: usize) -> core::ffi::c_int;
    }
    let _ = unsafe { pthread_override_qos_class_end_np(qos_override) };
}

/// Begin an interactive proving session, boosting every recorded pool worker
/// to USER_INITIATED QoS. Refcounted; pair every call with
/// `zcashlc_proving_interactive_end`.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_proving_interactive_begin() {
    let mut core = CORE.lock().unwrap();
    #[cfg(target_vendor = "apple")]
    core.begin(start_qos_override);
    #[cfg(not(target_vendor = "apple"))]
    core.begin(|_| 0);
}

/// End an interactive proving session. The boost is released when the last
/// outstanding session ends; calling without a matching begin is a no-op.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_proving_interactive_end() {
    let mut core = CORE.lock().unwrap();
    #[cfg(target_vendor = "apple")]
    core.end(end_qos_override);
    #[cfg(not(target_vendor = "apple"))]
    core.end(|_| ());
}

/// Number of interactive proving sessions currently outstanding. Diagnostic
/// and test visibility only.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_proving_interactive_active() -> i32 {
    i32::try_from(CORE.lock().unwrap().active()).unwrap_or(i32::MAX)
}

#[cfg(test)]
mod tests {
    use super::BoostCore;
    use std::cell::RefCell;

    #[test]
    fn begin_boosts_each_worker_once_and_refcounts_sessions() {
        let mut core = BoostCore::new();
        core.register_worker(11);
        core.register_worker(22);

        let started = RefCell::new(Vec::new());
        let start = |worker: usize| {
            started.borrow_mut().push(worker);
            worker + 1000
        };
        assert_eq!(core.begin(&start), 1);
        assert_eq!(core.begin(&start), 2);
        assert_eq!(*started.borrow(), vec![11, 22]);

        let ended = RefCell::new(Vec::new());
        let stop = |token: usize| ended.borrow_mut().push(token);
        assert_eq!(core.end(&stop), 1);
        assert!(ended.borrow().is_empty());
        assert_eq!(core.end(&stop), 0);
        assert_eq!(*ended.borrow(), vec![1011, 1022]);
    }

    #[test]
    fn end_without_begin_is_a_saturating_no_op() {
        let mut core = BoostCore::new();
        core.register_worker(11);

        let stop_calls = RefCell::new(0usize);
        assert_eq!(core.end(|_| { *stop_calls.borrow_mut() += 1 }), 0);
        assert_eq!(*stop_calls.borrow(), 0);
        assert_eq!(core.active(), 0);
    }

    #[test]
    fn failed_override_tokens_are_not_released() {
        let mut core = BoostCore::new();
        core.register_worker(11);
        core.register_worker(22);

        core.begin(|worker| if worker == 11 { 0 } else { 2022 });
        let ended = RefCell::new(Vec::new());
        core.end(|token| ended.borrow_mut().push(token));
        assert_eq!(*ended.borrow(), vec![2022]);
    }

    #[test]
    fn workers_registered_mid_session_join_the_next_session() {
        let mut core = BoostCore::new();
        core.register_worker(11);

        let started = RefCell::new(Vec::new());
        let start = |worker: usize| {
            started.borrow_mut().push(worker);
            worker + 1000
        };
        core.begin(&start);
        core.register_worker(22);
        assert_eq!(*started.borrow(), vec![11]);
        core.end(|_| ());

        core.begin(&start);
        assert_eq!(*started.borrow(), vec![11, 11, 22]);
        core.end(|_| ());
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
