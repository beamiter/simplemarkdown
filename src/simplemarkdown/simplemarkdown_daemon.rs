//! simplemarkdown — the Markdown preview backend for the Vim plugin.
//!
//! Reads JSON-lines requests on stdin, writes JSON-lines events on stdout.
//! Rendering happens on the blocking pool, and a request the editor has since
//! withdrawn is dropped before it starts: typing in a large document queues a
//! render per keystroke burst, and Vim only ever wants the answer to the last.

mod classes;
mod glyphs;
mod highlight;
mod inline;
mod protocol;
mod render;
mod table;

use protocol::{Event, PROTOCOL_VERSION, RenderResult, Request};
use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;
use std::time::Instant;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{Mutex, mpsc};

const USAGE: &str = "\
Usage: simplemarkdown-daemon [OPTION]

With no option the daemon speaks the JSON-lines protocol on stdin/stdout.

  --preview FILE [WIDTH]  render FILE to plain text and exit (default width 80)
  --classes               list every text-property class the renderer emits
  --self-test             check the renderer against a built-in document
  --version, -V           print the version
  --help, -h              print this message";

fn capabilities() -> BTreeMap<&'static str, bool> {
    BTreeMap::from([
        ("render", true),
        ("toc", true),
        ("links", true),
        ("tables", true),
        ("footnotes", true),
        ("tasklists", true),
        ("alerts", true),
        ("frontmatter", true),
        ("syntax", true),
        ("ascii", true),
    ])
}

fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => run_daemon(),
        Some("--version" | "-V") => {
            println!("simplemarkdown-daemon {}", env!("CARGO_PKG_VERSION"));
            std::process::ExitCode::SUCCESS
        }
        Some("--help" | "-h") => {
            println!(
                "simplemarkdown-daemon {}\n\n{USAGE}",
                env!("CARGO_PKG_VERSION")
            );
            std::process::ExitCode::SUCCESS
        }
        Some("--classes") => {
            for class in classes::ALL {
                println!("{class}");
            }
            std::process::ExitCode::SUCCESS
        }
        Some("--self-test") => match self_test() {
            Ok(()) => {
                println!("ok");
                std::process::ExitCode::SUCCESS
            }
            Err(message) => {
                eprintln!("self-test failed: {message}");
                std::process::ExitCode::FAILURE
            }
        },
        Some("--preview") => match preview(&args[1..]) {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(message) => {
                eprintln!("simplemarkdown-daemon: {message}");
                std::process::ExitCode::FAILURE
            }
        },
        Some(other) => {
            eprintln!("unknown argument: {other}\n\n{USAGE}");
            std::process::ExitCode::from(2)
        }
    }
}

// ─────────────────────────── daemon ───────────────────────────

fn run_daemon() -> std::process::ExitCode {
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("simplemarkdown-daemon: could not start the runtime: {error}");
            return std::process::ExitCode::FAILURE;
        }
    };
    match runtime.block_on(serve()) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("simplemarkdown-daemon: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}

async fn serve() -> std::io::Result<()> {
    let (out_tx, out_rx) = mpsc::channel::<String>(256);
    let writer = tokio::spawn(stdout_writer(out_rx));

    // Requests the editor has withdrawn.  Checked twice — when the render is
    // picked up and again when it finishes — because a document large enough
    // to be worth cancelling is also large enough to be cancelled mid-flight.
    let cancelled: Arc<Mutex<HashSet<u64>>> = Arc::new(Mutex::new(HashSet::new()));

    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let request = match serde_json::from_str::<Request>(&line) {
            Ok(request) => request,
            Err(error) => {
                send(
                    &out_tx,
                    Event::Error {
                        id: 0,
                        message: format!("invalid request: {error}"),
                    },
                )
                .await;
                continue;
            }
        };

        match request {
            Request::Ping { id } => {
                send(
                    &out_tx,
                    Event::Pong {
                        id,
                        protocol_version: PROTOCOL_VERSION,
                        version: env!("CARGO_PKG_VERSION"),
                        capabilities: capabilities(),
                    },
                )
                .await;
            }
            Request::Cancel { id } => {
                cancelled.lock().await.insert(id);
            }
            Request::Render(request) => {
                let tx = out_tx.clone();
                let cancelled = cancelled.clone();
                tokio::spawn(async move {
                    let id = request.id;
                    if cancelled.lock().await.remove(&id) {
                        return;
                    }
                    let started = Instant::now();
                    let width = request.width.max(8);
                    let opts = request.opts.clone();
                    let source = request.lines.join("\n");

                    // Rendering a long document with syntax highlighting is
                    // CPU-bound for tens of milliseconds; keeping it off the
                    // reactor is what lets a cancel arriving meanwhile be seen.
                    let rendered =
                        tokio::task::spawn_blocking(move || render::render(&source, width, &opts))
                            .await;

                    let output = match rendered {
                        Ok(output) => output,
                        Err(error) => {
                            send(
                                &tx,
                                Event::Error {
                                    id,
                                    message: format!("render failed: {error}"),
                                },
                            )
                            .await;
                            return;
                        }
                    };

                    if cancelled.lock().await.remove(&id) {
                        return;
                    }
                    send(
                        &tx,
                        Event::RenderResult(Box::new(RenderResult {
                            id,
                            width,
                            lines: output.lines,
                            toc: output.toc,
                            links: output.links,
                            elapsed_ms: started.elapsed().as_millis(),
                        })),
                    )
                    .await;
                });
            }
        }
    }

    // Stdin is closed, but replies may still be queued, and a render spawned a
    // moment ago may not have produced its own yet.  Returning here drops the
    // runtime, which cancels the writer task mid-flight and loses whatever it
    // had not written — invisible to the plugin, whose stdin stays open for the
    // life of the session, but fatal to anything that pipes one request in and
    // reads the answer out.
    //
    // Dropping our sender lets the writer finish once the last in-flight render
    // has dropped its clone.  The timeout is a backstop: a wedged render must
    // not keep the process alive for ever.
    drop(out_tx);
    let _ = tokio::time::timeout(std::time::Duration::from_secs(5), writer).await;
    Ok(())
}

async fn stdout_writer(mut rx: mpsc::Receiver<String>) {
    let mut out = tokio::io::stdout();
    while let Some(line) = rx.recv().await {
        if out.write_all(line.as_bytes()).await.is_err() || out.write_all(b"\n").await.is_err() {
            break;
        }
        let _ = out.flush().await;
    }
}

async fn send(tx: &mpsc::Sender<String>, event: Event) {
    match serde_json::to_string(&event) {
        Ok(line) => {
            let _ = tx.send(line).await;
        }
        // Serialisation cannot fail for these types, but a silent drop here
        // would look exactly like a hung daemon from Vim's side.
        Err(error) => eprintln!("simplemarkdown-daemon: could not encode an event: {error}"),
    }
}

// ─────────────────────────── CLI helpers ───────────────────────────

fn preview(args: &[String]) -> Result<(), String> {
    let path = args.first().ok_or("--preview needs a file")?;
    let width = match args.get(1) {
        Some(text) => text
            .parse::<usize>()
            .map_err(|_| format!("bad width: {text}"))?,
        None => 80,
    };
    let source = std::fs::read_to_string(path).map_err(|error| format!("{path}: {error}"))?;
    for line in render::render(&source, width.max(8), &protocol::Options::default()).lines {
        println!("{}", line.text);
    }
    Ok(())
}

/// Exercised by `install.sh` before the binary is put in place, so a build
/// whose renderer cannot lay out its own documentation never gets installed.
fn self_test() -> Result<(), String> {
    use unicode_width::UnicodeWidthStr;

    let source = include_str!("../../tests/fixtures/kitchen-sink.md");
    let known: HashSet<&str> = classes::ALL.iter().copied().collect();

    for width in [20usize, 40, 80, 120] {
        let output = render::render(source, width, &protocol::Options::default());
        if output.lines.is_empty() {
            return Err(format!("width {width}: the renderer produced nothing"));
        }
        for (index, line) in output.lines.iter().enumerate() {
            let row = index + 1;
            if line.text.width() > width {
                return Err(format!(
                    "width {width}: row {row} is {} columns wide: {:?}",
                    line.text.width(),
                    line.text
                ));
            }
            if line.text.contains('\n') || line.text.contains('\t') {
                return Err(format!(
                    "width {width}: row {row} contains a control character"
                ));
            }
            for prop in &line.props {
                if prop.0 < 1 || prop.0 + prop.1 - 1 > line.text.len() {
                    return Err(format!(
                        "width {width}: row {row} has a property outside the line: {prop:?}"
                    ));
                }
                if !line.text.is_char_boundary(prop.0 - 1)
                    || !line.text.is_char_boundary(prop.0 - 1 + prop.1)
                {
                    return Err(format!(
                        "width {width}: row {row} has a property split across a character: {prop:?}"
                    ));
                }
                if !known.contains(prop.2) {
                    return Err(format!(
                        "width {width}: unregistered property class {:?}",
                        prop.2
                    ));
                }
            }
        }
        for link in &output.links {
            let row = output
                .lines
                .get(link.row as usize - 1)
                .ok_or_else(|| format!("width {width}: link points at row {}", link.row))?;
            if link.col + link.len - 1 > row.text.len() {
                return Err(format!("width {width}: link {link:?} escapes its row"));
            }
        }
        for entry in &output.toc {
            if output.lines.get(entry.row as usize - 1).is_none() {
                return Err(format!(
                    "width {width}: table-of-contents row {} does not exist",
                    entry.row
                ));
            }
        }
    }

    // The handshake has to round-trip: the Vim side gates every feature on it.
    let pong = serde_json::to_string(&Event::Pong {
        id: 1,
        protocol_version: PROTOCOL_VERSION,
        version: env!("CARGO_PKG_VERSION"),
        capabilities: capabilities(),
    })
    .map_err(|error| error.to_string())?;
    if !pong.contains("\"type\":\"pong\"") {
        return Err("the handshake reply lost its type tag".to_string());
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn self_test_passes() {
        self_test().expect("the built-in self-test should pass");
    }

    #[test]
    fn render_requests_parse() {
        let line = r##"{"type":"render","id":7,"path":"a.md","lines":["# x"],"width":40}"##;
        match serde_json::from_str::<Request>(line).expect("parses") {
            Request::Render(request) => {
                assert_eq!(request.id, 7);
                assert_eq!(request.width, 40);
                // Absent options must land on the documented defaults, not on
                // Default::default() for bool.
                assert!(request.opts.unicode && request.opts.syntax && request.opts.wrap);
                assert_eq!(request.opts.tab_width, 4);
            }
            other => panic!("wrong variant: {other:?}"),
        }
    }

    #[test]
    fn options_are_individually_overridable() {
        let line = r#"{"type":"render","id":1,"lines":[],"opts":{"unicode":false,"max_width":72}}"#;
        match serde_json::from_str::<Request>(line).expect("parses") {
            Request::Render(request) => {
                assert!(!request.opts.unicode);
                assert_eq!(request.opts.max_width, 72);
                assert!(
                    request.opts.syntax,
                    "unmentioned options keep their default"
                );
            }
            other => panic!("wrong variant: {other:?}"),
        }
    }

    #[test]
    fn events_serialise_with_the_short_field_names() {
        let output = render::render("# hi\n", 20, &protocol::Options::default());
        let event = Event::RenderResult(Box::new(RenderResult {
            id: 1,
            width: 20,
            lines: output.lines,
            toc: output.toc,
            links: output.links,
            elapsed_ms: 0,
        }));
        let encoded = serde_json::to_string(&event).expect("encodes");
        assert!(encoded.contains(r#""type":"render_result""#));
        assert!(encoded.contains(r#""t":"▌ hi""#), "{encoded}");
        assert!(encoded.contains(r#""p":[[1,3,"HeadMark"]"#), "{encoded}");
    }

    #[test]
    fn blank_rows_carry_no_properties_or_source_line() {
        let output = render::render("a\n\nb\n", 20, &protocol::Options::default());
        let encoded = serde_json::to_string(&output.lines[1]).expect("encodes");
        assert_eq!(encoded, r#"{"t":""}"#);
    }

    #[test]
    fn every_emitted_class_is_declared() {
        // classes::ALL is what `--classes` prints and what the Vim side
        // registers property types for; a class emitted but not declared is a
        // hard prop_add() error inside a channel callback.
        let source = include_str!("../../tests/fixtures/kitchen-sink.md");
        let declared: HashSet<&str> = classes::ALL.iter().copied().collect();
        for line in render::render(source, 80, &protocol::Options::default()).lines {
            for prop in line.props {
                assert!(
                    declared.contains(prop.2),
                    "{:?} is not in classes::ALL",
                    prop.2
                );
            }
        }
    }

    #[test]
    fn a_document_of_only_blank_lines_is_harmless() {
        let output = render::render("\n\n\n", 40, &protocol::Options::default());
        assert!(output.lines.is_empty());
    }
}
