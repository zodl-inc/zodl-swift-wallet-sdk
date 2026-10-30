//! Additive, engine-independent retained health subscription ABI.
use slipstream_core::transport_health::{
    self as health, HealthOutcome, HealthPurpose, HealthScope, HealthStage,
};
use std::ffi::{CStr, c_char, c_void};
use std::sync::Arc;

/// Fixed-layout local evidence. Enum tags are zero-based in the documented order.
/// UUID bytes and all correlation fields are local only, never HTTP headers.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct FfiOHTTPHealthObservationV1 {
    pub generation: u64,
    pub version: u64,
    pub request_id: u64,
    pub started_at_nanoseconds: u64,
    pub observed_at_nanoseconds: u64,
    pub retry_not_before_nanoseconds: u64,
    pub operation_started_at_nanoseconds: u64,
    pub operation_id: [u8; 16],
    /// Route, lightwalletd, exchange rates, swaps, voting, Flexa, other.
    pub scope: u32,
    /// Usable, transport unavailable, backend unavailable, rate limited, policy
    /// rejected, configuration failure, response rejected, cancelled, inconclusive.
    pub outcome: u32,
    /// Connection, key configuration, response head, response body, complete.
    pub stage: u32,
    /// Background, user operation, diagnostic.
    pub purpose: u32,
    pub has_operation: bool,
    pub historical: bool,
}

impl From<&health::HealthObservation> for FfiOHTTPHealthObservationV1 {
    fn from(value: &health::HealthObservation) -> Self {
        Self {
            generation: value.generation,
            version: value.version,
            request_id: value.request_id,
            started_at_nanoseconds: value.started_at_nanoseconds,
            observed_at_nanoseconds: value.observed_at_nanoseconds,
            retry_not_before_nanoseconds: match value.outcome {
                HealthOutcome::RateLimited {
                    retry_not_before_nanoseconds,
                } => retry_not_before_nanoseconds,
                _ => 0,
            },
            operation_started_at_nanoseconds: value
                .operation
                .map_or(0, |operation| operation.started_at_nanoseconds),
            operation_id: value.operation.map_or([0; 16], |operation| operation.id),
            scope: match value.scope {
                HealthScope::Route => 0,
                HealthScope::Lightwalletd => 1,
                HealthScope::ExchangeRates => 2,
                HealthScope::Swaps => 3,
                HealthScope::Voting => 4,
                HealthScope::Flexa => 5,
                HealthScope::Other => 6,
            },
            outcome: match value.outcome {
                HealthOutcome::Usable => 0,
                HealthOutcome::TransportUnavailable => 1,
                HealthOutcome::BackendUnavailable => 2,
                HealthOutcome::RateLimited { .. } => 3,
                HealthOutcome::PolicyRejected => 4,
                HealthOutcome::ConfigurationFailure => 5,
                HealthOutcome::ResponseRejected => 6,
                HealthOutcome::Cancelled => 7,
                HealthOutcome::Inconclusive => 8,
            },
            stage: match value.stage {
                HealthStage::Connection => 0,
                HealthStage::KeyConfiguration => 1,
                HealthStage::ResponseHead => 2,
                HealthStage::ResponseBody => 3,
                HealthStage::Complete => 4,
            },
            purpose: match value.purpose {
                HealthPurpose::Background => 0,
                HealthPurpose::UserOperation => 1,
                HealthPurpose::Diagnostic => 2,
            },
            has_operation: value.operation.is_some(),
            historical: value.historical,
        }
    }
}

/// Opaque subscription, independent of any wallet or engine handle.
pub struct OHTTPHealthSubscription {
    inner: health::HealthSubscription,
}

/// The observations are borrowed only until this callback returns. The callback
/// runs on a dedicated native worker and must not unwind across the C boundary.
pub type OHTTPHealthCallbackV1 = Option<
    unsafe extern "C" fn(
        observations: *const FfiOHTTPHealthObservationV1,
        count: usize,
        version: u64,
        generation: u64,
        context: *mut c_void,
    ),
>;

#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_ohttp_health_api_version() -> u32 {
    1
}

/// Subscribes to an exact configured route; no network request is performed.
/// Returns null for missing/invalid strings, zero generation, or absent callback.
///
/// # Safety
/// Strings must be valid NUL-terminated buffers. `context` must remain live until
/// unsubscribe has fenced callbacks. Copy all borrowed observations in callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_health_subscribe_v1(
    gateway: *const c_char,
    relay: *const c_char,
    via_tor: bool,
    generation: u64,
    callback: OHTTPHealthCallbackV1,
    context: *mut c_void,
) -> *mut OHTTPHealthSubscription {
    if gateway.is_null() || relay.is_null() || generation == 0 {
        return std::ptr::null_mut();
    }
    let Some(callback) = callback else {
        return std::ptr::null_mut();
    };
    let (Ok(gateway), Ok(relay)) = (
        unsafe { CStr::from_ptr(gateway) }.to_str(),
        unsafe { CStr::from_ptr(relay) }.to_str(),
    ) else {
        return std::ptr::null_mut();
    };
    if gateway.is_empty() || relay.is_empty() {
        return std::ptr::null_mut();
    }
    let route = health::HealthRoute {
        gateway_host: gateway.to_owned(),
        relay_url: relay.to_owned(),
        via_tor,
    };
    // The caller owns the opaque context; its lifetime is protected by the subscription fence.
    let context = context as usize;
    let inner = health::subscribe(
        route,
        generation,
        Arc::new(move |snapshot| {
            let observations: Vec<_> = snapshot
                .observations
                .iter()
                .map(FfiOHTTPHealthObservationV1::from)
                .collect();
            unsafe {
                callback(
                    observations.as_ptr(),
                    observations.len(),
                    snapshot.version,
                    snapshot.generation,
                    context as *mut c_void,
                )
            };
        }),
    );
    Box::into_raw(Box::new(OHTTPHealthSubscription { inner }))
}

/// Copies an atomic snapshot. Returns the required element count (at most 63),
/// or SIZE_MAX on invalid arguments. Insufficient capacity never partially copies.
/// `version` and `generation` are optional outputs, including for sizing calls.
///
/// # Safety
/// The subscription must be live and must not be unsubscribed concurrently.
/// Non-null output pointers must be writable, with `capacity` entries in `output`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_health_snapshot_v1(
    subscription: *const OHTTPHealthSubscription,
    output: *mut FfiOHTTPHealthObservationV1,
    capacity: usize,
    version: *mut u64,
    generation: *mut u64,
) -> usize {
    let Some(subscription) = (unsafe { subscription.as_ref() }) else {
        return usize::MAX;
    };
    if output.is_null() && capacity != 0 {
        return usize::MAX;
    }
    let snapshot = subscription.inner.snapshot();
    if !version.is_null() {
        unsafe { *version = snapshot.version };
    }
    if !generation.is_null() {
        unsafe { *generation = snapshot.generation };
    }
    let count = snapshot.observations.len();
    if capacity >= count && !output.is_null() {
        for (index, entry) in snapshot.observations.iter().enumerate() {
            unsafe {
                output
                    .add(index)
                    .write(FfiOHTTPHealthObservationV1::from(entry))
            };
        }
    }
    count
}

/// Synchronously fences callbacks and frees the subscription. Null is a no-op.
/// When invoked inside its own callback, retires future callbacks; the current
/// callback may return normally. Never hold a callback-required lock while closing.
///
/// # Safety
/// A non-null pointer must be an unfreed result of subscribe. The caller must
/// serialize unsubscribe against snapshot access and all other unsubscribe calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_ohttp_health_unsubscribe_v1(
    subscription: *mut OHTTPHealthSubscription,
) {
    if !subscription.is_null() {
        drop(unsafe { Box::from_raw(subscription) });
    }
}
