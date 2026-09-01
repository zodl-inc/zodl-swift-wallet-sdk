//! Hand-declared Darwin QoS bindings, shared by the proving-pool setup in
//! `zcashlc_init_on_load` and the interactive proving boost in
//! `interactive_qos`.
//!
//! Hand-declared because libc 0.2 does not export these for Apple targets:
//! `pthread_::qos` is absent from the apple arm of libc's `new/mod.rs`
//! re-export list, and the override API has no libc binding at all. Revisit
//! if libc starts exporting `pthread_::qos`. `pthread_self` and `pthread_t`
//! do come from libc, which types `pthread_t` as `uintptr_t` on BSD/Apple —
//! the thread handles really are integers here, which is what lets the
//! worker vector live in a `static Mutex` without a `Send` workaround.
//!
//! The `/// cbindgen:ignore` on this module's declaration in lib.rs is
//! load-bearing: cbindgen parses item-scope `extern "C"` blocks (regardless
//! of visibility) and re-emits them into the generated zcashlc.h, where they
//! collide with the real <pthread.h> prototypes. The FFI build guard in
//! build.rs fails the build if that suppression ever regresses.
//!
//! QoS class reference:
//! <https://developer.apple.com/documentation/dispatch/dispatchqos/qosclass-swift.enum>
//! (raw values match <sys/qos.h>).

use core::ffi::{c_int, c_uint};

pub use libc::{pthread_self, pthread_t};

/// A user tapped and is actively waiting on the result (0x19 in <sys/qos.h>).
pub const QOS_CLASS_USER_INITIATED: c_uint = 0x19;
/// Ongoing work the user is not blocked on (0x11 in <sys/qos.h>).
pub const QOS_CLASS_UTILITY: c_uint = 0x11;

unsafe extern "C" {
    pub fn pthread_set_qos_class_self_np(qos_class: c_uint, relative_priority: c_int) -> c_int;
    // `pthread_override_t` is an opaque pointer, unlike `pthread_t`; it is
    // carried pointer-width as `usize` so the token vector stays `Send`
    // inside `interactive_qos`'s static Mutex.
    pub fn pthread_override_qos_class_start_np(
        thread: pthread_t,
        qos_class: c_uint,
        relative_priority: c_int,
    ) -> usize;
    pub fn pthread_override_qos_class_end_np(qos_override: usize) -> c_int;
}
