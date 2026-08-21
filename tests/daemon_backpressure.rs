use std::io::Write;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[test]
fn unread_stdout_cannot_hold_eof_shutdown_forever() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_simplemarkdown-daemon"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    {
        let stdin = child.stdin.as_mut().unwrap();
        let mut sent = 0;
        for id in 1..=1000 {
            match writeln!(stdin, "{}", serde_json::json!({"type": "ping", "id": id})) {
                Ok(()) => sent += 1,
                Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => break,
                Err(error) => panic!("could not write request flood: {error}"),
            }
        }
        assert!(
            sent > 256,
            "fixture never exceeded the reply channel capacity"
        );
    }
    drop(child.stdin.take());

    let started = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if started.elapsed() > Duration::from_secs(10) {
            let _ = child.kill();
            let _ = child.wait();
            panic!("daemon did not bound EOF shutdown under stdout backpressure");
        }
        std::thread::sleep(Duration::from_millis(25));
    };
    assert!(status.success(), "daemon exited unsuccessfully: {status}");
}
