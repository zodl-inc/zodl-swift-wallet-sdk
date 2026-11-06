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

#[test]
fn ohttp_health_copies_all_126_entries_without_partial_writes_and_fences_callbacks() {
    use transport_health::HealthPurpose;
    unsafe extern "C" fn copy_callback(
        entries: *const FfiOHTTPHealthObservationV1,
        count: usize,
        _: u64,
        _: u64,
        context: *mut c_void,
    ) {
        let sender = unsafe { &*context.cast::<mpsc::Sender<Vec<FfiOHTTPHealthObservationV1>>>() };
        sender
            .send(unsafe { std::slice::from_raw_parts(entries, count) }.to_vec())
            .unwrap();
    }
    let route = route();
    for scope in [
        HealthScope::Route,
        HealthScope::Lightwalletd,
        HealthScope::ExchangeRates,
        HealthScope::Swaps,
        HealthScope::Voting,
        HealthScope::Flexa,
        HealthScope::Other,
    ] {
        for outcome in [
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
        ] {
            for purpose in [HealthPurpose::Background, HealthPurpose::Diagnostic] {
                transport_health::begin_request(&route, scope)
                    .with_context(purpose, None)
                    .record(outcome, HealthStage::Complete);
            }
        }
    }
    let gateway = CString::new(route.gateway_host.clone()).unwrap();
    let relay = CString::new(route.relay_url.clone()).unwrap();
    let (sender, receiver) = mpsc::channel::<Vec<FfiOHTTPHealthObservationV1>>();
    let mut short = [FfiOHTTPHealthObservationV1::default(); 63];
    for entry in &mut short {
        entry.request_id = 123456;
    }
    let mut full = [FfiOHTTPHealthObservationV1::default(); 126];
    let mut version = 0;
    let mut generation = 0;
    let (required, short_required, full_required, callback);
    unsafe {
        let subscription = zcashlc_ohttp_health_subscribe_v1(
            gateway.as_ptr(),
            relay.as_ptr(),
            false,
            91,
            Some(copy_callback),
            (&sender as *const mpsc::Sender<Vec<FfiOHTTPHealthObservationV1>>)
                .cast_mut()
                .cast(),
        );
        assert!(!subscription.is_null());
        required = zcashlc_ohttp_health_snapshot_v1(
            subscription,
            std::ptr::null_mut(),
            0,
            &mut version,
            &mut generation,
        );
        short_required = zcashlc_ohttp_health_snapshot_v1(
            subscription,
            short.as_mut_ptr(),
            63,
            &mut version,
            &mut generation,
        );
        full_required = zcashlc_ohttp_health_snapshot_v1(
            subscription,
            full.as_mut_ptr(),
            126,
            &mut version,
            &mut generation,
        );
        callback = receiver.recv_timeout(Duration::from_secs(3)).unwrap();
        zcashlc_ohttp_health_unsubscribe_v1(subscription);
    }
    transport_health::begin_request(&route, HealthScope::Route)
        .record(HealthOutcome::Usable, HealthStage::Complete);
    assert!(
        receiver.try_recv().is_err(),
        "retired C callback must not restart"
    );
    assert_eq!(
        required, 126,
        "native bound must cross the actual C sizing export"
    );
    assert_eq!(short_required, 126);
    assert!(
        short.iter().all(|entry| entry.request_id == 123456),
        "short capacity must never partially copy"
    );
    assert_eq!(full_required, 126);
    assert_eq!(callback.len(), 126);
    assert_eq!(generation, 91);
    assert!(version > 0);
    assert!(
        full.iter()
            .all(|entry| entry.historical && entry.generation == 0 && entry.request_id != 0)
    );
    for (copied, notified) in full.iter().zip(callback.iter()) {
        assert_eq!(copied.request_id, notified.request_id);
        assert_eq!(copied.version, notified.version);
        assert_eq!(
            copied.started_at_nanoseconds,
            notified.started_at_nanoseconds
        );
        assert_eq!(
            copied.observed_at_nanoseconds,
            notified.observed_at_nanoseconds
        );
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

#[test]
fn subscription_construction_panic_returns_null() {
    use std::sync::atomic::{AtomicUsize, Ordering};

    unsafe extern "C" fn callback(
        _: *const FfiOHTTPHealthObservationV1,
        _: usize,
        _: u64,
        _: u64,
        context: *mut c_void,
    ) {
        unsafe { &*context.cast::<AtomicUsize>() }.fetch_add(1, Ordering::SeqCst);
    }

    let gateway = CString::new("gateway.test").unwrap();
    let relay = CString::new("https://relay.test/").unwrap();
    let context = Arc::new(AtomicUsize::new(0));
    let retained_notification = Mutex::new(None);
    let result = std::panic::catch_unwind(|| unsafe {
        subscribe_with_constructor(
            gateway.as_ptr(),
            relay.as_ptr(),
            false,
            43,
            Some(callback),
            Arc::as_ptr(&context).cast_mut().cast(),
            |_, _, notify| {
                *retained_notification.lock().unwrap() = Some(Arc::downgrade(&notify));
                panic!("could not start OHTTP health notification worker");
            },
        )
    });
    assert!(
        result.is_ok(),
        "construction must not unwind out of the Rust FFI implementation"
    );
    assert!(result.unwrap().is_null());
    assert_eq!(
        retained_notification
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .strong_count(),
        0
    );
    assert_eq!(context.load(Ordering::SeqCst), 0);
    assert_eq!(
        Arc::strong_count(&context),
        1,
        "the context remains exclusively caller-owned"
    );
    let weak_context = Arc::downgrade(&context);
    drop(context);
    assert!(weak_context.upgrade().is_none());
    assert!(
        ffi_helpers::error_handling::take_last_error()
            .unwrap()
            .to_string()
            .contains("could not start OHTTP health notification worker")
    );
}

#[test]
fn normal_subscription_still_fences_callbacks() {
    unsafe extern "C" fn callback(
        _: *const FfiOHTTPHealthObservationV1,
        _: usize,
        _: u64,
        generation: u64,
        context: *mut c_void,
    ) {
        let sender = unsafe { &*context.cast::<mpsc::Sender<u64>>() };
        let _ = sender.send(generation);
    }

    let route = route();
    let gateway = CString::new(route.gateway_host.clone()).unwrap();
    let relay = CString::new(route.relay_url.clone()).unwrap();
    let (sender, receiver) = mpsc::channel::<u64>();
    let subscription = unsafe {
        subscribe_with_constructor(
            gateway.as_ptr(),
            relay.as_ptr(),
            false,
            47,
            Some(callback),
            (&sender as *const mpsc::Sender<u64>).cast_mut().cast(),
            transport_health::subscribe,
        )
    };
    assert!(!subscription.is_null());
    transport_health::begin_request(&route, HealthScope::Route)
        .record(HealthOutcome::Usable, HealthStage::Complete);
    assert_eq!(receiver.recv_timeout(Duration::from_secs(3)).unwrap(), 47);
    unsafe { zcashlc_ohttp_health_unsubscribe_v1(subscription) };
    transport_health::begin_request(&route, HealthScope::Route)
        .record(HealthOutcome::TransportUnavailable, HealthStage::Connection);
    assert!(receiver.recv_timeout(Duration::from_millis(30)).is_err());
}
