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

use protocol::{Event, Line, PROTOCOL_VERSION, Patch, RenderResult, Request};
use std::collections::{BTreeMap, HashMap, HashSet};
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
        ("incremental", true),
        ("blocks", true),
    ])
}

// ─────────────────────────── session state ───────────────────────────

/// What the client is holding for one preview window.
struct Session {
    /// The id of the render that produced `rows`.  Renders run concurrently on
    /// the blocking pool and can finish out of order; an answer older than the
    /// one already sent would describe a document the client has moved past.
    id: u64,
    rows: Vec<Line>,
}

/// A client that opens and closes previews all day should not grow the daemon
/// without bound.  `forget` is the tidy path; this is the backstop.
const MAX_SESSIONS: usize = 32;

type Sessions = Arc<Mutex<HashMap<String, Session>>>;

/// The rows that changed, as one splice.
///
/// Trimming the common prefix and then the common suffix finds exactly the run
/// an edit touched: typing in a paragraph reflows that paragraph and nothing
/// else, and both the rows above it and the rows below it compare equal.  It
/// cannot describe two edits in different places as two hunks — it will span
/// them — which is the right trade for a preview driven by a keystroke at a
/// time.
fn diff(prev: &[Line], next: &[Line]) -> Patch {
    let mut head = 0;
    while head < prev.len() && head < next.len() && prev[head] == next[head] {
        head += 1;
    }
    let mut tail = 0;
    while tail < prev.len() - head
        && tail < next.len() - head
        && prev[prev.len() - 1 - tail] == next[next.len() - 1 - tail]
    {
        tail += 1;
    }
    Patch {
        from: head + 1,
        del: prev.len() - head - tail,
        lines: next[head..next.len() - tail].to_vec(),
    }
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
    let sessions: Sessions = Arc::new(Mutex::new(HashMap::new()));

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
            Request::Forget { session } => {
                sessions.lock().await.remove(&session);
            }
            Request::Render(request) => {
                let tx = out_tx.clone();
                let cancelled = cancelled.clone();
                let sessions = sessions.clone();
                tokio::spawn(async move {
                    let id = request.id;
                    if cancelled.lock().await.remove(&id) {
                        return;
                    }
                    let started = Instant::now();
                    let width = request.width.max(8);
                    let opts = request.opts.clone();
                    let key = request.session.clone();
                    let incremental = request.incremental && !key.is_empty();
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

                    let total = output.lines.len();
                    let (lines, patch) = match key.is_empty() {
                        true => (Some(output.lines), None),
                        false => {
                            let mut sessions = sessions.lock().await;
                            if let Some(session) = sessions.get(&key)
                                && session.id > id
                            {
                                // A newer render for this window has already
                                // been answered; this one describes a document
                                // the client has moved past.
                                return;
                            }
                            // Trimming to a patch is only worth the splice when
                            // it is substantially smaller.  A rewrite of most of
                            // the document is cheaper for the client to take as
                            // a plain buffer replace.
                            let patch = incremental
                                .then(|| sessions.get(&key))
                                .flatten()
                                .map(|session| diff(&session.rows, &output.lines))
                                .filter(|patch| patch.lines.len() * 2 <= total);
                            if sessions.len() >= MAX_SESSIONS
                                && !sessions.contains_key(&key)
                                && let Some(evict) = sessions.keys().next().cloned()
                            {
                                sessions.remove(&evict);
                            }
                            sessions.insert(
                                key.clone(),
                                Session {
                                    id,
                                    rows: output.lines.clone(),
                                },
                            );
                            match patch {
                                Some(patch) => (None, Some(patch)),
                                None => (Some(output.lines), None),
                            }
                        }
                    };

                    send(
                        &tx,
                        Event::RenderResult(Box::new(RenderResult {
                            id,
                            width,
                            total,
                            lines,
                            patch,
                            toc: output.toc,
                            links: output.links,
                            blocks: output.blocks,
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

    // Every optional decoration is checked too: the gutter and the stripe both
    // add columns and properties, and a layout that only holds together with
    // them off is not one worth installing.
    let variants = [
        protocol::Options::default(),
        protocol::Options {
            code_numbers: true,
            table_zebra: true,
            show_urls: true,
            ..protocol::Options::default()
        },
        // `wrap: false` is deliberately not here: it is documented to produce
        // one long row per paragraph and scroll the window sideways, so the
        // width invariant below does not apply to it.
        protocol::Options {
            unicode: false,
            code_wrap: false,
            code_numbers: true,
            ..protocol::Options::default()
        },
    ];

    for (width, opts) in [20usize, 40, 80, 120]
        .into_iter()
        .flat_map(|width| variants.iter().map(move |opts| (width, opts)))
    {
        let output = render::render(source, width, opts);
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
        let total = output.lines.len();
        let event = Event::RenderResult(Box::new(RenderResult {
            id: 1,
            width: 20,
            total,
            lines: Some(output.lines),
            patch: None,
            toc: output.toc,
            links: output.links,
            blocks: output.blocks,
            elapsed_ms: 0,
        }));
        let encoded = serde_json::to_string(&event).expect("encodes");
        assert!(encoded.contains(r#""type":"render_result""#));
        assert!(encoded.contains(r#""t":"▌ hi""#), "{encoded}");
        assert!(encoded.contains(r#""p":[[1,3,"HeadMark"]"#), "{encoded}");
        // A full reply carries no patch key at all, so the client can branch
        // on its presence rather than on a null.
        assert!(!encoded.contains(r#""patch""#), "{encoded}");
    }

    #[test]
    fn a_patch_describes_only_the_rows_that_moved() {
        let before = render::render(
            "# title\n\npara one\n\npara two\n",
            40,
            &protocol::Options::default(),
        );
        let after = render::render(
            "# title\n\npara one edited\n\npara two\n",
            40,
            &protocol::Options::default(),
        );
        let patch = diff(&before.lines, &after.lines);
        assert_eq!(patch.lines.len(), 1, "one paragraph reflowed to one row");
        assert_eq!(patch.del, 1);
        assert!(patch.lines[0].text.contains("para one edited"));

        // Applying it must reproduce the new document exactly — that is the
        // whole contract with the Vim side.
        let mut applied = before.lines;
        applied.splice(patch.from - 1..patch.from - 1 + patch.del, patch.lines);
        assert_eq!(applied, after.lines);
    }

    #[test]
    fn a_patch_can_be_a_pure_insertion_or_deletion() {
        let short = render::render("a\n\nb\n", 40, &protocol::Options::default());
        let long = render::render("a\n\nnew\n\nb\n", 40, &protocol::Options::default());

        let insert = diff(&short.lines, &long.lines);
        let mut applied = short.lines.clone();
        applied.splice(insert.from - 1..insert.from - 1 + insert.del, insert.lines);
        assert_eq!(applied, long.lines);

        let delete = diff(&long.lines, &short.lines);
        let mut applied = long.lines.clone();
        applied.splice(delete.from - 1..delete.from - 1 + delete.del, delete.lines);
        assert_eq!(applied, short.lines);
    }

    #[test]
    fn an_unchanged_document_patches_to_nothing() {
        let output = render::render("# same\n\nbody\n", 40, &protocol::Options::default());
        let patch = diff(&output.lines, &output.lines);
        assert_eq!(patch.del, 0);
        assert!(patch.lines.is_empty());
    }

    #[test]
    fn blocks_cover_the_document_and_map_back_to_source() {
        let source = "# heading\n\nparagraph text\n\n```rust\nfn main() {}\n```\n";
        let output = render::render(source, 40, &protocol::Options::default());
        assert_eq!(output.blocks.len(), 3, "{:?}", output.blocks);
        for block in &output.blocks {
            let (row, rows, first, last) = (block.0, block.1, block.2, block.3);
            assert!(rows >= 1, "a block with no rows should not be indexed");
            assert!(
                row as usize + rows as usize - 1 <= output.lines.len(),
                "block {block:?} runs past the document"
            );
            assert!(first >= 1 && last >= first, "bad source range in {block:?}");
        }
        // The fence is three source lines and the block index must say so.
        let fence = output.blocks.last().expect("three blocks");
        assert_eq!(fence.3 - fence.2, 2);
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
