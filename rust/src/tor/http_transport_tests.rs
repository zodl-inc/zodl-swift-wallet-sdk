use std::{
    net::SocketAddr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

use bytes::Bytes;
use http_body_util::{BodyExt, Empty};
use hyper::{Request, client::conn::http1::SendRequest};
use hyper_util::rt::TokioIo;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
    task::JoinHandle,
    time::timeout,
};

use zcash_client_backend::tor::{Error, http::HttpError};

use super::with_http_timeout;

const TEST_GUARD: Duration = Duration::from_secs(2);
const FIXTURE_IO_GUARD: Duration = Duration::from_secs(5);
const MAX_REQUEST_HEADERS: usize = 16 * 1024;

struct ResponseScript {
    headers: &'static [u8],
    body: &'static [u8],
    delay_before_headers: Duration,
    hold_open_after_body: bool,
}

impl ResponseScript {
    fn complete_body() -> Self {
        Self {
            headers: b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n",
            body: b"test",
            delay_before_headers: Duration::ZERO,
            hold_open_after_body: false,
        }
    }

    fn stalled_body() -> Self {
        Self {
            headers: b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\n",
            body: b"x",
            delay_before_headers: Duration::ZERO,
            hold_open_after_body: true,
        }
    }

    fn truncated_body() -> Self {
        Self {
            headers: b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\n",
            body: b"x",
            delay_before_headers: Duration::ZERO,
            hold_open_after_body: false,
        }
    }

    fn delayed_headers() -> Self {
        Self {
            headers: b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n",
            body: b"test",
            delay_before_headers: Duration::from_secs(1),
            hold_open_after_body: false,
        }
    }
}

struct ServerOutcome {
    client_eof: bool,
}

struct LocalHttpServer {
    addr: SocketAddr,
    request_headers_seen: Option<oneshot::Receiver<()>>,
    response_headers_written: Option<oneshot::Receiver<()>>,
    response_body_written: Option<oneshot::Receiver<()>>,
    task: JoinHandle<anyhow::Result<ServerOutcome>>,
}

struct RetryHttpServer {
    addr: SocketAddr,
    accepted: Arc<AtomicUsize>,
    first_request_headers_seen: Option<oneshot::Receiver<()>>,
    second_request_headers_seen: Option<oneshot::Receiver<()>>,
    response_headers_written: Option<oneshot::Receiver<()>>,
    response_body_written: Option<oneshot::Receiver<()>>,
    task: JoinHandle<anyhow::Result<ServerOutcome>>,
}

impl RetryHttpServer {
    async fn spawn() -> Self {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .expect("bind loopback retry server");
        let addr = listener.local_addr().expect("read retry server address");
        let accepted = Arc::new(AtomicUsize::new(0));
        let observed_accepted = accepted.clone();
        let (first_request_tx, first_request_headers_seen) = oneshot::channel();
        let (second_request_tx, second_request_headers_seen) = oneshot::channel();
        let (response_headers_tx, response_headers_written) = oneshot::channel();
        let (response_body_tx, response_body_written) = oneshot::channel();
        let task = tokio::spawn(async move {
            serve_retry_attempts(
                listener,
                observed_accepted,
                first_request_tx,
                second_request_tx,
                response_headers_tx,
                response_body_tx,
            )
            .await
        });

        Self {
            addr,
            accepted,
            first_request_headers_seen: Some(first_request_headers_seen),
            second_request_headers_seen: Some(second_request_headers_seen),
            response_headers_written: Some(response_headers_written),
            response_body_written: Some(response_body_written),
            task,
        }
    }

    fn addr(&self) -> SocketAddr {
        self.addr
    }

    async fn expect_attempts_and_response_stages(&mut self) {
        expect_stage(
            self.first_request_headers_seen
                .take()
                .expect("first-attempt stage is observed once"),
            "server read first-attempt request headers",
        )
        .await;
        expect_stage(
            self.second_request_headers_seen
                .take()
                .expect("second-attempt stage is observed once"),
            "server read second-attempt request headers",
        )
        .await;
        expect_stage(
            self.response_headers_written
                .take()
                .expect("retry response-header stage is observed once"),
            "server wrote delayed retry response headers",
        )
        .await;
        expect_stage(
            self.response_body_written
                .take()
                .expect("retry response-body stage is observed once"),
            "server wrote delayed retry response body bytes",
        )
        .await;
    }

    fn accepted_count(&self) -> usize {
        self.accepted.load(Ordering::SeqCst)
    }

    async fn join(mut self) -> ServerOutcome {
        let joined = timeout(FIXTURE_IO_GUARD, &mut self.task).await;
        match joined {
            Ok(result) => result
                .expect("retry server task must not panic")
                .expect("retry server must complete cleanly"),
            Err(_) => {
                self.task.abort();
                let _ = self.task.await;
                panic!("retry server exceeded the teardown guard");
            }
        }
    }
}

impl LocalHttpServer {
    async fn spawn(script: ResponseScript) -> Self {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .expect("bind loopback test server");
        let addr = listener.local_addr().expect("read loopback server address");
        let (request_headers_tx, request_headers_seen) = oneshot::channel();
        let (response_headers_tx, response_headers_written) = oneshot::channel();
        let (response_body_tx, response_body_written) = oneshot::channel();
        let task = tokio::spawn(async move {
            serve_one(
                listener,
                script,
                request_headers_tx,
                response_headers_tx,
                response_body_tx,
            )
            .await
        });

        Self {
            addr,
            request_headers_seen: Some(request_headers_seen),
            response_headers_written: Some(response_headers_written),
            response_body_written: Some(response_body_written),
            task,
        }
    }

    fn addr(&self) -> SocketAddr {
        self.addr
    }

    async fn expect_request_headers(&mut self) {
        expect_stage(
            self.request_headers_seen
                .take()
                .expect("request-header stage is observed once"),
            "server read request headers",
        )
        .await;
    }

    async fn expect_response_headers_written(&mut self) {
        expect_stage(
            self.response_headers_written
                .take()
                .expect("response-header stage is observed once"),
            "server wrote response headers",
        )
        .await;
    }

    async fn expect_response_body_written(&mut self) {
        expect_stage(
            self.response_body_written
                .take()
                .expect("response-body stage is observed once"),
            "server wrote response body bytes",
        )
        .await;
    }

    async fn expect_no_response_headers(&mut self) {
        expect_stage_absent(
            self.response_headers_written
                .take()
                .expect("response-header stage is observed once"),
            "server response headers",
        )
        .await;
    }

    async fn expect_no_response_body(&mut self) {
        expect_stage_absent(
            self.response_body_written
                .take()
                .expect("response-body stage is observed once"),
            "server response body",
        )
        .await;
    }

    async fn join(mut self) -> ServerOutcome {
        let joined = timeout(FIXTURE_IO_GUARD, &mut self.task).await;
        match joined {
            Ok(result) => result
                .expect("local HTTP server task must not panic")
                .expect("local HTTP server must complete cleanly"),
            Err(_) => {
                self.task.abort();
                let _ = self.task.await;
                panic!("local HTTP server exceeded the teardown guard");
            }
        }
    }
}

async fn serve_one(
    listener: TcpListener,
    script: ResponseScript,
    request_headers_seen: oneshot::Sender<()>,
    response_headers_written: oneshot::Sender<()>,
    response_body_written: oneshot::Sender<()>,
) -> anyhow::Result<ServerOutcome> {
    let (mut stream, _) = listener.accept().await?;
    read_request_headers(&mut stream).await?;
    request_headers_seen
        .send(())
        .map_err(|_| anyhow::anyhow!("request-header observer dropped"))?;

    if !script.delay_before_headers.is_zero() {
        let mut buffer = [0u8; 64];
        let client_closed = tokio::select! {
            _ = tokio::time::sleep(script.delay_before_headers) => false,
            read = stream.read(&mut buffer) => {
                anyhow::ensure!(read? == 0, "client sent unexpected bytes after request headers");
                true
            }
        };
        if client_closed {
            return Ok(ServerOutcome { client_eof: true });
        }
    }

    stream.write_all(script.headers).await?;
    response_headers_written
        .send(())
        .map_err(|_| anyhow::anyhow!("response-header observer dropped"))?;
    stream.write_all(script.body).await?;
    response_body_written
        .send(())
        .map_err(|_| anyhow::anyhow!("response-body observer dropped"))?;

    if !script.hold_open_after_body {
        stream.shutdown().await?;
    }

    Ok(ServerOutcome {
        client_eof: wait_for_eof(&mut stream).await?,
    })
}

async fn serve_retry_attempts(
    listener: TcpListener,
    accepted: Arc<AtomicUsize>,
    first_request_headers_seen: oneshot::Sender<()>,
    second_request_headers_seen: oneshot::Sender<()>,
    response_headers_written: oneshot::Sender<()>,
    response_body_written: oneshot::Sender<()>,
) -> anyhow::Result<ServerOutcome> {
    let (mut first, _) = timeout(FIXTURE_IO_GUARD, listener.accept())
        .await
        .map_err(|_| anyhow::anyhow!("timed out accepting first request attempt"))??;
    accepted.fetch_add(1, Ordering::SeqCst);
    read_request_headers(&mut first).await?;
    first_request_headers_seen
        .send(())
        .map_err(|_| anyhow::anyhow!("first-attempt observer dropped"))?;
    tokio::time::sleep(Duration::from_millis(20)).await;
    first.shutdown().await?;
    drop(first);

    let (mut second, _) = timeout(FIXTURE_IO_GUARD, listener.accept())
        .await
        .map_err(|_| anyhow::anyhow!("timed out accepting second request attempt"))??;
    accepted.fetch_add(1, Ordering::SeqCst);
    read_request_headers(&mut second).await?;
    second_request_headers_seen
        .send(())
        .map_err(|_| anyhow::anyhow!("second-attempt observer dropped"))?;
    tokio::time::sleep(Duration::from_millis(20)).await;
    second
        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\n")
        .await?;
    response_headers_written
        .send(())
        .map_err(|_| anyhow::anyhow!("retry response-header observer dropped"))?;
    second.write_all(b"x").await?;
    response_body_written
        .send(())
        .map_err(|_| anyhow::anyhow!("retry response-body observer dropped"))?;

    Ok(ServerOutcome {
        client_eof: wait_for_eof(&mut second).await?,
    })
}

async fn read_request_headers(stream: &mut TcpStream) -> anyhow::Result<()> {
    timeout(FIXTURE_IO_GUARD, async {
        let mut request = Vec::new();
        let mut buffer = [0u8; 1024];
        loop {
            let read = stream.read(&mut buffer).await?;
            anyhow::ensure!(read != 0, "client closed before sending request headers");
            request.extend_from_slice(&buffer[..read]);
            anyhow::ensure!(
                request.len() <= MAX_REQUEST_HEADERS,
                "request headers exceeded fixture limit"
            );
            if request.windows(4).any(|window| window == b"\r\n\r\n") {
                return anyhow::Ok(());
            }
        }
    })
    .await
    .map_err(|_| anyhow::anyhow!("timed out reading request headers"))?
}

async fn wait_for_eof(stream: &mut TcpStream) -> anyhow::Result<bool> {
    timeout(FIXTURE_IO_GUARD, async {
        let mut buffer = [0u8; 64];
        loop {
            if stream.read(&mut buffer).await? == 0 {
                return anyhow::Ok(true);
            }
        }
    })
    .await
    .map_err(|_| anyhow::anyhow!("timed out waiting for client EOF"))?
}

type ClientDriver = JoinHandle<Result<(), hyper::Error>>;

async fn connect_client(addr: SocketAddr) -> (SendRequest<Empty<Bytes>>, ClientDriver) {
    let stream = TcpStream::connect(addr)
        .await
        .expect("connect to loopback test server");
    let (sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(stream))
        .await
        .expect("complete local HTTP/1 handshake");
    let driver = tokio::spawn(connection);
    (sender, driver)
}

fn request_for(addr: SocketAddr) -> Request<Empty<Bytes>> {
    Request::builder()
        .uri(format!("http://{addr}/"))
        .header(http::header::HOST, addr.to_string())
        .body(Empty::new())
        .expect("build local HTTP request")
}

async fn expect_stage(stage: oneshot::Receiver<()>, name: &str) {
    match timeout(TEST_GUARD, stage).await {
        Ok(Ok(())) => {}
        Ok(Err(_)) => panic!("{name} sender dropped before signaling"),
        Err(_) => panic!("{name} exceeded the fixture guard"),
    }
}

async fn expect_stage_absent(stage: oneshot::Receiver<()>, name: &str) {
    match timeout(TEST_GUARD, stage).await {
        Ok(Err(_)) => {}
        Ok(Ok(())) => panic!("{name} unexpectedly occurred"),
        Err(_) => panic!("{name} sender remained live past the fixture guard"),
    }
}

async fn join_clean_client_driver(mut driver: ClientDriver) {
    let joined = match timeout(TEST_GUARD, &mut driver).await {
        Ok(joined) => joined,
        Err(_) => {
            driver.abort();
            match driver.await {
                Err(error) if error.is_cancelled() => {}
                Err(error) => panic!("local HTTP client driver abort failed: {error}"),
                Ok(result) => {
                    panic!("local HTTP client driver completed after its guard: {result:?}")
                }
            }
            panic!("local HTTP client driver exceeded the teardown guard");
        }
    };

    let connection_result = match joined {
        Ok(result) => result,
        Err(error) if error.is_panic() => {
            panic!("local HTTP client driver panicked: {error}")
        }
        Err(error) if error.is_cancelled() => {
            panic!("local HTTP client driver was unexpectedly cancelled: {error}")
        }
        Err(error) => panic!("local HTTP client driver failed to join: {error}"),
    };

    match connection_result {
        Ok(()) => {}
        Err(error) => {
            panic!("local HTTP client connection failed unexpectedly: {error}")
        }
    }
}

type DriverRegistry = Arc<Mutex<Vec<ClientDriver>>>;

async fn connect_tracked_client(
    addr: SocketAddr,
    drivers: &DriverRegistry,
) -> SendRequest<Empty<Bytes>> {
    let (sender, driver) = connect_client(addr).await;
    drivers
        .lock()
        .expect("client-driver registry lock")
        .push(driver);
    sender
}

async fn join_tracked_client_drivers(drivers: &DriverRegistry) {
    let drivers = std::mem::take(
        &mut *drivers
            .lock()
            .expect("client-driver registry lock for teardown"),
    );
    for driver in drivers {
        join_clean_client_driver(driver).await;
    }
}

#[tokio::test]
async fn stalled_body_uses_outer_deadline() {
    let mut server = LocalHttpServer::spawn(ResponseScript::stalled_body()).await;
    let (mut sender, driver) = connect_client(server.addr()).await;
    let request = request_for(server.addr());
    let (headers_seen, parsed_headers) = tokio::sync::oneshot::channel();

    let guarded_result = timeout(
        TEST_GUARD,
        with_http_timeout(100, async move {
            let response = sender.send_request(request).await?;
            headers_seen
                .send(())
                .expect("observe parsed response headers");
            let body = crate::collect_http_response_body_limited(
                response.into_body(),
                crate::TOR_HTTP_MAX_RESPONSE_BYTES,
            )
            .await?;
            anyhow::Ok(body)
        }),
    )
    .await;

    expect_stage(parsed_headers, "client parsed response headers").await;
    server.expect_request_headers().await;
    server.expect_response_headers_written().await;
    server.expect_response_body_written().await;
    join_clean_client_driver(driver).await;
    let outcome = server.join().await;

    assert!(outcome.client_eof, "the client must close its local socket");
    let result = guarded_result.expect("production timeout exceeded the test guard");
    assert_eq!(
        result.expect_err("body must time out").to_string(),
        "Tor HTTP request timed out"
    );
}

#[tokio::test]
async fn complete_body_copies_exact_bytes() {
    let mut server = LocalHttpServer::spawn(ResponseScript::complete_body()).await;
    let (mut sender, driver) = connect_client(server.addr()).await;
    let request = request_for(server.addr());
    let (headers_seen, parsed_headers) = oneshot::channel();

    let guarded_result = timeout(
        TEST_GUARD,
        with_http_timeout(1_000, async move {
            let response = sender.send_request(request).await?;
            headers_seen
                .send(())
                .expect("observe parsed response headers");
            let body = crate::collect_http_response_body_limited(
                response.into_body(),
                crate::TOR_HTTP_MAX_RESPONSE_BYTES,
            )
            .await?;
            anyhow::Ok(body)
        }),
    )
    .await;

    expect_stage(parsed_headers, "client parsed response headers").await;
    server.expect_request_headers().await;
    server.expect_response_headers_written().await;
    server.expect_response_body_written().await;
    join_clean_client_driver(driver).await;
    let outcome = server.join().await;

    assert!(outcome.client_eof, "the client must close its local socket");
    let result = guarded_result.expect("body copy exceeded the test guard");
    assert_eq!(
        result.expect("complete body must succeed"),
        Some(bytes::Bytes::from_static(b"test"))
    );
}

#[tokio::test]
async fn truncated_body_is_an_error() {
    let mut server = LocalHttpServer::spawn(ResponseScript::truncated_body()).await;
    let (mut sender, driver) = connect_client(server.addr()).await;
    let request = request_for(server.addr());
    let (headers_seen, parsed_headers) = oneshot::channel();

    let guarded_result = timeout(
        TEST_GUARD,
        with_http_timeout(1_000, async move {
            let response = sender.send_request(request).await?;
            headers_seen
                .send(())
                .expect("observe parsed response headers");
            let body = crate::collect_http_response_body_limited(
                response.into_body(),
                crate::TOR_HTTP_MAX_RESPONSE_BYTES,
            )
            .await?;
            anyhow::Ok(body)
        }),
    )
    .await;

    expect_stage(parsed_headers, "client parsed response headers").await;
    server.expect_request_headers().await;
    server.expect_response_headers_written().await;
    server.expect_response_body_written().await;
    join_clean_client_driver(driver).await;
    let outcome = server.join().await;

    assert!(outcome.client_eof, "the client must close its local socket");
    let result = guarded_result.expect("truncated body exceeded the test guard");
    let error = result.expect_err("an incomplete Content-Length must not succeed");
    assert_ne!(error.to_string(), "Tor HTTP request timed out");
}

#[tokio::test]
async fn delayed_headers_use_outer_deadline() {
    let mut server = LocalHttpServer::spawn(ResponseScript::delayed_headers()).await;
    let (mut sender, driver) = connect_client(server.addr()).await;
    let request = request_for(server.addr());
    let (headers_seen, parsed_headers) = oneshot::channel();

    let guarded_result = timeout(
        TEST_GUARD,
        with_http_timeout(100, async move {
            let response = sender.send_request(request).await?;
            headers_seen
                .send(())
                .expect("observe parsed response headers");
            let body = crate::collect_http_response_body_limited(
                response.into_body(),
                crate::TOR_HTTP_MAX_RESPONSE_BYTES,
            )
            .await?;
            anyhow::Ok(body)
        }),
    )
    .await;

    server.expect_request_headers().await;
    join_clean_client_driver(driver).await;
    expect_stage_absent(parsed_headers, "client response headers").await;
    server.expect_no_response_headers().await;
    server.expect_no_response_body().await;
    let outcome = server.join().await;

    assert!(outcome.client_eof, "the client must close its local socket");
    let result = guarded_result.expect("production timeout exceeded the test guard");
    assert_eq!(
        result.expect_err("header wait must time out").to_string(),
        "Tor HTTP request timed out"
    );
}

#[tokio::test]
async fn one_deadline_spans_local_transport_attempts() {
    let mut server = RetryHttpServer::spawn().await;
    let addr = server.addr();
    let drivers = DriverRegistry::default();
    let operation_drivers = drivers.clone();
    let (second_headers_seen, parsed_second_headers) = oneshot::channel();

    let guarded_result = timeout(
        TEST_GUARD,
        with_http_timeout(250, async move {
            let mut first_sender = connect_tracked_client(addr, &operation_drivers).await;
            let first_result = first_sender.send_request(request_for(addr)).await;
            anyhow::ensure!(
                first_result.is_err(),
                "the first local attempt unexpectedly received headers"
            );
            drop(first_sender);

            let mut second_sender = connect_tracked_client(addr, &operation_drivers).await;
            let response = second_sender.send_request(request_for(addr)).await?;
            second_headers_seen
                .send(())
                .expect("observe parsed second-attempt response headers");
            let body = crate::collect_http_response_body_limited(
                response.into_body(),
                crate::TOR_HTTP_MAX_RESPONSE_BYTES,
            )
            .await?;
            anyhow::Ok(body)
        }),
    )
    .await;

    server.expect_attempts_and_response_stages().await;
    expect_stage(
        parsed_second_headers,
        "client parsed second-attempt response headers",
    )
    .await;
    join_tracked_client_drivers(&drivers).await;
    let accepted_count = server.accepted_count();
    let outcome = server.join().await;

    assert_eq!(accepted_count, 2, "both local attempts must be observed");
    assert!(outcome.client_eof, "the client must close its local socket");
    let result = guarded_result.expect("production timeout exceeded the test guard");
    assert_eq!(
        result
            .expect_err("the shared attempt budget must expire")
            .to_string(),
        "Tor HTTP request timed out"
    );
}

// --- The response-body guard on a local server ---------------------------------------------
//
// These drive `tor_http_with_body_guard`, the wiring every `zcashlc_tor_http_*` call uses, with
// a local hyper client in place of `zcash_client_backend`'s Tor client, replaying the crate's
// `http_request` call order by hand: the retry filter sees the final response's status, then the
// collector gets the body. Driving the crate's own client needs a bootstrapped Tor
// (`network_tests::real_ffi_error_page_is_cut_at_the_fixed_guard`, opt-in).

/// The declared length of an error page that never ends within a test.
const ENDLESS_ERROR_PAGE_DECLARED_LEN: usize = 1 << 20;
/// A 2xx body past the error-page guard but under every caller's ceiling.
const LARGE_OK_BODY_LEN: usize = crate::TOR_HTTP_MAX_ERROR_BODY_BYTES + 4096;
/// A small error page, returned whole.
const SMALL_ERROR_PAGE_LEN: usize = 1024;
/// How many bytes past the guard the collector may have consumed: the frame that overflowed it.
/// The endless page is trickled one byte at a time past the guard, so that frame is a few bytes.
const GUARD_OVERFLOW_FRAME_SLACK: usize = 64;
const TRICKLE_INTERVAL: Duration = Duration::from_millis(10);

struct LargeResponseScript {
    status: u16,
    declared_len: usize,
    /// Bytes written right after the headers.
    written_at_once: usize,
    /// Then one byte every `TRICKLE_INTERVAL` until the client goes away.
    trickle: bool,
}

impl LargeResponseScript {
    /// `status` with `TOR_HTTP_MAX_ERROR_BODY_BYTES` bytes at once, then a trickle that never
    /// reaches the declared length within a test.
    fn endless_error_page(status: u16) -> Self {
        Self {
            status,
            declared_len: ENDLESS_ERROR_PAGE_DECLARED_LEN,
            written_at_once: crate::TOR_HTTP_MAX_ERROR_BODY_BYTES,
            trickle: true,
        }
    }

    /// `status` with a complete body of `len` bytes.
    fn complete(status: u16, len: usize) -> Self {
        Self {
            status,
            declared_len: len,
            written_at_once: len,
            trickle: false,
        }
    }
}

struct LargeServerOutcome {
    bytes_written: usize,
    client_eof: bool,
}

struct LargeHttpServer {
    addr: SocketAddr,
    task: JoinHandle<anyhow::Result<LargeServerOutcome>>,
}

impl LargeHttpServer {
    async fn spawn(script: LargeResponseScript) -> Self {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .expect("bind loopback large-response server");
        let addr = listener
            .local_addr()
            .expect("read large-response server address");
        let task = tokio::spawn(async move { serve_large(listener, script).await });
        Self { addr, task }
    }

    fn addr(&self) -> SocketAddr {
        self.addr
    }

    async fn join(mut self) -> LargeServerOutcome {
        match timeout(FIXTURE_IO_GUARD, &mut self.task).await {
            Ok(result) => result
                .expect("large-response server task must not panic")
                .expect("large-response server must complete cleanly"),
            Err(_) => {
                self.task.abort();
                let _ = self.task.await;
                panic!("large-response server exceeded the teardown guard");
            }
        }
    }
}

async fn serve_large(
    listener: TcpListener,
    script: LargeResponseScript,
) -> anyhow::Result<LargeServerOutcome> {
    let (mut stream, _) = timeout(FIXTURE_IO_GUARD, listener.accept())
        .await
        .map_err(|_| anyhow::anyhow!("timed out accepting the guarded request"))??;
    read_request_headers(&mut stream).await?;
    stream
        .write_all(
            format!(
                "HTTP/1.1 {} Scripted\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                script.status, script.declared_len
            )
            .as_bytes(),
        )
        .await?;

    let mut bytes_written = 0;
    // A client that stopped reading closes its socket; the write then fails (or the read below
    // sees EOF), which is the outcome, not a fixture error.
    if stream
        .write_all(&vec![b'e'; script.written_at_once])
        .await
        .is_err()
    {
        return Ok(LargeServerOutcome {
            bytes_written,
            client_eof: true,
        });
    }
    bytes_written += script.written_at_once;

    if !script.trickle {
        // A client that stopped at its ceiling may already have reset the connection.
        let _ = stream.shutdown().await;
        let client_eof = matches!(wait_for_eof(&mut stream).await, Ok(true) | Err(_));
        return Ok(LargeServerOutcome {
            bytes_written,
            client_eof,
        });
    }

    let deadline = Instant::now() + FIXTURE_IO_GUARD;
    let mut buffer = [0u8; 64];
    loop {
        match timeout(TRICKLE_INTERVAL, stream.read(&mut buffer)).await {
            Ok(Ok(0)) | Ok(Err(_)) => {
                return Ok(LargeServerOutcome {
                    bytes_written,
                    client_eof: true,
                });
            }
            Ok(Ok(_)) => anyhow::bail!("client sent bytes after its request headers"),
            Err(_) => {
                anyhow::ensure!(
                    Instant::now() < deadline,
                    "the client kept reading the error page past the guard"
                );
                if stream.write_all(b"e").await.is_err() {
                    return Ok(LargeServerOutcome {
                        bytes_written,
                        client_eof: true,
                    });
                }
                bytes_written += 1;
            }
        }
    }
}

struct GuardedCall {
    response: anyhow::Result<http::Response<Bytes>>,
    /// Body bytes the collector pulled from the connection, the frame that overflowed its bound
    /// included.
    body_bytes_consumed: usize,
}

/// One GET through `tor_http_with_body_guard` with the test's local hyper client, the crate's
/// call order replayed: `guard.filter` with the final status, then `guard.parse_get` with the body.
async fn guarded_local_get(addr: SocketAddr, max_bytes: usize) -> GuardedCall {
    let (mut sender, driver) = connect_client(addr).await;
    let consumed = Arc::new(AtomicUsize::new(0));
    let counted = consumed.clone();

    let guarded = timeout(
        TEST_GUARD,
        crate::tor_http_with_body_guard(
            max_bytes,
            |_| None,
            |guard| async move {
                let response = sender
                    .send_request(request_for(addr))
                    .await
                    .map_err(|error| Error::from(HttpError::from(error)))?;
                // zcash_client_backend's http_request: the retry filter sees the final response's
                // status, then parse_response gets the body.
                let retry = guard.filter(Ok(response.status()));
                assert!(retry.is_none(), "the test's retry policy never retries");
                let (parts, body) = response.into_parts();
                let body = body.map_frame(move |frame| {
                    if let Some(data) = frame.data_ref() {
                        counted.fetch_add(data.len(), Ordering::SeqCst);
                    }
                    frame
                });
                let body = guard.parse_get(body, false).await?;
                Ok(http::Response::from_parts(parts, body))
            },
        ),
    )
    .await;

    driver.abort();
    let _ = driver.await;

    GuardedCall {
        response: guarded.expect(
            "the guarded call must return within the test guard: the collector read past its bound",
        ),
        body_bytes_consumed: consumed.load(Ordering::SeqCst),
    }
}

async fn endless_error_page_is_cut_at_the_guard(status: u16) {
    let server = LargeHttpServer::spawn(LargeResponseScript::endless_error_page(status)).await;
    let call = guarded_local_get(server.addr(), crate::TOR_HTTP_MAX_RESPONSE_BYTES).await;
    let outcome = server.join().await;

    let response = call
        .response
        .expect("an error page past the guard is reported by its status, not as too large");
    assert_eq!(response.status().as_u16(), status);
    assert!(
        response.body().is_empty(),
        "the cut error page comes back empty"
    );
    assert!(
        call.body_bytes_consumed > crate::TOR_HTTP_MAX_ERROR_BODY_BYTES,
        "the collector must have reached the guard: {} bytes",
        call.body_bytes_consumed
    );
    assert!(
        call.body_bytes_consumed
            <= crate::TOR_HTTP_MAX_ERROR_BODY_BYTES + GUARD_OVERFLOW_FRAME_SLACK,
        "the collector read past the 64 KiB guard: {} bytes",
        call.body_bytes_consumed
    );
    assert!(outcome.client_eof, "the client must close its local socket");
    assert!(
        outcome.bytes_written < ENDLESS_ERROR_PAGE_DECLARED_LEN,
        "the server must not have been read to the end of the page"
    );
}

#[tokio::test]
async fn an_endless_429_page_is_cut_at_the_guard_under_the_default_ceiling() {
    endless_error_page_is_cut_at_the_guard(429).await;
}

#[tokio::test]
async fn an_endless_503_page_is_cut_at_the_guard_under_the_default_ceiling() {
    endless_error_page_is_cut_at_the_guard(503).await;
}

#[tokio::test]
async fn a_small_error_page_is_returned_whole_with_its_status() {
    let server =
        LargeHttpServer::spawn(LargeResponseScript::complete(429, SMALL_ERROR_PAGE_LEN)).await;
    let call = guarded_local_get(server.addr(), crate::TOR_HTTP_MAX_RESPONSE_BYTES).await;
    let outcome = server.join().await;

    let response = call.response.expect("a small error page is returned");
    assert_eq!(response.status(), http::StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(response.body().len(), SMALL_ERROR_PAGE_LEN);
    assert_eq!(call.body_bytes_consumed, SMALL_ERROR_PAGE_LEN);
    assert_eq!(outcome.bytes_written, SMALL_ERROR_PAGE_LEN);
}

#[tokio::test]
async fn a_large_2xx_body_under_the_callers_ceiling_is_returned_whole() {
    let server =
        LargeHttpServer::spawn(LargeResponseScript::complete(200, LARGE_OK_BODY_LEN)).await;
    let call = guarded_local_get(server.addr(), crate::TOR_HTTP_MAX_RESPONSE_BYTES).await;
    let outcome = server.join().await;

    let response = call
        .response
        .expect("a 2xx body past 64 KiB but under the ceiling is not cut");
    assert_eq!(response.status(), http::StatusCode::OK);
    assert_eq!(response.body().len(), LARGE_OK_BODY_LEN);
    assert!(response.body().iter().all(|byte| *byte == b'e'));
    assert_eq!(call.body_bytes_consumed, LARGE_OK_BODY_LEN);
    assert_eq!(outcome.bytes_written, LARGE_OK_BODY_LEN);
    assert!(outcome.client_eof, "the client must close its local socket");
}

#[tokio::test]
async fn a_2xx_body_past_the_callers_ceiling_is_an_error() {
    let server =
        LargeHttpServer::spawn(LargeResponseScript::complete(200, LARGE_OK_BODY_LEN)).await;
    let call = guarded_local_get(server.addr(), crate::TOR_HTTP_MAX_ERROR_BODY_BYTES).await;
    let _ = server.join().await;

    let error = call
        .response
        .expect_err("a 2xx body past the caller's ceiling must fail");
    assert!(
        error.to_string().contains("exceeds"),
        "unexpected error: {error}"
    );
    assert!(
        call.body_bytes_consumed <= LARGE_OK_BODY_LEN,
        "the collector cannot consume more than the body"
    );
}

// The dependency's http_request is private and needs bootstrapped Tor. This fixture replaces
// only its socket and its source-verified 60s parse_response timer, and uses GET's production
// parser, total deadline, response bounds, and status handling unchanged.
struct ParsedGetOutcome {
    response: anyhow::Result<http::Response<Bytes>>,
    elapsed: Duration,
    client_eof: bool,
}

async fn parsed_get(
    timeout_ms: Option<u64>,
    body_delay: Duration,
    status: u16,
    data: Bytes,
    max_bytes: usize,
) -> ParsedGetOutcome {
    let (client_io, mut server_io) = tokio::io::duplex(1024);
    let (mut sender, connection) =
        hyper::client::conn::http1::handshake::<_, Empty<Bytes>>(TokioIo::new(client_io))
            .await
            .unwrap();
    let driver = tokio::spawn(connection);
    let server = tokio::spawn(async move {
        let mut request = [0; 1024];
        server_io.read(&mut request).await.unwrap();
        server_io
            .write_all(
                format!(
                    "HTTP/1.1 {status} Scripted\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    data.len()
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        server_io.write_all(&data[..1]).await.unwrap();
        let mut eof = [0; 1];
        tokio::select! {
            _ = tokio::time::sleep(body_delay) => {
                // Cutting an oversized body may close the socket during the write.
                if server_io.write_all(&data[1..]).await.is_err() { return true; }
                let _ = server_io.shutdown().await;
                matches!(server_io.read(&mut eof).await, Ok(0) | Err(_))
            }
            result = server_io.read(&mut eof) => matches!(result, Ok(0) | Err(_)),
        }
    });
    let started = tokio::time::Instant::now();
    let response = crate::tor_http_get_response(
        max_bytes,
        timeout_ms,
        |_| None,
        |guard, explicit_deadline| async move {
            let response = sender
                .send_request(
                    Request::builder()
                        .uri("http://local/params")
                        .body(Empty::<Bytes>::new())
                        .unwrap(),
                )
                .await
                .map_err(HttpError::from)?;
            guard.filter(Ok(response.status()));
            let (parts, body) = response.into_parts();
            let parsed = timeout(
                Duration::from_secs(60),
                guard.parse_get(body, explicit_deadline),
            )
            .await
            .unwrap_or_else(|_| {
                Err(
                    HttpError::Timeout(zcash_client_backend::tor::http::TimeoutPhase::ResponseBody)
                        .into(),
                )
            })?;
            Ok(http::Response::from_parts(parts, parsed))
        },
    )
    .await;
    let elapsed = started.elapsed();
    // Do not abort these tasks: the body/socket must be released by the production path.
    timeout(Duration::from_secs(1), driver)
        .await
        .expect("body release must stop the connection driver")
        .expect("driver must not panic")
        .expect("driver must close cleanly");
    let client_eof = timeout(Duration::from_secs(1), server)
        .await
        .expect("the server must observe client closure")
        .expect("server must not panic");
    ParsedGetOutcome {
        response,
        elapsed,
        client_eof,
    }
}

async fn slow_body_get(timeout_ms: Option<u64>, delay: Duration) -> ParsedGetOutcome {
    parsed_get(
        timeout_ms,
        delay,
        200,
        Bytes::from_static(b"test"),
        crate::TOR_HTTP_MAX_RESPONSE_BYTES,
    )
    .await
}

// Break caught: collecting inside the backend parser silently overrides a 30-minute budget.
#[tokio::test(start_paused = true)]
async fn explicit_get_body_can_complete_after_backend_sixty_seconds() {
    let outcome = slow_body_get(Some(1_800_000), Duration::from_secs(61)).await;
    let response = outcome
        .response
        .expect("the explicit GET deadline permits a body longer than 60 seconds");
    assert_eq!(response.body(), b"test".as_slice());
    assert_eq!(outcome.elapsed, Duration::from_secs(61));
    assert!(outcome.client_eof);
}

#[tokio::test(start_paused = true)]
async fn untimed_get_retains_backend_sixty_second_body_timeout() {
    let outcome = slow_body_get(None, Duration::from_secs(61)).await;
    let error = outcome
        .response
        .expect_err("legacy GET keeps its backend timer");
    assert!(
        error.to_string().contains("reading the response body"),
        "{error}"
    );
    assert_eq!(outcome.elapsed, Duration::from_secs(60));
    assert!(outcome.client_eof);
}

#[tokio::test(start_paused = true)]
async fn explicit_get_body_expiry_drops_connection_at_total_deadline() {
    for (deadline_ms, expected) in [
        (1_800_000, Duration::from_secs(1800)),
        (7, Duration::from_millis(7)),
    ] {
        let outcome = slow_body_get(Some(deadline_ms), Duration::from_secs(1801)).await;
        assert_eq!(
            outcome
                .response
                .expect_err("pending body must expire")
                .to_string(),
            "Tor HTTP request timed out"
        );
        assert_eq!(outcome.elapsed, expected);
        assert!(
            outcome.client_eof,
            "the pending Incoming must release its socket"
        );
    }
}

#[tokio::test(start_paused = true)]
async fn explicit_get_preserves_response_size_and_status_guards() {
    // The same production collector is parameterized: small bounds prove both sides of
    // the success ceiling without allocating a 257 MiB response in a unit test.
    assert_eq!(crate::TOR_HTTP_MAX_RESPONSE_BYTES, 269_484_032);
    for (limit, succeeds) in [(4, true), (3, false)] {
        let outcome = parsed_get(
            Some(1000),
            Duration::ZERO,
            200,
            Bytes::from_static(b"test"),
            limit,
        )
        .await;
        if succeeds {
            assert_eq!(outcome.response.unwrap().body(), b"test".as_slice());
        } else {
            assert!(
                outcome
                    .response
                    .unwrap_err()
                    .to_string()
                    .contains("exceeds")
            );
        }
        assert!(outcome.client_eof);
    }
    for (length, expected_len) in [(65_536, 65_536), (65_537, 0)] {
        let outcome = parsed_get(
            Some(1000),
            Duration::ZERO,
            503,
            Bytes::from(vec![b'e'; length]),
            3,
        )
        .await;
        let response = outcome
            .response
            .expect("error pages preserve their status even when cut");
        assert_eq!(response.status(), 503);
        assert_eq!(response.body().len(), expected_len);
        assert!(outcome.client_eof);
    }
}

#[tokio::test]
async fn legacy_429_preserves_actual_pause_after_a_real_body_error() {
    let server = LocalHttpServer::spawn(ResponseScript {
        headers: b"HTTP/1.1 429 Limited\r\nRetry-After: 120\r\nContent-Length: 10\r\nConnection: close\r\n\r\n",
        body: b"x", delay_before_headers: Duration::ZERO, hold_open_after_body: false,
    }).await;
    let before = slipstream_core::transport_health::monotonic_time_nanoseconds();
    let call = guarded_local_get(server.addr(), 1024).await;
    assert!(call.response.is_err());
    let outcome = crate::zcashlc_tor_http_last_outcome();
    assert_eq!(outcome.http_status, 429);
    assert!(outcome.retry_not_before_ns >= before + 120_000_000_000);
    assert!(
        outcome.retry_not_before_ns
            <= slipstream_core::transport_health::monotonic_time_nanoseconds() + 120_000_000_000
    );
    server.join().await;
}
