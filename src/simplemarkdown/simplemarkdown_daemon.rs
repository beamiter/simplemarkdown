//! simplemarkdown — the Markdown preview backend for the Vim plugin.
//!
//! Reads JSON-lines requests on stdin, writes JSON-lines events on stdout.
//! Rendering happens on the blocking pool, and a request the editor has since
//! withdrawn is dropped before it starts: typing in a large document queues a
//! render per keystroke burst, and Vim only ever wants the answer to the last.

mod classes;
mod edit;
mod format;
mod glyphs;
mod highlight;
mod html;
mod inline;
mod lint;
mod md;
mod outline;
mod protocol;
mod render;
mod serve;
mod table;

use protocol::{
    Event, HtmlRequest, Line, PROTOCOL_VERSION, PageOptions, Patch, RenderResult, Request,
    ServeRequest, SrcPatch,
};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::io::Write as StdWrite;
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::Instant;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, BufReader};
use tokio::sync::{Mutex, mpsc};

const USAGE: &str = "\
Usage: simplemarkdown-daemon [OPTION]

With no option the daemon speaks the JSON-lines protocol on stdin/stdout.

  --preview FILE [WIDTH]  render FILE to plain text and exit (default width 80)
  --html FILE [THEME]     write the browser preview's page for FILE to stdout
                          (THEME is auto, light or dark; default auto)
  --bench FILE [WIDTH] [RUNS]
                          time repeated renders of FILE and the patch one edit
                          produces (default width 80, 20 runs)
  --classes               list every text-property class the renderer emits
  --codes                 list every diagnostic code `:SimpleMarkdownLint` emits
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
        ("format", true),
        ("edit", true),
        ("lint", true),
        ("outline", true),
        ("serve", true),
        ("html", true),
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
    /// Fingerprints of the three whole-document indexes this session was last
    /// sent, so an unchanged one can be left out of the next reply.
    indexes: Indexes,
}

/// The outline, the link spans and the block index, by fingerprint.
///
/// All three describe the whole document however little of it moved, and on a
/// small patch they are the reply: measured on an 1,800-row document, an
/// 84-byte patch travelled inside a 32,864-byte answer, and Vim parses that
/// JSON on the main thread on every keystroke.
#[derive(Default, PartialEq, Eq, Clone, Copy)]
struct Indexes {
    toc: u64,
    links: u64,
    blocks: u64,
}

impl Indexes {
    fn of(output: &render::Output) -> Self {
        Self {
            toc: fingerprint(&output.toc),
            links: fingerprint(&output.links),
            blocks: fingerprint(&output.blocks),
        }
    }
}

/// Which indexes a particular reply has to carry.
#[derive(Clone, Copy)]
struct Carry {
    toc: bool,
    links: bool,
    blocks: bool,
}

impl Carry {
    fn everything() -> Self {
        Self {
            toc: true,
            links: true,
            blocks: true,
        }
    }
}

fn fingerprint<T: std::hash::Hash>(value: &T) -> u64 {
    use std::hash::Hasher;
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    value.hash(&mut hasher);
    hasher.finish()
}

/// A client that opens and closes previews all day should not grow the daemon
/// without bound.  `forget` is the tidy path; this is the backstop.
const MAX_SESSIONS: usize = 32;

/// How many withdrawn render ids to remember.  An entry is normally removed by
/// the render it cancels, but a cancel that loses the race against its own
/// reply has nothing left to remove it — and a long typing session cancels a
/// render per keystroke burst, so those strays are a slow leak.
const MAX_CANCELLED: usize = 256;

#[derive(Default)]
struct CancelledRequests {
    ids: HashSet<u64>,
    order: VecDeque<u64>,
}

impl CancelledRequests {
    fn remove(&mut self, id: &u64) -> bool {
        if !self.ids.remove(id) {
            return false;
        }
        // The table is deliberately tiny. Keeping the order queue exact avoids
        // a stale occurrence evicting a newly reused id later.
        self.order.retain(|pending| pending != id);
        true
    }

    #[cfg(test)]
    fn contains(&self, id: &u64) -> bool {
        self.ids.contains(id)
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.ids.len()
    }
}

/// Remember that render `id` has been withdrawn, retaining the most recently
/// received cancellations. The editor emits increasing ids, but the wire is a
/// public protocol: a reconnecting or malformed client can send them out of
/// order, and that must not defeat the memory bound.
fn note_cancelled(cancelled: &mut CancelledRequests, id: u64) {
    if cancelled.ids.insert(id) {
        cancelled.order.push_back(id);
    }
    while cancelled.ids.len() > MAX_CANCELLED {
        if let Some(oldest) = cancelled.order.pop_front() {
            cancelled.ids.remove(&oldest);
        } else {
            break;
        }
    }
}

/// The session to drop when the table is full: the one whose last render is
/// oldest.  `keys().next()` is whatever the hash order happens to offer, which
/// can evict the window the user is looking at and leave one closed hours ago.
fn stalest_session(sessions: &HashMap<String, Session>) -> Option<String> {
    sessions
        .iter()
        .min_by_key(|(_, session)| session.id)
        .map(|(key, _)| key.clone())
}

/// A browser preview whose socket the daemon is holding open.
///
/// One per previewed buffer, keyed by the editor's session string.  It outlives
/// every request that touches it — that is the difference between this and a
/// render — so it is the one piece of daemon state that has to be torn down
/// explicitly rather than dropped when a task ends.
struct Preview {
    server: serve::Server,
    /// The document's file name, for rebuilding the page options when the
    /// editor changes one of them.
    name: String,
    /// What the page was started with.  An update re-renders with the same
    /// options rather than carrying them again on every keystroke.
    opts: html::Options,
    /// Which preview this is, across the life of the daemon.  The session key is
    /// reused — a buffer previewed, closed and previewed again is the same key —
    /// and `issued`/`served` start over with each one, so an update still
    /// rendering when its preview was replaced would find a sequence number it
    /// compares favourably against and push the old preview's document to the
    /// new one's browser.
    epoch: u64,
    /// Updates handed out, and the newest one that reached the browser.
    /// Renders finish on the blocking pool and can overtake one another, and a
    /// page left showing the older of two keystrokes looks broken until the
    /// next one happens to arrive.
    issued: u64,
    served: u64,
}

/// Hands out [`Preview::epoch`].  A plain counter: it only ever has to tell one
/// preview from the one it replaced.
static PREVIEW_EPOCH: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn next_epoch() -> u64 {
    PREVIEW_EPOCH.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
}

/// A browser preview costs a socket, a port and a copy of the document.  The
/// editor opens one per buffer and closes them with the buffer, so this is a
/// backstop against a client that has lost count, not a policy.
const MAX_PREVIEWS: usize = 16;

type Sessions = Arc<Mutex<HashMap<String, Session>>>;
type Cancelled = Arc<Mutex<CancelledRequests>>;
type Previews = Arc<Mutex<HashMap<String, Preview>>>;

/// One outline request, from the spawn to the reply — or to neither, if the
/// editor withdrew it on the way.
///
/// Withdrawable for the same reason a render is.  An outline carries the whole
/// document and costs a whole `pulldown-cmark` parse, and the client asks for
/// one on every edit it has folds for — so the request that is already moot
/// when it is picked up, or moot by the time the parse finishes, is the common
/// case rather than the odd one.  Hence the two checks: the first is the cancel
/// that overtook the request in the queue, the second is the one that arrived
/// while the parse was running, which is what an ordinary supersede looks like.
///
/// A function rather than the block it used to be so that the second check can
/// be held by a test: a cancel timed to land mid-parse over a channel nobody
/// has to read from a pipe.
#[derive(Clone)]
struct EventTx {
    sender: mpsc::Sender<String>,
    stalled: Arc<AtomicBool>,
}

impl EventTx {
    fn new(sender: mpsc::Sender<String>) -> Self {
        Self {
            sender,
            stalled: Arc::new(AtomicBool::new(false)),
        }
    }

    fn is_stalled(&self) -> bool {
        self.stalled.load(Ordering::Acquire)
    }
}

async fn walk_outline(id: u64, lines: Vec<String>, cancelled: Cancelled, tx: EventTx) {
    if cancelled.lock().await.remove(&id) {
        return;
    }
    let walked = tokio::task::spawn_blocking(move || outline::outline(&lines)).await;
    if cancelled.lock().await.remove(&id) {
        return;
    }
    let event = match walked {
        Ok(toc) => Event::OutlineResult { id, toc },
        Err(error) => Event::Error {
            id,
            message: format!("outline failed: {error}"),
        },
    };
    send(&tx, event).await;
}

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
    let mut patch = Patch {
        from: head + 1,
        del: prev.len() - head - tail,
        lines: next[head..next.len() - tail].to_vec(),
        src: None,
    };
    // The rows the trim left alone look the same but need not have come from
    // the same source lines — that is the whole reason `Line` no longer
    // compares `src` — so the map is repaired as a second, independent step,
    // computed against exactly what the client will be holding once it has
    // spliced the rows in.
    patch.src = src_correction(&spliced_src(prev, &patch), next);
    patch
}

/// The row → source map the client ends up with after applying `patch`'s rows.
fn spliced_src(prev: &[Line], patch: &Patch) -> Vec<u32> {
    let mut map: Vec<u32> = prev.iter().map(|line| line.src).collect();
    map.splice(
        patch.from - 1..patch.from - 1 + patch.del,
        patch.lines.iter().map(|line| line.src),
    );
    map
}

/// What still has to happen to `applied` for it to be the new document's map.
///
/// Almost always one integer: `n` lines inserted anywhere above moves every
/// row below by `n`, and both a shifted prefix (a row whose *appearance* did
/// not change, so the diff kept it) and a shifted suffix are covered by the
/// same rule.  Sending the entries in full is the honest answer when a single
/// delta cannot describe them, and even then it is only the rows from the
/// first disagreement on.
fn src_correction(applied: &[u32], next: &[Line]) -> Option<SrcPatch> {
    debug_assert_eq!(applied.len(), next.len());
    let start = applied
        .iter()
        .zip(next)
        .position(|(have, want)| *have != want.src)?;

    let mut delta: Option<i64> = None;
    let mut shiftable = true;
    for (have, want) in applied[start..].iter().zip(&next[start..]) {
        // A row that came from no particular source line — a box border, a
        // blank spacer — is 0 on both sides and the client leaves it alone.  A
        // row that gained or lost one is not something a shift can express.
        if *have == 0 || want.src == 0 {
            if *have == want.src {
                continue;
            }
            shiftable = false;
            break;
        }
        let moved = i64::from(want.src) - i64::from(*have);
        match delta {
            None => delta = Some(moved),
            Some(seen) if seen == moved => {}
            Some(_) => {
                shiftable = false;
                break;
            }
        }
    }

    if shiftable && let Some(moved) = delta {
        return Some(SrcPatch {
            from: start + 1,
            delta: moved,
            tail: None,
        });
    }
    Some(SrcPatch {
        from: start + 1,
        delta: 0,
        tail: Some(next[start..].iter().map(|line| line.src).collect()),
    })
}

/// Roughly what a set of rows costs on the wire, for deciding whether a patch
/// is worth the splice.  Counting rows instead — what this used to do — says a
/// patch of ten table rows is smaller than a document of a thousand blank ones,
/// which is backwards.
fn wire_size(lines: &[Line]) -> usize {
    lines
        .iter()
        .map(|line| line.text.len() + line.props.len() * 24 + 16)
        .sum()
}

fn patch_size(patch: &Patch) -> usize {
    wire_size(&patch.lines)
        + match &patch.src {
            Some(SrcPatch {
                tail: Some(tail), ..
            }) => tail.len() * 5,
            _ => 0,
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
        Some("--codes") => {
            for (code, description) in lint::codes::ALL {
                println!("{code}\t{description}");
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
        Some("--bench") => match bench(&args[1..]) {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(message) => {
                eprintln!("simplemarkdown-daemon: {message}");
                std::process::ExitCode::FAILURE
            }
        },
        Some("--html") => match html_page(&args[1..]) {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(message) => {
                eprintln!("simplemarkdown-daemon: {message}");
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

/// Render requests carry the document in one JSONL record. Keep the limit high
/// enough for a genuinely large Markdown file, but finite so a broken client
/// cannot grow one unterminated line until the daemon exhausts memory.
const MAX_REQUEST_LINE_BYTES: usize = 64 * 1024 * 1024;

fn finish_request_line(mut bytes: Vec<u8>, too_long: bool, limit: usize) -> Result<String, String> {
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    if too_long || bytes.len() > limit {
        return Err(format!("request line exceeds {limit} bytes"));
    }
    String::from_utf8(bytes).map_err(|_| "request line is not valid UTF-8".to_string())
}

/// Read one bounded JSONL record and discard the rest of an oversized record
/// through its newline, so a valid request immediately after it is still read.
async fn read_request_line<R>(
    reader: &mut R,
    limit: usize,
) -> std::io::Result<Option<Result<String, String>>>
where
    R: AsyncBufRead + Unpin,
{
    let mut bytes = Vec::new();
    let mut too_long = false;

    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return if bytes.is_empty() && !too_long {
                Ok(None)
            } else {
                Ok(Some(finish_request_line(bytes, too_long, limit)))
            };
        }

        let newline = available.iter().position(|byte| *byte == b'\n');
        let content_len = newline.unwrap_or(available.len());
        let consumed = newline.map_or(available.len(), |position| position + 1);
        if !too_long {
            // Keep one extra byte until the record ends: for CRLF that byte is
            // the framing CR, not part of the JSON line's documented limit.
            if bytes.len().saturating_add(content_len) > limit.saturating_add(1) {
                bytes.clear();
                too_long = true;
            } else {
                bytes.extend_from_slice(&available[..content_len]);
            }
        }
        reader.consume(consumed);

        if newline.is_some() {
            return Ok(Some(finish_request_line(bytes, too_long, limit)));
        }
    }
}

async fn serve() -> std::io::Result<()> {
    let (sender, out_rx) = mpsc::channel::<String>(256);
    let out_tx = EventTx::new(sender);
    let (writer_done_tx, writer_done_rx) = std::sync::mpsc::channel();
    let writer = std::thread::spawn(move || {
        stdout_writer(out_rx);
        let _ = writer_done_tx.send(());
    });

    // Requests the editor has withdrawn.  Checked twice — when the render is
    // picked up and again when it finishes — because a document large enough
    // to be worth cancelling is also large enough to be cancelled mid-flight.
    let cancelled: Cancelled = Arc::new(Mutex::new(CancelledRequests::default()));
    let sessions: Sessions = Arc::new(Mutex::new(HashMap::new()));
    let previews: Previews = Arc::new(Mutex::new(HashMap::new()));

    let mut stdin = BufReader::new(tokio::io::stdin());
    loop {
        if out_tx.is_stalled() {
            break;
        }
        let Some(line) = read_request_line(&mut stdin, MAX_REQUEST_LINE_BYTES).await? else {
            break;
        };
        let line = match line {
            Ok(line) => line,
            Err(message) => {
                send(&out_tx, Event::Error { id: 0, message }).await;
                continue;
            }
        };
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
                note_cancelled(&mut *cancelled.lock().await, id);
            }
            Request::Forget { session } => {
                sessions.lock().await.remove(&session);
            }
            Request::Outline { id, lines } => {
                tokio::spawn(walk_outline(id, lines, cancelled.clone(), out_tx.clone()));
            }
            Request::Lint { id, lines } => {
                let tx = out_tx.clone();
                tokio::spawn(async move {
                    let source = lines.join("\n");
                    let linted = tokio::task::spawn_blocking(move || lint::lint(&source)).await;
                    let event = match linted {
                        Ok(items) => Event::LintResult { id, items },
                        Err(error) => Event::Error {
                            id,
                            message: format!("lint failed: {error}"),
                        },
                    };
                    send(&tx, event).await;
                });
            }
            Request::FormatTable { id, lines, line } => {
                // Off the reactor like a render: the parse is over the whole
                // buffer, and a document large enough to be worth formatting a
                // table in is large enough to stall a keystroke's preview.
                let tx = out_tx.clone();
                tokio::spawn(async move {
                    let found =
                        tokio::task::spawn_blocking(move || format::table_at(&lines, line)).await;
                    let event = match found {
                        Ok(Some(replacement)) => Event::FormatResult {
                            id,
                            from: replacement.from,
                            to: replacement.to,
                            lines: replacement.lines,
                        },
                        Ok(None) => Event::FormatResult {
                            id,
                            from: 0,
                            to: 0,
                            lines: Vec::new(),
                        },
                        Err(error) => Event::Error {
                            id,
                            message: format!("format failed: {error}"),
                        },
                    };
                    send(&tx, event).await;
                });
            }
            Request::Edit {
                id,
                op,
                lines,
                from,
                to,
            } => {
                let tx = out_tx.clone();
                let Some(op) = edit::Op::parse(&op) else {
                    send(
                        &tx,
                        Event::Error {
                            id,
                            message: format!("unknown edit op: {op}"),
                        },
                    )
                    .await;
                    continue;
                };
                // Off the reactor for the same reason a format is: the parse is
                // over the whole buffer, and the buffer belongs to someone who
                // is also waiting for their next keystroke to be rendered.
                tokio::spawn(async move {
                    let done = tokio::task::spawn_blocking(move || {
                        edit::edit(op, &lines, from.max(1), to.max(from.max(1)))
                    })
                    .await;
                    let event = match done {
                        Ok(Ok(edits)) => Event::EditResult { id, edits },
                        // A refusal is the answer to a question a user asked and
                        // is worth showing them verbatim ("promoting would take
                        // \"Top\" past H1"); a panic is not.
                        Ok(Err(message)) => Event::Error { id, message },
                        Err(error) => Event::Error {
                            id,
                            message: format!("edit failed: {error}"),
                        },
                    };
                    send(&tx, event).await;
                });
            }
            Request::Serve(request) => {
                tokio::spawn(serve_start(*request, previews.clone(), out_tx.clone()));
            }
            Request::ServeUpdate {
                session,
                lines,
                line,
            } => {
                tokio::spawn(serve_update(session, lines, line, previews.clone()));
            }
            Request::ServeOpts { session, page } => {
                let mut table = previews.lock().await;
                if let Some(preview) = table.get_mut(&session) {
                    // The document options can change too — syntax off, front
                    // matter hidden — and those need a re-render, which the
                    // next `serve_update` does with the options stored here.
                    preview.opts = html_options(&page);
                    let name = preview.name.clone();
                    preview.server.set_opts(page_options(name, &page));
                }
            }
            Request::ServeCursor { session, line } => {
                if let Some(preview) = previews.lock().await.get(&session) {
                    preview.server.cursor(line);
                }
            }
            Request::ServeStop { session, all } => {
                let mut table = previews.lock().await;
                if all {
                    for (_, preview) in table.drain() {
                        preview.server.stop();
                    }
                } else if let Some(preview) = table.remove(&session) {
                    preview.server.stop();
                }
            }
            Request::Html(request) => {
                tokio::spawn(html_once(*request, out_tx.clone()));
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
                    let src_sum: u64 = output.lines.iter().map(|line| u64::from(line.src)).sum();
                    let indexes = Indexes::of(&output);
                    // Which of the three indexes this reply has to carry.  A
                    // client that says `incremental` is holding what it was
                    // last sent; one that does not has thrown it away — a
                    // placeholder, a fresh window — and needs all three back.
                    // A session-less render always carries them: there is
                    // nothing remembering what that client has.
                    let mut carry = Carry::everything();
                    let mut output = output;
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
                            let full_size = wire_size(&output.lines);
                            let patch = incremental
                                .then(|| sessions.get(&key))
                                .flatten()
                                .map(|session| diff(&session.rows, &output.lines))
                                .filter(|patch| patch_size(patch) * 2 <= full_size);
                            let sent = incremental
                                .then(|| sessions.get(&key))
                                .flatten()
                                .map_or(Indexes::default(), |session| session.indexes);
                            carry = Carry {
                                toc: sent.toc != indexes.toc,
                                links: sent.links != indexes.links,
                                blocks: sent.blocks != indexes.blocks,
                            };
                            if sessions.len() >= MAX_SESSIONS
                                && !sessions.contains_key(&key)
                                && let Some(evict) = stalest_session(&sessions)
                            {
                                sessions.remove(&evict);
                            }
                            sessions.insert(
                                key.clone(),
                                Session {
                                    id,
                                    rows: output.lines.clone(),
                                    indexes,
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
                            src_sum,
                            lines,
                            patch,
                            toc: carry.toc.then(|| std::mem::take(&mut output.toc)),
                            links: carry.links.then(|| std::mem::take(&mut output.links)),
                            blocks: carry.blocks.then(|| std::mem::take(&mut output.blocks)),
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
    // A browser preview is the one thing here that survives its request, so it
    // is the one thing that has to be closed on the way out.  Dropping the
    // runtime would do it, but not before the accept loops had been cancelled
    // mid-write, which is how a browser ends up waiting on a stream nobody is
    // ever going to finish.
    for (_, preview) in previews.lock().await.drain() {
        preview.server.stop();
    }

    drop(out_tx);
    if writer_done_rx
        .recv_timeout(std::time::Duration::from_secs(5))
        .is_ok()
    {
        let _ = writer.join();
    }
    Ok(())
}

// ─────────────────────────── the browser preview ───────────────────────────

/// The document, as the page renderer wants it.
fn html_options(page: &PageOptions) -> html::Options {
    html::Options {
        syntax: page.syntax,
        frontmatter: page.frontmatter,
        // `$…$` is only worth parsing as math when something is going to typeset
        // it; left on with no engine it would strip the dollars off prose that
        // merely mentions a price.
        math: page.math != "off",
    }
}

/// The page around it.
///
/// `name` is what the path says the document is called; `page.name` is what
/// the editor says it is called, and it wins when it has anything to say.  A
/// document open in a remote workspace is served out of a staging directory
/// whose file name — `main.md` — is the same for every host, and the editor is
/// the only side that knows which one it came from.
fn page_options(name: String, page: &PageOptions) -> html::PageOptions {
    html::PageOptions {
        name: if page.name.is_empty() {
            name
        } else {
            page.name.clone()
        },
        theme: page.theme.clone(),
        math: page.math.clone(),
        math_url: page.math_url.clone(),
        max_width: page.max_width,
        live: page.live,
        follow: page.follow,
        sync_back: page.sync_back,
    }
}

/// Whether this bind is reachable only from this machine.  A second asset
/// directory is offered on that condition and no other.
fn is_loopback(host: &str) -> bool {
    matches!(host, "127.0.0.1" | "localhost" | "::1" | "[::1]")
}

/// The document's directory — the first one the server will hand a file out of —
/// and the name to put in the title bar.
fn document_root(path: &str) -> (PathBuf, String) {
    let path = PathBuf::from(path);
    let name = path.file_name().map_or_else(
        || "markdown".to_string(),
        |name| name.to_string_lossy().into_owned(),
    );
    // A path that names a directory is its own root.  Taking its parent would
    // put everything beside it inside the served tree, a level of the
    // filesystem nobody asked for — and the editor sends whatever the buffer is
    // called, which can be a directory listing.  Asked of the filesystem rather
    // than guessed from the spelling, because a directory is allowed to be
    // called `notes.md`.
    if path.is_dir() {
        return (path, name);
    }
    let root = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .map_or_else(|| PathBuf::from("."), Path::to_path_buf);
    (root, name)
}

async fn render_page(source: String, opts: html::Options) -> Result<html::Page, String> {
    // Off the reactor for the same reason a terminal render is: syntect over a
    // long document is tens of milliseconds of one core, and the editor is
    // waiting for its next keystroke to be laid out on the same runtime.
    tokio::task::spawn_blocking(move || html::render(&source, &opts))
        .await
        .map_err(|error| format!("render failed: {error}"))
}

async fn serve_start(request: ServeRequest, previews: Previews, tx: EventTx) {
    let id = request.id;
    let session = request.session.clone();
    let (root, name) = document_root(&request.path);
    let opts = html_options(&request.page);

    let page = match render_page(request.lines.join("\n"), opts.clone()).await {
        Ok(page) => page,
        Err(message) => {
            send(&tx, Event::Error { id, message }).await;
            return;
        }
    };

    let sync_back = request.page.sync_back;
    let config = serve::Config {
        host: request.host.clone(),
        port: request.port,
        attempts: request.attempts.max(1),
        root,
        // Widened only on a loopback bind: the editor checks that too, and a
        // setting that quietly turned a shared preview into a file server for
        // the directory above the document is not a setting anybody asked for.
        extra_root: (!request.root.is_empty() && is_loopback(&request.host))
            .then(|| PathBuf::from(&request.root)),
        page,
        page_opts: page_options(name.clone(), &request.page),
    };
    let mut server = match serve::Server::start(config).await {
        Ok(server) => server,
        Err(error) => {
            send(
                &tx,
                Event::Error {
                    id,
                    message: format!(
                        "no free port in {}-{} on {}: {error}",
                        request.port,
                        request.port.saturating_add(request.attempts.max(1) - 1),
                        request.host
                    ),
                },
            )
            .await;
            return;
        }
    };

    // The page only reports where the reader scrolled to when it was told the
    // editor wants to know; forwarding it otherwise would move the cursor of
    // someone who asked for a preview, not for a remote control.
    if sync_back && let Some(mut scrolled) = server.sync_back() {
        let tx = tx.clone();
        let session = session.clone();
        tokio::spawn(async move {
            while let Some(line) = scrolled.recv().await {
                send(
                    &tx,
                    Event::ServeScrolled {
                        session: session.clone(),
                        line,
                    },
                )
                .await;
            }
        });
    }

    let url = server.url().to_string();
    let port = server.port();

    // Everything that decides this preview's fate happens under one lock, held
    // across no await.  The table used to be cleared of any old entry before
    // the bind and written after it, with the lock dropped in between — and two
    // `serve` requests for the same session, which the editor cannot prevent
    // because it only learns a preview exists when the *reply* arrives, then
    // both found the slot empty.  Whichever lost the insert became a listener
    // nobody held a handle to, and `Server` deliberately has no `Drop` that
    // stops one, so that server and its port were held until the daemon exited.
    let displaced = {
        let mut table = previews.lock().await;
        if table.len() >= MAX_PREVIEWS && !table.contains_key(&session) {
            // The table filled while this one was binding.  Its port goes back
            // here rather than being held by a preview that is being refused:
            // dropping the handle is exactly what does not stop a server.
            server.stop();
            None
        } else {
            Some(table.insert(
                session.clone(),
                Preview {
                    server,
                    name,
                    opts,
                    epoch: next_epoch(),
                    issued: 0,
                    served: 0,
                },
            ))
        }
    };

    let Some(displaced) = displaced else {
        send(
            &tx,
            Event::Error {
                id,
                message: format!("{MAX_PREVIEWS} browser previews are already running"),
            },
        )
        .await;
        return;
    };

    // A second `:SimpleMarkdownExternal` on a buffer that already has one means
    // "again", not "another", and so does losing the race above: whatever this
    // replaced is stopped, so its port comes back and the reader is not left
    // with two tabs disagreeing.
    if let Some(previous) = displaced {
        previous.server.stop();
    }

    send(
        &tx,
        Event::ServeResult {
            id,
            session,
            url,
            port,
        },
    )
    .await;
}

async fn serve_update(session: String, lines: Vec<String>, line: usize, previews: Previews) {
    let (opts, epoch, seq) = {
        let mut table = previews.lock().await;
        let Some(preview) = table.get_mut(&session) else {
            // The editor closed this preview while the keystroke that produced
            // this update was still in the pipe.  Not an error, and not worth a
            // reply to a request that never had one.
            return;
        };
        preview.issued += 1;
        (preview.opts.clone(), preview.epoch, preview.issued)
    };

    let Ok(page) = render_page(lines.join("\n"), opts).await else {
        return;
    };

    let mut table = previews.lock().await;
    let Some(preview) = table.get_mut(&session) else {
        return;
    };
    // A different preview under the same key: this document belongs to a page
    // that has already been closed, and the sequence it was measured against
    // went with it.
    if preview.epoch != epoch || seq <= preview.served {
        return;
    }
    preview.served = seq;
    preview.server.update(page);
    if line > 0 {
        preview.server.cursor(line);
    }
}

async fn html_once(request: HtmlRequest, tx: EventTx) {
    let id = request.id;
    let (root, name) = document_root(&request.path);
    let opts = html_options(&request.page);
    let page_opts = page_options(name, &request.page);
    match render_page(request.lines.join("\n"), opts).await {
        Ok(mut page) => {
            let body = std::mem::take(&mut page.body);
            // Reading files is blocking work, and a page full of screenshots is
            // several megabytes of it.
            page.body = tokio::task::spawn_blocking(move || inline_images(&root, body))
                .await
                .unwrap_or_default();
            let html = html::document(&page, &page_opts, 0);
            send(&tx, Event::HtmlResult { id, html }).await;
        }
        Err(message) => send(&tx, Event::Error { id, message }).await,
    }
}

/// The largest picture worth carrying inside the page, and the most the page
/// may carry in total.
///
/// This is a file somebody is going to open from a temporary directory, keep,
/// or mail.  A relative `src` in it points at nothing — the picture is beside
/// the *document*, which is somewhere else — so the picture travels or it is
/// broken, and there is no third answer.  The caps are what keeps "self
/// contained" from meaning "forty megabytes of screenshots".
const INLINE_MAX_FILE: u64 = 4 * 1024 * 1024;
const INLINE_MAX_TOTAL: usize = 16 * 1024 * 1024;

/// Rewrite every `src="…"` that names a readable file under `root` as a `data:`
/// URI, so the one-shot page carries its pictures the way it already carries
/// its stylesheet.
///
/// Deliberately only `src`: an `href` is a link, and a link that led somewhere
/// on the author's disk is more useful left alone than turned into a copy of
/// whatever was there.  A path that leaves `root` is refused by the same guard
/// the server uses, for the same reason.
fn inline_images(root: &Path, body: String) -> String {
    const ATTR: &str = " src=\"";
    if !body.contains(ATTR) {
        return body;
    }
    let body = body.as_str();
    let mut out = String::with_capacity(body.len());
    let mut rest = body;
    let mut budget = INLINE_MAX_TOTAL;
    while let Some(at) = rest.find(ATTR) {
        let after = at + ATTR.len();
        let Some(end) = rest[after..].find('"') else {
            break;
        };
        let value = &rest[after..after + end];
        out.push_str(&rest[..after]);
        match inline_one(root, value, &mut budget) {
            Some(data) => out.push_str(&data),
            None => out.push_str(value),
        }
        rest = &rest[after + end..];
    }
    out.push_str(rest);
    out
}

fn inline_one(root: &Path, value: &str, budget: &mut usize) -> Option<String> {
    // Anything with a scheme is already somewhere the reader can reach, and a
    // `data:` URI is one of ours from a previous pass.
    if value.is_empty() || value.contains("://") || value.starts_with("data:") {
        return None;
    }
    // `./pic.png` is what the document wrote and what the page carries; a
    // browser resolves it away before it ever reaches the server, so the guard
    // the server uses has never had to accept it.  `../` is still refused —
    // the same answer the server gives, for the same reason.
    let mut relative = value.trim_start_matches('/');
    while let Some(rest) = relative.strip_prefix("./") {
        relative = rest;
    }
    let target = format!("/{relative}");
    let path = serve::safe_join(root, &target)?;
    let size = std::fs::metadata(&path).ok()?.len();
    if size > INLINE_MAX_FILE || size as usize > *budget {
        return None;
    }
    let bytes = std::fs::read(&path).ok()?;
    *budget = budget.saturating_sub(bytes.len());
    Some(format!(
        "data:{};base64,{}",
        serve::content_type(&path),
        base64(&bytes)
    ))
}

/// Base64, written out rather than depended on: this is the only place in the
/// daemon that needs it, and a crate for forty lines is a crate to keep
/// updated.
fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let block = match chunk {
            [a] => u32::from(*a) << 16,
            [a, b] => (u32::from(*a) << 16) | (u32::from(*b) << 8),
            [a, b, c] => (u32::from(*a) << 16) | (u32::from(*b) << 8) | u32::from(*c),
            _ => unreachable!("chunks(3) yields one, two or three"),
        };
        for index in 0..4 {
            if index <= chunk.len() {
                let shift = 18 - index * 6;
                out.push(char::from(ALPHABET[((block >> shift) & 0x3f) as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

fn stdout_writer(mut rx: mpsc::Receiver<String>) {
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    while let Some(line) = rx.blocking_recv() {
        if out.write_all(line.as_bytes()).is_err() || out.write_all(b"\n").is_err() {
            break;
        }
        let _ = out.flush();
    }
}

async fn send(tx: &EventTx, event: Event) {
    if tx.is_stalled() {
        return;
    }
    match serde_json::to_string(&event) {
        Ok(line) => {
            match tokio::time::timeout(std::time::Duration::from_secs(2), tx.sender.send(line))
                .await
            {
                Ok(Ok(())) => {}
                Ok(Err(_)) | Err(_) => tx.stalled.store(true, Ordering::Release),
            }
        }
        // Serialisation cannot fail for these types, but a silent drop here
        // would look exactly like a hung daemon from Vim's side.
        Err(error) => eprintln!("simplemarkdown-daemon: could not encode an event: {error}"),
    }
}

// ─────────────────────────── CLI helpers ───────────────────────────

/// The page `:SimpleMarkdownExternal` serves, on stdout.
///
/// The browser preview is the one part of this daemon whose output nobody can
/// read in a terminal, which makes it the one part worth being able to pipe
/// into a file and open — or into a headless browser and screenshot, which is
/// how the stylesheet gets reviewed.
fn html_page(args: &[String]) -> Result<(), String> {
    let path = args.first().ok_or("--html needs a file")?;
    let theme = args.get(1).map_or("auto", String::as_str);
    if !matches!(theme, "auto" | "light" | "dark") {
        return Err(format!("theme is auto, light or dark, not {theme}"));
    }
    let source = std::fs::read_to_string(path).map_err(|error| format!("{path}: {error}"))?;
    let (_, name) = document_root(path);
    let page = html::render(&source, &html::Options::default());
    let mut opts = html::PageOptions {
        name,
        theme: theme.to_string(),
        ..html::PageOptions::default()
    };
    // Nothing is listening: a page written to a file must not spend its life
    // reconnecting to an SSE endpoint that was never there.
    opts.live = false;
    print!("{}", html::document(&page, &opts, 0));
    Ok(())
}

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

/// Time what the plugin actually does: a first render of a document, the
/// steady-state renders that follow it — the gap between the two is the
/// highlight cache — and the patch a one-word edit produces.
///
/// The CHANGELOG publishes figures for all three.  Without a way to take them
/// in the tree they are folklore the moment anything changes, and `bench` sat
/// in the Makefile's .PHONY list for a while with no rule behind it, which is
/// the same problem wearing a hat.
fn bench(args: &[String]) -> Result<(), String> {
    let path = args.first().ok_or("--bench needs a file")?;
    let number = |index: usize, fallback: usize| -> Result<usize, String> {
        match args.get(index) {
            None => Ok(fallback),
            Some(text) => text
                .parse::<usize>()
                .map_err(|_| format!("not a number: {text}")),
        }
    };
    let width = number(1, 80)?.max(8);
    let runs = number(2, 20)?.max(1);

    let source = std::fs::read_to_string(path).map_err(|error| format!("{path}: {error}"))?;
    let opts = protocol::Options::default();

    let mut times: Vec<f64> = Vec::with_capacity(runs);
    let mut rows = 0usize;
    for _ in 0..runs {
        let started = Instant::now();
        let output = render::render(&source, width, &opts);
        times.push(started.elapsed().as_secs_f64() * 1000.0);
        // Read something out of the result so the render cannot be optimised
        // away, and so a rendering that collapses to nothing is visible.
        rows = output.lines.len();
    }

    let first = times[0];
    let mut rest: Vec<f64> = times[1.min(times.len() - 1)..].to_vec();
    rest.sort_by(|a, b| a.partial_cmp(b).expect("no NaN"));
    let median = rest[rest.len() / 2];

    let before = render::render(&source, width, &opts);
    let edited = source.replacen("the", "THE", 1);
    let after = render::render(&edited, width, &opts);
    let patch = diff(&before.lines, &after.lines);
    let patch_bytes = serde_json::to_string(&patch).map_or(0, |text| text.len());
    let full_bytes = serde_json::to_string(&after.lines).map_or(0, |text| text.len());

    println!("{path}: {rows} rows at width {width}, {runs} runs");
    println!("  first render     {first:8.2} ms");
    println!("  steady state     {median:8.2} ms  (median of the rest)");
    println!(
        "  one-word edit    {:8} bytes as a patch of {} rows, against {full_bytes} for the document",
        patch_bytes,
        patch.lines.len()
    );
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

    #[tokio::test]
    async fn bounded_request_reader_recovers_at_the_next_record() {
        let input = b"0123456789\n{\"type\":\"ping\",\"id\":7}\r\n";
        let mut reader = BufReader::new(&input[..]);

        let oversized = read_request_line(&mut reader, 8)
            .await
            .unwrap()
            .unwrap()
            .unwrap_err();
        assert_eq!(oversized, "request line exceeds 8 bytes");

        let next = read_request_line(&mut reader, 64)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(next, r#"{"type":"ping","id":7}"#);
        assert!(read_request_line(&mut reader, 64).await.unwrap().is_none());

        let mut exact_crlf = BufReader::new(&b"12345678\r\n"[..]);
        assert_eq!(
            read_request_line(&mut exact_crlf, 8)
                .await
                .unwrap()
                .unwrap()
                .unwrap(),
            "12345678"
        );
    }

    /// Every length modulo three, against the alphabet and the padding rules —
    /// this is written out here rather than depended on, so it is held here too.
    #[test]
    fn base64_matches_the_alphabet_and_the_padding() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foob"), "Zm9vYg==");
        assert_eq!(base64(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
        // Every byte value, so the last two alphabet entries are covered.
        let all: Vec<u8> = (0u8..=255).collect();
        let encoded = base64(&all);
        assert!(encoded.contains('+') && encoded.contains('/'), "{encoded}");
        assert_eq!(encoded.len(), 344);
    }

    /// The one-shot page carries its pictures or they are broken: a relative
    /// `src` in a file written to a temporary directory points at nothing.
    #[test]
    fn the_one_shot_page_carries_the_pictures_beside_the_document() {
        let root =
            std::env::temp_dir().join(format!("simplemarkdown-inline-{}", std::process::id()));
        std::fs::create_dir_all(&root).expect("a directory");
        std::fs::write(root.join("pic.png"), b"\x89PNG\r\n\x1a\n").expect("a picture");

        let body = concat!(
            "<img src=\"./pic.png\" alt=\"a\">",
            "<img src=\"../secret.png\" alt=\"b\">",
            "<img src=\"https://example.com/x.png\" alt=\"c\">",
            "<img src=\"missing.png\" alt=\"d\">",
        );
        let out = inline_images(&root, body.to_string());
        assert!(
            out.contains("src=\"data:image/png;base64,iVBORw0KGgo"),
            "{out}"
        );
        // Out of the document's directory, off the machine, or not there: all
        // three are left exactly as the document wrote them.
        assert!(out.contains("src=\"../secret.png\""), "{out}");
        assert!(out.contains("src=\"https://example.com/x.png\""), "{out}");
        assert!(out.contains("src=\"missing.png\""), "{out}");

        std::fs::remove_dir_all(&root).ok();
    }

    /// The editor's name for the document wins over the one the path implies,
    /// and an editor that sends none leaves the path's name alone.  This is the
    /// whole of what makes a remote document's tab say which host it is on:
    /// its path is a copy in a staging directory called `main.md`.
    #[test]
    fn the_editors_name_for_the_document_wins() {
        let (_, from_path) = document_root("/tmp/simplemarkdown-remote-7/main.md");
        assert_eq!(from_path, "main.md");

        let unnamed = PageOptions::default();
        assert_eq!(page_options(from_path.clone(), &unnamed).name, "main.md");

        let named = PageOptions {
            name: String::from("main.md @ssh:box:docs@9ms"),
            ..PageOptions::default()
        };
        assert_eq!(
            page_options(from_path, &named).name,
            "main.md @ssh:box:docs@9ms"
        );
    }

    /// And it reaches that far through the wire, from a request written by an
    /// editor that predates the field as well as one that does not.
    #[test]
    fn a_page_name_is_optional_on_the_wire() {
        let old = r#"{"type":"html","id":1,"path":"a.md","lines":[],"page":{"theme":"dark"}}"#;
        match serde_json::from_str::<Request>(old).expect("parses") {
            Request::Html(request) => {
                assert_eq!(request.page.theme, "dark");
                assert_eq!(request.page.name, "");
            }
            other => panic!("wrong variant: {other:?}"),
        }
        let new =
            r#"{"type":"html","id":1,"path":"a.md","lines":[],"page":{"name":"a.md @ssh:box"}}"#;
        match serde_json::from_str::<Request>(new).expect("parses") {
            Request::Html(request) => assert_eq!(request.page.name, "a.md @ssh:box"),
            other => panic!("wrong variant: {other:?}"),
        }
    }

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
        let src_sum = output.lines.iter().map(|line| u64::from(line.src)).sum();
        let event = Event::RenderResult(Box::new(RenderResult {
            id: 1,
            width: 20,
            total,
            src_sum,
            lines: Some(output.lines),
            patch: None,
            toc: Some(output.toc),
            links: Some(output.links),
            blocks: Some(output.blocks),
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

    /// The client's side of a patch, in the same two steps Vim takes: splice
    /// the rows, then repair the source map below the splice.  Nothing else in
    /// the daemon can prove those two agree, because `Line`'s equality no
    /// longer looks at `src`.
    fn apply(prev: &[Line], patch: &Patch) -> Vec<Line> {
        let mut rows = prev.to_vec();
        rows.splice(
            patch.from - 1..patch.from - 1 + patch.del,
            patch.lines.iter().cloned(),
        );
        match &patch.src {
            None => {}
            Some(SrcPatch {
                from,
                tail: Some(entries),
                ..
            }) => {
                assert_eq!(from - 1 + entries.len(), rows.len(), "the tail must fit");
                for (row, src) in rows[from - 1..].iter_mut().zip(entries) {
                    row.src = *src;
                }
            }
            Some(SrcPatch { from, delta, .. }) => {
                for row in &mut rows[from - 1..] {
                    if row.src != 0 {
                        row.src = (i64::from(row.src) + delta) as u32;
                    }
                }
            }
        }
        rows
    }

    fn srcs(lines: &[Line]) -> Vec<u32> {
        lines.iter().map(|line| line.src).collect()
    }

    #[test]
    fn an_insertion_at_the_top_is_still_a_small_patch() {
        // The regression this whole protocol version exists for: `src` used to
        // be part of a row's identity, so inserting one line above made every
        // row below compare unequal, the common suffix vanished, and a single
        // keystroke shipped the entire document.
        let body: String = (0..200).map(|n| format!("paragraph {n}\n\n")).collect();
        let before = render::render(&body, 60, &protocol::Options::default());
        let after = render::render(
            &format!("a new opening line\n\n{body}"),
            60,
            &protocol::Options::default(),
        );

        let patch = diff(&before.lines, &after.lines);
        assert!(
            patch.lines.len() <= 4,
            "{} rows for a one-line insertion",
            patch.lines.len()
        );
        assert!(
            patch_size(&patch) * 2 <= wire_size(&after.lines),
            "the patch must survive the filter that chooses patch over document"
        );
        // Two source lines were added, so every row below moves by two — one
        // integer for a document of any length.
        match &patch.src {
            Some(SrcPatch {
                delta: 2,
                tail: None,
                ..
            }) => {}
            other => panic!("expected a shift of 2, got {other:?}"),
        }
        let applied = apply(&before.lines, &patch);
        assert_eq!(applied, after.lines, "the rows");
        assert_eq!(srcs(&applied), srcs(&after.lines), "the source map");
    }

    #[test]
    fn a_deletion_that_changes_no_row_still_moves_the_source_map() {
        // Deleting one of two consecutive blank lines renders identically and
        // shifts every row below it, which is exactly the case a diff over
        // appearance alone cannot see.
        let before = render::render("a\n\n\nb\n", 40, &protocol::Options::default());
        let after = render::render("a\n\nb\n", 40, &protocol::Options::default());
        assert_eq!(before.lines, after.lines, "no row changed");
        assert_ne!(srcs(&before.lines), srcs(&after.lines), "but the map did");

        let patch = diff(&before.lines, &after.lines);
        assert!(patch.lines.is_empty() && patch.del == 0);
        let applied = apply(&before.lines, &patch);
        assert_eq!(srcs(&applied), srcs(&after.lines));
    }

    #[test]
    fn withdrawn_render_ids_do_not_accumulate() {
        // A cancel that loses the race against its own reply is never removed
        // by the render it names, and a typing session issues one per keystroke
        // burst: unbounded, this is a leak for the life of the daemon.
        let mut cancelled = CancelledRequests::default();
        for id in 1..=10_000u64 {
            note_cancelled(&mut cancelled, id);
        }
        assert!(
            cancelled.len() <= MAX_CANCELLED,
            "{} ids remembered",
            cancelled.len()
        );
        // What is remembered has to be the recent end of the range: those are
        // the renders that might still be queued.
        assert!(cancelled.contains(&10_000));
        assert!(cancelled.contains(&9_999));
        assert!(!cancelled.contains(&1));

        // The bound must describe insertion count, not numeric ordering. An
        // out-of-order protocol peer used to make `id - MAX_CANCELLED` point
        // backwards and retain the whole table forever.
        let mut descending = CancelledRequests::default();
        for id in (1..=10_000u64).rev() {
            note_cancelled(&mut descending, id);
        }
        assert_eq!(descending.len(), MAX_CANCELLED);
        assert!(descending.contains(&1));
        assert!(descending.contains(&2));
        assert!(!descending.contains(&10_000));
    }

    // The two checks in `walk_outline` are not the same check twice.  The
    // Makefile asserts the first one, by sending the cancel before the outline
    // it names — the out-of-order case the client really does produce.  This is
    // the other one, and the one an ordinary supersede produces: the withdrawal
    // arrives while the parse is running, which nothing observable from a pipe
    // can be timed against.
    #[tokio::test]
    async fn an_outline_withdrawn_while_it_parses_is_never_answered() {
        let cancelled: Cancelled = Arc::new(Mutex::new(CancelledRequests::default()));
        let (tx, mut rx) = mpsc::channel::<String>(8);
        // Big enough that the parse is still running when the cancel lands: a
        // document this size takes hundreds of milliseconds to walk, against
        // the 50ms below, and the margin only grows on a slower machine.
        let lines: Vec<String> = (0..500_000).map(|n| format!("# heading {n}")).collect();
        let walking = tokio::spawn(walk_outline(7, lines, cancelled.clone(), EventTx::new(tx)));

        // By now the first check has certainly run — it is a lock acquired
        // microseconds after the spawn — so this is the second one or nothing.
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        note_cancelled(&mut *cancelled.lock().await, 7);

        walking.await.expect("the outline task does not panic");
        assert!(
            rx.try_recv().is_err(),
            "a withdrawn outline was answered anyway"
        );
        assert!(
            !cancelled.lock().await.contains(&7),
            "and the id it named is spent rather than remembered for ever"
        );
    }

    #[test]
    fn the_stalest_session_is_the_one_evicted() {
        let mut sessions = HashMap::new();
        for (key, id) in [("busy", 90u64), ("closed-hours-ago", 3), ("idle", 40)] {
            sessions.insert(
                key.to_string(),
                Session {
                    id,
                    rows: Vec::new(),
                    indexes: Indexes::default(),
                },
            );
        }
        assert_eq!(
            stalest_session(&sessions).as_deref(),
            Some("closed-hours-ago")
        );
    }

    #[test]
    fn random_edit_scripts_round_trip_through_a_patch() {
        // The four hand-written cases below each prove one shape.  This proves
        // the property they are examples of — apply(prev, diff(prev, next)) is
        // next, in appearance *and* in source map — over a few hundred edits
        // made at random offsets in a document of mixed block types.  The
        // generator is a fixed-seed xorshift so a failure is reproducible.
        let mut state = 0x2545_f491_4f6c_dd1du64;
        let mut next_rand = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        let palette = [
            "# a heading",
            "## another heading",
            "",
            "some prose that is long enough to wrap at forty columns or so",
            "- a list item",
            "  - a nested item",
            "> quoted",
            "```rust",
            "fn main() {}",
            "```",
            "| a | b |",
            "|---|---|",
            "| 1 | 2 |",
        ];

        let mut source: Vec<String> = (0..40)
            .map(|n| palette[n % palette.len()].to_string())
            .collect();
        let opts = protocol::Options::default();
        let mut prev = render::render(&source.join("\n"), 40, &opts);

        for _ in 0..200 {
            let roll = next_rand();
            let at = (roll >> 8) as usize % (source.len() + 1);
            match roll % 3 {
                0 => source.insert(
                    at,
                    palette[(roll >> 32) as usize % palette.len()].to_string(),
                ),
                1 if !source.is_empty() => {
                    source.remove(at.min(source.len() - 1));
                }
                _ if !source.is_empty() => {
                    let index = at.min(source.len() - 1);
                    source[index] = palette[(roll >> 32) as usize % palette.len()].to_string();
                }
                _ => {}
            }

            let next = render::render(&source.join("\n"), 40, &opts);
            let patch = diff(&prev.lines, &next.lines);
            let applied = apply(&prev.lines, &patch);
            assert_eq!(applied, next.lines, "rows after {patch:?}");
            assert_eq!(
                srcs(&applied),
                srcs(&next.lines),
                "source map after {patch:?}"
            );
            prev = next;
        }
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
