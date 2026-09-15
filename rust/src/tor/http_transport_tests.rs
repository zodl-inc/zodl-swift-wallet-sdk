use std::{
    net::SocketAddr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use bytes::Bytes;
use http_body_util::Empty;
use hyper::{Request, client::conn::http1::SendRequest};
use hyper_util::rt::TokioIo;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
    task::JoinHandle,
    time::timeout,
};

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

async fn connect_client(addr: SocketAddr) -> (SendRequest<Empty<Bytes>>, JoinHandle<()>) {
    let stream = TcpStream::connect(addr)
        .await
        .expect("connect to loopback test server");
    let (sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(stream))
        .await
        .expect("complete local HTTP/1 handshake");
    let driver = tokio::spawn(async move {
        let _ = connection.await;
    });
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

async fn join_client_driver(mut driver: JoinHandle<()>) {
    if timeout(TEST_GUARD, &mut driver).await.is_err() {
        driver.abort();
        let _ = driver.await;
        panic!("local HTTP client driver exceeded the teardown guard");
    }
}

type DriverRegistry = Arc<Mutex<Vec<JoinHandle<()>>>>;

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
        join_client_driver(driver).await;
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
            let body = crate::collect_http_response_body(response.into_body()).await?;
            anyhow::Ok(body)
        }),
    )
    .await;

    expect_stage(parsed_headers, "client parsed response headers").await;
    server.expect_request_headers().await;
    server.expect_response_headers_written().await;
    server.expect_response_body_written().await;
    join_client_driver(driver).await;
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
            let body = crate::collect_http_response_body(response.into_body()).await?;
            anyhow::Ok(body)
        }),
    )
    .await;

    expect_stage(parsed_headers, "client parsed response headers").await;
    server.expect_request_headers().await;
    server.expect_response_headers_written().await;
    server.expect_response_body_written().await;
    join_client_driver(driver).await;
    let outcome = server.join().await;

    assert!(outcome.client_eof, "the client must close its local socket");
    let result = guarded_result.expect("body copy exceeded the test guard");
    assert_eq!(result.expect("complete body must succeed"), b"test"[..]);
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
            let body = crate::collect_http_response_body(response.into_body()).await?;
            anyhow::Ok(body)
        }),
    )
    .await;

    expect_stage(parsed_headers, "client parsed response headers").await;
    server.expect_request_headers().await;
    server.expect_response_headers_written().await;
    server.expect_response_body_written().await;
    join_client_driver(driver).await;
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
            let body = crate::collect_http_response_body(response.into_body()).await?;
            anyhow::Ok(body)
        }),
    )
    .await;

    server.expect_request_headers().await;
    join_client_driver(driver).await;
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
            let body = crate::collect_http_response_body(response.into_body()).await?;
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
