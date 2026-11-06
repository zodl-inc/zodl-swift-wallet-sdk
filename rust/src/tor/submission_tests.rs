use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

use super::SubmissionRuntime;

#[test]
fn submission_deadline_covers_later_rpc_and_drops_active_work() {
    let runtime = SubmissionRuntime::new(80).unwrap();
    runtime
        .run(async {
            tokio::time::sleep(Duration::from_millis(50)).await;
            Ok::<_, anyhow::Error>(())
        })
        .unwrap();
    let dropped = Arc::new(AtomicUsize::new(0));
    struct Active(Arc<AtomicUsize>);
    impl Drop for Active {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
    let started = Instant::now();
    let result: anyhow::Result<()> = runtime.run(async {
        let _active = Active(dropped.clone());
        tokio::time::sleep(Duration::from_millis(120)).await;
        Ok(())
    });
    assert!(result.is_err());
    assert!(
        started.elapsed() < Duration::from_millis(60),
        "the second RPC must not receive a fresh 80 ms"
    );
    assert_eq!(dropped.load(Ordering::SeqCst), 1);
    let calls = AtomicUsize::new(0);
    let late: anyhow::Result<()> = runtime.run(async {
        calls.fetch_add(1, Ordering::SeqCst);
        Ok(())
    });
    assert!(late.is_err());
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

#[test]
fn submission_executor_does_not_leave_detached_writer_running() {
    let runtime = SubmissionRuntime::new(30).unwrap();
    let writes = Arc::new(AtomicUsize::new(0));
    let writer_dropped = Arc::new(AtomicUsize::new(0));
    struct Writer(Arc<AtomicUsize>);
    impl Drop for Writer {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
    let result: anyhow::Result<()> = runtime.run(async {
        let writes = writes.clone();
        let owner = Writer(writer_dropped.clone());
        tokio::spawn(async move {
            let _owner = owner;
            for _ in 0..120 {
                writes.fetch_add(1, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        });
        tokio::time::sleep(Duration::from_millis(60)).await;
        Ok(())
    });
    let timed_out = result.is_err();
    drop(runtime);
    let at_return = writes.load(Ordering::SeqCst);
    assert!(at_return > 0);
    std::thread::sleep(Duration::from_millis(20));
    assert_eq!(writes.load(Ordering::SeqCst), at_return);
    assert_eq!(writer_dropped.load(Ordering::SeqCst), 1);
    assert!(timed_out);
}

#[test]
fn zero_submission_budget_is_rejected() {
    assert!(SubmissionRuntime::new(0).is_err());
}

#[test]
fn submission_close_stops_real_socket_writer_before_return() {
    use std::io::Read;
    use tokio::io::AsyncWriteExt;
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let peer = std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut bytes = [0u8; 256];
        let mut received = 0;
        loop {
            let count = socket.read(&mut bytes).unwrap();
            if count == 0 {
                return received;
            }
            received += count;
        }
    });
    let runtime = SubmissionRuntime::new(30).unwrap();
    let writes = Arc::new(AtomicUsize::new(0));
    let result: anyhow::Result<()> = runtime.run(async {
        let mut socket = tokio::net::TcpStream::connect(address).await?;
        let writes = writes.clone();
        tokio::spawn(async move {
            for _ in 0..120 {
                if socket.write_all(&[1]).await.is_err() {
                    break;
                }
                writes.fetch_add(1, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        });
        tokio::time::sleep(Duration::from_millis(60)).await;
        Ok(())
    });
    drop(runtime);
    let at_return = writes.load(Ordering::SeqCst);
    let received = peer.join().unwrap();
    assert!(at_return > 0);
    assert_eq!(
        writes.load(Ordering::SeqCst),
        at_return,
        "the connection writer must be retired before native close returns"
    );
    assert_eq!(received, at_return);
    assert!(result.is_err());
}
