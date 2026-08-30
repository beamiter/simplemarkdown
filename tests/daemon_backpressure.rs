//! What the daemon does when the editor stops reading its stdout.
//!
//! Both tests flood the daemon with pings and never read a byte of the answers,
//! so the stdout pipe fills, the writer thread blocks inside `write_all`, and
//! the reply channel behind it fills too.  They differ in what they then ask:
//! the first closes stdin and requires the shutdown to be bounded, the second
//! leaves stdin open and requires the daemon to give up on its own.

use std::io::{Read, Write};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

/// The flood, sized against two limits at once.  On the request side it has to
/// stay inside the kernel's stdin pipe buffer — about 64 KiB, and these are
/// ~26 bytes each — because the daemon stops reading when it stalls and a
/// fixture whose own `writeln!` blocked would hang instead of asserting.  On
/// the reply side it has to overrun the stdout pipe *plus* the reply channel:
/// a pong carries the capability table, so ~350 bytes against 64 KiB of pipe
/// and 256 queued replies is roughly a threefold margin.
const FLOOD: u32 = 1000;

fn flood(stdin: &mut ChildStdin) -> u32 {
    let mut sent = 0;
    for id in 1..=FLOOD {
        match writeln!(stdin, "{}", serde_json::json!({"type": "ping", "id": id})) {
            Ok(()) => sent += 1,
            Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => break,
            Err(error) => panic!("could not write request flood: {error}"),
        }
    }
    sent
}

fn spawn() -> Child {
    Command::new(env!("CARGO_BIN_EXE_simplemarkdown-daemon"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap()
}

fn wait_for_exit(child: &mut Child, budget: Duration, complaint: &str) -> ExitStatus {
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        if started.elapsed() > budget {
            let _ = child.kill();
            let _ = child.wait();
            panic!("{complaint}");
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// How many replies were still sitting in the stdout pipe when the daemon went.
///
/// Read only after the child has exited: reading earlier would drain the pipe
/// and relieve the very backpressure these tests are about.
fn queued_replies(child: &mut Child) -> usize {
    let mut buffered = String::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut buffered)
        .unwrap();
    buffered.lines().filter(|line| !line.is_empty()).count()
}

#[test]
fn unread_stdout_cannot_hold_eof_shutdown_forever() {
    let mut child = spawn();
    let sent = flood(child.stdin.as_mut().unwrap());
    // Not a backpressure assertion.  `sent` counts writes the *kernel* accepted,
    // and a write into a full pipe blocks rather than failing, so this number
    // can only fall short of the flood when the daemon died mid-write and the
    // pipe was broken.  That is worth catching — a daemon that was already gone
    // would make the shutdown deadline below vacuous — but it says nothing
    // about how many replies queued up.  That claim is the next test's.
    assert_eq!(
        sent, FLOOD,
        "the daemon's stdin closed mid-flood; it died before the fixture was set up"
    );
    drop(child.stdin.take());

    let status = wait_for_exit(
        &mut child,
        Duration::from_secs(10),
        "daemon did not bound EOF shutdown under stdout backpressure",
    );
    assert!(status.success(), "daemon exited unsuccessfully: {status}");
}

/// The other half, and the one that actually names the stall.
///
/// stdin stays open for the whole test, so nothing tells the daemon to leave:
/// the only thing that can end this process is its own discovery that stdout is
/// no longer draining.  Delete the `is_stalled()` check in the request loop, or
/// widen the reply channel until it can absorb the flood, and this hangs until
/// the deadline instead of exiting — which is what the `sent > 256` guard this
/// replaced was supposed to be standing in for and could not detect.
#[test]
fn a_reader_that_stops_reading_cannot_pin_the_daemon_open() {
    let mut child = spawn();
    let sent = flood(child.stdin.as_mut().unwrap());
    assert_eq!(
        sent, FLOOD,
        "the daemon's stdin closed mid-flood; it died before the fixture was set up"
    );

    // No `drop(child.stdin)`: the handle outlives the wait below, so the daemon
    // never sees EOF.  Its 2s send timeout plus its 5s wait on the wedged writer
    // is the shutdown being measured; the budget is loose around both.
    let status = wait_for_exit(
        &mut child,
        Duration::from_secs(30),
        "daemon stayed alive with stdout unread and stdin open: the stall was never noticed",
    );
    assert!(status.success(), "daemon exited unsuccessfully: {status}");

    let replies = queued_replies(&mut child);
    assert!(
        replies > 0,
        "the daemon answered nothing at all, so it did not stop *because* of backpressure"
    );
    assert!(
        replies < sent as usize,
        "every one of the {sent} replies fit downstream, so the flood never applied \
         backpressure and this test proved nothing"
    );
}
