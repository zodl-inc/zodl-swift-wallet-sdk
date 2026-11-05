use std::time::Duration;

use bytes::Buf;
use http_body_util::{BodyExt, Full};
use hyper::Request;
use hyper_util::rt::TokioIo;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::oneshot,
    task::AbortHandle,
    time::timeout,
};

use super::{post_body, with_http_timeout};

const GUARD: Duration = Duration::from_secs(5);
const PAYLOAD_LEN: usize = 256 * 1024;

struct AbortOnDrop(AbortHandle);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

#[derive(Clone, Copy, Debug)]
enum ReturnBeforeDrain {
    EarlyResponse,
    Deadline,
}

// Check while caller memory is still alive and before spawning any task. A borrowed
// regression fails here safely, never by freeing or mutating memory still in use.
async fn require_owned<B: Buf + Clone + Unpin>(body: &Full<B>, caller: &[u8]) {
    if let Some(frame) = body.clone().frame().await {
        let frame = frame.unwrap();
        let data = frame.data_ref().unwrap();
        let pointer = data.chunk().as_ptr() as usize;
        let start = caller.as_ptr() as usize;
        assert!(
            !(start..start + caller.len()).contains(&pointer),
            "native POST body still borrows the caller allocation"
        );
    }
}

async fn late_wire_bytes<B>(
    body: Full<B>,
    length: usize,
    mode: ReturnBeforeDrain,
    caller: &mut Option<Vec<u8>>,
) where
    B: Buf + Send + Unpin + 'static,
{
    // Bounded in-memory HTTP transport: no Tor, DNS, or external network. The body
    // exceeds the entire transport capacity, so its tail cannot be buffered early.
    let (client, mut server) = tokio::io::duplex(128);
    let (request_seen_tx, request_seen) = oneshot::channel();
    let (drain_tx, drain) = oneshot::channel();
    let server_task = tokio::spawn(async move {
        let mut headers = Vec::new();
        while !headers.ends_with(b"\r\n\r\n") {
            headers.push(server.read_u8().await.unwrap());
            assert!(headers.len() < 4096);
        }
        assert!(headers.starts_with(b"POST / HTTP/1.1\r\n"));
        let mut received = Vec::new();
        if length > 0 {
            received.push(server.read_u8().await.unwrap());
        }
        request_seen_tx.send(()).unwrap();
        if matches!(mode, ReturnBeforeDrain::EarlyResponse) {
            server
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
                .await
                .unwrap();
        }
        drain.await.unwrap();
        received.resize(length, 0);
        if length > 0 {
            server.read_exact(&mut received[1..]).await.unwrap();
        }
        received
    });
    let _server_abort = AbortOnDrop(server_task.abort_handle());
    let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(client))
        .await
        .unwrap();
    let connection_task = tokio::spawn(connection);
    let _connection_abort = AbortOnDrop(connection_task.abort_handle());
    let request = Request::post("/")
        .header("Host", "fixture.invalid")
        .header("Content-Length", length)
        .body(body)
        .unwrap();
    let operation = async {
        let response = sender.send_request(request).await?;
        assert_eq!(response.status(), 200);
        response.into_body().collect().await?;
        anyhow::Ok(())
    };
    match mode {
        ReturnBeforeDrain::EarlyResponse => timeout(GUARD, operation).await.unwrap().unwrap(),
        ReturnBeforeDrain::Deadline => {
            let error = with_http_timeout(20, operation).await.unwrap_err();
            assert!(error.is::<super::HttpDeadline>());
        }
    }
    timeout(GUARD, request_seen).await.unwrap().unwrap();
    drop(sender);
    // The outer operation has returned, just as the synchronous FFI call does.
    // Reuse and then release the actual caller buffer while Hyper is still gated.
    if let Some(mut allocation) = caller.take() {
        allocation.fill(0xe3);
        drop(allocation);
    }
    let replacement = vec![0xc7; length];
    drain_tx.send(()).unwrap();
    let received = timeout(GUARD, server_task).await.unwrap().unwrap();
    assert_eq!(received, vec![0x5a; length], "late payload: {mode:?}");
    assert!(replacement.iter().all(|byte| *byte == 0xc7));
    // Dropping the request future can close the response channel, so connection
    // errors after the full request has arrived are expected for deadline cases.
    let _ = timeout(GUARD, connection_task).await.unwrap().unwrap();
}

async fn exercise_body_lifetime(mode: ReturnBeforeDrain) {
    for length in [PAYLOAD_LEN, 0] {
        let mut caller = Some(vec![0x5a; length]);
        let allocation = caller.as_ref().unwrap();
        let pointer = if length == 0 {
            std::ptr::null()
        } else {
            allocation.as_ptr()
        };
        let body = unsafe { post_body(pointer, allocation.len()) };
        require_owned(&body, allocation).await;
        // The backend clones Full for each retry. Drop the original before either
        // clone is driven and use the second only after caller memory is released.
        let attempts = [body.clone(), body.clone()];
        drop(body);
        for attempt in attempts {
            timeout(GUARD, late_wire_bytes(attempt, length, mode, &mut caller))
                .await
                .expect("detached POST work must finish within the fixture guard");
        }
    }
}

#[tokio::test(start_paused = true)]
async fn native_post_body_survives_early_response() {
    exercise_body_lifetime(ReturnBeforeDrain::EarlyResponse).await;
}

#[tokio::test(start_paused = true)]
async fn native_post_body_survives_deadline() {
    exercise_body_lifetime(ReturnBeforeDrain::Deadline).await;
}
