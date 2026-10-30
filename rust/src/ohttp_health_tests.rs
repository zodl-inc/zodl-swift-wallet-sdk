//! The C bridge must preserve native evidence and synchronously fence borrowed callbacks.
use crate::ohttp_health::*;
use slipstream_core::transport_health::{
    self, HealthOutcome, HealthRoute, HealthScope, HealthStage,
};
use std::ffi::{CString, c_void};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::Duration;

unsafe extern "C" fn ignore(
    _: *const FfiOHTTPHealthObservationV1,
    _: usize,
    _: u64,
    _: u64,
    _: *mut c_void,
) {
}

fn route() -> HealthRoute {
    HealthRoute {
        gateway_host: format!("{}.test", uuid::Uuid::new_v4()),
        relay_url: "https://relay.test/".into(),
        via_tor: false,
    }
}

#[test]
fn ohttp_health_rejects_null_and_invalid_inputs() {
    let gateway = CString::new("gateway.test").unwrap();
    let relay = CString::new("https://relay.test/").unwrap();
    unsafe {
        assert!(
            zcashlc_ohttp_health_subscribe_v1(
                std::ptr::null(),
                relay.as_ptr(),
                false,
                1,
                Some(ignore),
                std::ptr::null_mut()
            )
            .is_null()
        );
        assert!(
            zcashlc_ohttp_health_subscribe_v1(
                gateway.as_ptr(),
                relay.as_ptr(),
                false,
                0,
                Some(ignore),
                std::ptr::null_mut()
            )
            .is_null()
        );
        assert!(
            zcashlc_ohttp_health_subscribe_v1(
                gateway.as_ptr(),
                relay.as_ptr(),
                false,
                1,
                None,
                std::ptr::null_mut()
            )
            .is_null()
        );
        assert_eq!(
            zcashlc_ohttp_health_snapshot_v1(
                std::ptr::null(),
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut()
            ),
            usize::MAX
        );
        zcashlc_ohttp_health_unsubscribe_v1(std::ptr::null_mut());
    }
}

#[test]
fn ohttp_health_snapshot_preserves_history_and_never_partially_copies() {
    let route = route();
    let request = transport_health::begin_request(&route, HealthScope::Lightwalletd);
    request.record(HealthOutcome::TransportUnavailable, HealthStage::Connection);
    request.record(HealthOutcome::Usable, HealthStage::Complete);
    let gateway = CString::new(route.gateway_host).unwrap();
    let relay = CString::new(route.relay_url).unwrap();
    unsafe {
        let subscription = zcashlc_ohttp_health_subscribe_v1(
            gateway.as_ptr(),
            relay.as_ptr(),
            false,
            91,
            Some(ignore),
            std::ptr::null_mut(),
        );
        assert!(!subscription.is_null());
        let mut version = 0;
        let mut generation = 0;
        let mut output = [FfiOHTTPHealthObservationV1::default(); 63];
        output[0].request_id = 123456;
        assert_eq!(
            zcashlc_ohttp_health_snapshot_v1(
                subscription,
                output.as_mut_ptr(),
                1,
                &mut version,
                &mut generation
            ),
            2
        );
        assert_eq!(output[0].request_id, 123456);
        assert_eq!(
            zcashlc_ohttp_health_snapshot_v1(
                subscription,
                output.as_mut_ptr(),
                63,
                &mut version,
                &mut generation
            ),
            2
        );
        assert_eq!(generation, 91);
        assert!(version > 0);
        assert_eq!(output[0].scope, 1);
        assert_eq!(output[0].outcome, 1);
        assert_eq!(output[1].outcome, 0);
        assert!(output[..2].iter().all(|entry| entry.historical
            && entry.generation == 0
            && entry.request_id == request.request_id()));
        zcashlc_ohttp_health_unsubscribe_v1(subscription);
    }
}

struct CallbackState {
    entered: mpsc::Sender<()>,
    release: (Mutex<bool>, Condvar),
    copied: Mutex<Vec<FfiOHTTPHealthObservationV1>>,
}
unsafe extern "C" fn blocked_callback(
    entries: *const FfiOHTTPHealthObservationV1,
    count: usize,
    _: u64,
    _: u64,
    context: *mut c_void,
) {
    let state = unsafe { &*context.cast::<CallbackState>() };
    *state.copied.lock().unwrap() = unsafe { std::slice::from_raw_parts(entries, count) }.to_vec();
    state.entered.send(()).unwrap();
    let mut release = state.release.0.lock().unwrap();
    while !*release {
        release = state.release.1.wait(release).unwrap();
    }
}

#[test]
fn ohttp_health_unsubscribe_waits_for_active_callback_and_coalesces_over_64_events() {
    let route = route();
    let gateway = CString::new(route.gateway_host.clone()).unwrap();
    let relay = CString::new(route.relay_url.clone()).unwrap();
    let (entered, receiver) = mpsc::channel();
    let state = Arc::new(CallbackState {
        entered,
        release: (Mutex::new(false), Condvar::new()),
        copied: Mutex::new(Vec::new()),
    });
    unsafe {
        let subscription = zcashlc_ohttp_health_subscribe_v1(
            gateway.as_ptr(),
            relay.as_ptr(),
            false,
            17,
            Some(blocked_callback),
            Arc::as_ptr(&state).cast_mut().cast(),
        );
        transport_health::begin_request(&route, HealthScope::Route)
            .record(HealthOutcome::TransportUnavailable, HealthStage::Connection);
        receiver.recv_timeout(Duration::from_secs(3)).unwrap();
        for _ in 0..100 {
            transport_health::begin_request(&route, HealthScope::Route)
                .record(HealthOutcome::Usable, HealthStage::Complete);
        }
        let mut output = [FfiOHTTPHealthObservationV1::default(); 63];
        let mut version = 0;
        let mut generation = 0;
        assert_eq!(
            zcashlc_ohttp_health_snapshot_v1(
                subscription,
                output.as_mut_ptr(),
                63,
                &mut version,
                &mut generation
            ),
            2
        );
        assert!(output[1].version > output[0].version + 64);
        let pointer = subscription as usize;
        let (finished, completion) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            zcashlc_ohttp_health_unsubscribe_v1(pointer as *mut OHTTPHealthSubscription);
            finished.send(()).unwrap();
        });
        assert!(completion.recv_timeout(Duration::from_millis(30)).is_err());
        *state.release.0.lock().unwrap() = true;
        state.release.1.notify_all();
        completion.recv_timeout(Duration::from_secs(3)).unwrap();
        worker.join().unwrap();
        assert_eq!(state.copied.lock().unwrap()[0].generation, 17);
    }
}

#[test]
fn ohttp_health_mapping_keeps_all_outcomes_and_operation_identity() {
    use transport_health::{HealthObservation, HealthOperation, HealthPurpose, HealthSource};
    let outcomes = [
        HealthOutcome::Usable,
        HealthOutcome::TransportUnavailable,
        HealthOutcome::BackendUnavailable,
        HealthOutcome::RateLimited {
            retry_not_before_nanoseconds: 900,
        },
        HealthOutcome::PolicyRejected,
        HealthOutcome::ConfigurationFailure,
        HealthOutcome::ResponseRejected,
        HealthOutcome::Cancelled,
        HealthOutcome::Inconclusive,
    ];
    for (tag, outcome) in outcomes.into_iter().enumerate() {
        let observation = HealthObservation {
            source: HealthSource::Native,
            route: route(),
            scope: HealthScope::ExchangeRates,
            outcome,
            stage: HealthStage::ResponseBody,
            generation: 17,
            version: 19,
            request_id: 23,
            started_at_nanoseconds: 100,
            observed_at_nanoseconds: 300,
            operation: Some(HealthOperation {
                id: [42; 16],
                started_at_nanoseconds: 75,
            }),
            purpose: HealthPurpose::UserOperation,
            historical: true,
        };
        let output = FfiOHTTPHealthObservationV1::from(&observation);
        assert_eq!(output.outcome, tag as u32);
        assert_eq!(
            output.retry_not_before_nanoseconds,
            if tag == 3 { 900 } else { 0 }
        );
        assert_eq!(output.scope, 2);
        assert_eq!(output.stage, 3);
        assert_eq!(output.purpose, 1);
        assert_eq!(output.operation_id, [42; 16]);
        assert_eq!(output.operation_started_at_nanoseconds, 75);
        assert_eq!(output.generation, 17);
        assert_eq!(output.version, 19);
        assert!(output.has_operation && output.historical);
    }
}

#[test]
fn ohttp_health_callback_can_unsubscribe_itself() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    struct Context {
        pointer: AtomicUsize,
        finished: mpsc::Sender<()>,
    }
    unsafe extern "C" fn callback(
        _: *const FfiOHTTPHealthObservationV1,
        _: usize,
        _: u64,
        _: u64,
        context: *mut c_void,
    ) {
        let context = unsafe { &*context.cast::<Context>() };
        let pointer = context.pointer.load(Ordering::Acquire);
        let finished = context.finished.clone();
        assert_ne!(pointer, 0);
        unsafe { zcashlc_ohttp_health_unsubscribe_v1(pointer as *mut OHTTPHealthSubscription) };
        finished.send(()).unwrap();
    }
    let route = route();
    let gateway = CString::new(route.gateway_host.clone()).unwrap();
    let relay = CString::new(route.relay_url.clone()).unwrap();
    let (finished, receiver) = mpsc::channel();
    let context = Context {
        pointer: AtomicUsize::new(0),
        finished,
    };
    unsafe {
        let subscription = zcashlc_ohttp_health_subscribe_v1(
            gateway.as_ptr(),
            relay.as_ptr(),
            false,
            29,
            Some(callback),
            (&context as *const Context).cast_mut().cast(),
        );
        assert!(!subscription.is_null());
        context
            .pointer
            .store(subscription as usize, Ordering::Release);
    }
    transport_health::begin_request(&route, HealthScope::Route)
        .record(HealthOutcome::Usable, HealthStage::Complete);
    receiver.recv_timeout(Duration::from_secs(3)).unwrap();
    // No callback can be started after self-retirement, including already queued evidence.
    transport_health::begin_request(&route, HealthScope::Route)
        .record(HealthOutcome::TransportUnavailable, HealthStage::Connection);
    assert!(receiver.recv_timeout(Duration::from_millis(30)).is_err());
}
