//! The browser preview's HTTP server: one per previewed document.
//!
//! Hand-rolled HTTP/1.1 on a [`tokio::net::TcpListener`], because pulling a web
//! framework into a process whose job is laying out rows of text was exactly
//! the trade this plugin made when it shelled out to `omd`, and exactly the
//! trade it is undoing.  What a preview needs is four routes — the page, an
//! event stream, a scroll report and the images sitting next to the document —
//! and that is one file, not a dependency tree with its own release schedule.
//!
//! What it deliberately is not: there is no keep-alive (every answer closes,
//! because a preview is one page load plus one stream that never ends), no
//! HTTP/2, no compression, no range requests, no conditional requests, no
//! directory listing and no authentication.  Nothing here is a general-purpose
//! server and nothing here should grow into one.
//!
//! It may nonetheless be bound to `0.0.0.0` — that is a documented setting, for
//! reading the preview on a phone — so every request is treated as hostile:
//! the head is capped and timed out, the body is capped, a static path is
//! resolved lexically *and* canonicalised against the document's directory, and
//! `POST /cursor` is a 404 rather than a no-op when the user has turned
//! sync-back off, so the page cannot make the editor jump on a setting the user
//! has already said no to.

use crate::html::{Page, PageOptions, TocItem, document};
use serde::{Deserialize, Serialize};
use std::io;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc, watch};

/// A request head larger than this is not a browser asking for a preview, and
/// reading it to the end is how a single connection eats the daemon's memory.
const MAX_HEAD: usize = 8 * 1024;

/// The only body this server reads is `{"line":N}`.  The cap is generous
/// because being wrong about it costs a bug report and being generous costs
/// 64 KiB.
const MAX_BODY: usize = 64 * 1024;

/// Assets are read whole into memory, which is the right shape for the images
/// and fonts a document links to and the wrong shape for the film someone has
/// left in the same directory.  Above this the answer is a refusal rather than
/// a copy of the file in the editor's address space.
const MAX_FILE: u64 = 64 * 1024 * 1024;

/// How long a connection may take to say what it wants — the head, and the
/// short body that may follow it.  Without this a peer that opens a socket and
/// then falls silent pins a task until the daemon exits, and opening sockets is
/// free.
const HEAD_TIMEOUT: Duration = Duration::from_secs(10);

/// Idle keep-alive on the event stream.  Some proxies and some browsers drop a
/// stream that says nothing for long enough, and a preview that has silently
/// stopped updating is worse than one that never worked: the user believes what
/// they are looking at.
const KEEPALIVE: Duration = Duration::from_secs(15);

/// How long a write may make no progress before the peer is dropped.
const WRITE_STALL: Duration = Duration::from_secs(30);

/// How far a browser may fall behind before it is resynchronised.  A lagged
/// receiver is resent the whole current document, so the queue only has to
/// cover an ordinary typing burst rather than a session.
const EVENT_QUEUE: usize = 64;

/// Scroll positions waiting for the editor.  Deeper than this and the editor is
/// far enough behind that the positions are no longer where the reader is
/// looking.
const CURSOR_QUEUE: usize = 16;

const OK: &str = "200 OK";
const NO_CONTENT: &str = "204 No Content";
const BAD_REQUEST: &str = "400 Bad Request";
const NOT_FOUND: &str = "404 Not Found";
const NOT_ALLOWED: &str = "405 Method Not Allowed";
const BODY_TOO_LARGE: &str = "413 Content Too Large";
const HEAD_TOO_LARGE: &str = "431 Request Header Fields Too Large";

const SSE_HEAD: &str = "HTTP/1.1 200 OK\r\n\
                        Content-Type: text/event-stream\r\n\
                        Cache-Control: no-cache\r\n\
                        Connection: close\r\n\
                        \r\n";

/// The last thing a browser is told.  A constant rather than a serialisation:
/// it is written on the way out, where there is nothing useful to do about a
/// failure, and it is short enough to read against the protocol document.
const BYE: &str = "data: {\"k\":\"bye\"}\n\n";

/// An SSE comment, which is the protocol's own way of saying nothing.
const PING: &str = ":\n\n";

// ─────────────────────────── configuration ───────────────────────────

pub struct Config {
    /// Bind address: `127.0.0.1` normally, `0.0.0.0` when the user wants to
    /// read the preview from another machine.
    pub host: String,
    /// The first port to try.
    pub port: u16,
    /// How far above `port` to look before giving up.
    pub attempts: u16,
    /// The document's directory: the only place an asset may come from.
    pub root: PathBuf,
    pub page: Page,
    pub page_opts: PageOptions,
}

// ─────────────────────────── shared state ───────────────────────────

/// The document every browser is currently being shown, and the event that
/// says so.  The frame is built once per update rather than once per
/// connection, and it is also what a browser gets on connect and what a browser
/// that has fallen behind gets instead of a gap.
struct Snapshot {
    page: Page,
    doc: Arc<str>,
    /// Which document this is.  A patch names the sequence it applies to, so a
    /// browser that has missed a frame — or connected between one being built
    /// and being sent — can tell, and wait for the next whole document instead
    /// of splicing into one it does not have.
    seq: u64,
}

struct State {
    /// Canonicalised, because a static path is only safe if the prefix it is
    /// compared against is real too.
    root: PathBuf,
    opts: PageOptions,
    snapshot: Mutex<Arc<Snapshot>>,
    events: broadcast::Sender<Arc<str>>,
    /// `None` when the user has turned sync-back off, which is what makes
    /// `POST /cursor` a 404 rather than a lie.
    cursor: Option<mpsc::Sender<usize>>,
    /// Flipped once, by [`Server::stop`].  Every connection and the accept loop
    /// wait on it; the sender lives here rather than in [`Server`] so that
    /// dropping the handle cannot be mistaken for a shutdown.
    shutdown: watch::Sender<bool>,
}

/// A running preview.  Dropping it does not stop the server; [`Server::stop`]
/// does, because the daemon keeps these in a table keyed by preview session and
/// a drop during a table rebuild would take a live preview down with it.
pub struct Server {
    state: Arc<State>,
    port: u16,
    url: String,
    cursor_rx: Option<mpsc::Receiver<usize>>,
}

impl Server {
    /// Binds the first free port at or above `config.port`, spawns the accept
    /// loop, and answers with the address the *browser* should be sent to — a
    /// wildcard bind is reachable on loopback, and that is where the browser
    /// has to go.
    pub async fn start(config: Config) -> io::Result<Self> {
        let Config {
            host,
            port,
            attempts,
            root,
            page,
            page_opts,
        } = config;

        let listener = bind(&host, port, attempts).await?;
        // The bound port, not the requested one: the search may have moved.
        let port = listener.local_addr()?.port();

        let (cursor_tx, cursor_rx) = match page_opts.sync_back {
            true => {
                let (tx, rx) = mpsc::channel(CURSOR_QUEUE);
                (Some(tx), Some(rx))
            }
            false => (None, None),
        };
        let (events, _) = broadcast::channel(EVENT_QUEUE);
        let (shutdown, _) = watch::channel(false);

        let state = Arc::new(State {
            // One stat, once, on a path the editor has just written a file
            // next to.  A directory that cannot be canonicalised — a buffer
            // whose directory has been deleted underneath it — still serves
            // the page; only its assets are lost, and they were lost anyway.
            root: root.canonicalize().unwrap_or(root),
            opts: page_opts,
            snapshot: Mutex::new(Arc::new(Snapshot {
                doc: Arc::from(doc_frame(&page, 0)),
                page,
                seq: 0,
            })),
            events,
            cursor: cursor_tx,
            shutdown,
        });

        tokio::spawn(accept(listener, state.clone()));

        Ok(Self {
            state,
            port,
            url: format!("http://{}:{port}/", browser_host(&host)),
            cursor_rx,
        })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn url(&self) -> &str {
        &self.url
    }

    /// Replace the document and push it to every connected browser — as the
    /// blocks that moved where that is smaller, and as the whole thing where it
    /// is not.
    ///
    /// The snapshot is replaced and the frame sent under one lock, and a
    /// browser subscribes under the same one: otherwise a tab opened between
    /// the two would be handed the new document *and* the patch that produced
    /// it, and would splice an edit into a document that already had it.
    pub fn update(&self, page: Page) {
        let mut held = lock(&self.state.snapshot);
        let previous = held.clone();
        let seq = previous.seq + 1;

        // No periodic whole document to fall back on: the page checks both
        // that a patch names the sequence it is holding and that the splice
        // left it with the number of children the daemon says it should have,
        // and reloads itself when either fails.  Sending the document
        // occasionally *just in case* would cost a quarter of a megabyte every
        // few keystrokes on a long one, to repair a state that is detected.
        let payload = match block_patch(&previous.page, &page) {
            Some(splice) => {
                let frame = frame(&PatchEvent {
                    k: "patch",
                    seq,
                    base: previous.seq,
                    from: splice.from,
                    del: splice.del,
                    html: splice.html,
                    shift: splice.shift,
                    blocks: page.blocks.len(),
                    // The rail and the tab are rebuilt from these, and on a
                    // keystroke inside a paragraph neither has moved.
                    title: (page.title != previous.page.title).then_some(page.title.as_str()),
                    toc: (page.toc != previous.page.toc).then_some(page.toc.as_slice()),
                });
                Arc::from(frame)
            }
            None => Arc::from(doc_frame(&page, seq)),
        };

        *held = Arc::new(Snapshot {
            doc: Arc::from(doc_frame(&page, seq)),
            page,
            seq,
        });
        // A send with nobody listening is the ordinary case — the user has not
        // opened the tab yet — and the browser that arrives next is handed the
        // snapshot on connect.
        let _ = self.state.events.send(payload);
    }

    /// Push a scroll position.
    pub fn cursor(&self, line: usize) {
        let _ = self
            .state
            .events
            .send(Arc::from(frame(&LineEvent { k: "line", line })));
    }

    /// Take the channel the browser's own scrolling arrives on.  `None` after
    /// the first call: there is one receiver and the daemon owns it.
    pub fn sync_back(&mut self) -> Option<mpsc::Receiver<usize>> {
        self.cursor_rx.take()
    }

    /// Say goodbye to every browser, then stop accepting.
    ///
    /// The goodbye is written by each stream rather than broadcast, so that it
    /// cannot lose the race against the shutdown it announces.  Breaking the
    /// accept loop drops the listener, which is what actually frees the port —
    /// the next `:SimpleMarkdownExternal` on this buffer asks for it back.
    ///
    /// `send_replace` rather than `send`: `send` refuses, and leaves the value
    /// alone, when nothing has subscribed yet — and the accept loop subscribes
    /// when the runtime first polls it, which is after `start()` has returned.
    /// A `stop()` landing in that window would silently do nothing and hold the
    /// port for the life of the daemon.
    pub fn stop(&self) {
        self.state.shutdown.send_replace(true);
    }
}

/// The snapshot lock, held over a pointer clone and nothing else.  A poisoned
/// mutex would mean a task panicked mid-swap; refusing to serve the preview
/// over it would turn a stray panic into a dead preview, and what is behind the
/// lock is a whole document either way.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Separate functions so that no `MutexGuard` is ever alive across an `await`.
fn current(state: &State) -> Arc<Snapshot> {
    lock(&state.snapshot).clone()
}

fn current_doc(state: &State) -> Arc<str> {
    lock(&state.snapshot).doc.clone()
}

// ─────────────────────────── events ───────────────────────────

#[derive(Serialize)]
struct DocEvent<'a> {
    k: &'static str,
    seq: u64,
    title: &'a str,
    html: &'a str,
    toc: &'a [TocItem],
    /// How many children `#sm-doc` must have once this is in place.  The page
    /// splices by child index, so a count it disagrees with is the one thing
    /// it cannot detect on its own — and it stops splicing until the next
    /// whole document rather than editing the wrong paragraph.
    blocks: usize,
}

/// The blocks that moved: replace `del` of the page's children, starting at
/// `from`, with the elements `html` parses to.
#[derive(Serialize)]
struct PatchEvent<'a> {
    k: &'static str,
    seq: u64,
    base: u64,
    from: usize,
    del: usize,
    html: &'a str,
    blocks: usize,
    /// Add `delta` to the `data-line` of every child from `from` on.  Absent
    /// when the edit neither added nor removed a source line.
    #[serde(skip_serializing_if = "Option::is_none")]
    shift: Option<Shift>,
    /// Only when they changed.  The contents rail is rebuilt from scratch when
    /// it arrives, and on a keystroke inside a paragraph it has not moved.
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    toc: Option<&'a [TocItem]>,
}

#[derive(Serialize)]
struct LineEvent {
    k: &'static str,
    line: usize,
}

#[derive(Deserialize)]
struct CursorReport {
    line: usize,
}

fn doc_frame(page: &Page, seq: u64) -> String {
    frame(&DocEvent {
        k: "doc",
        seq,
        title: &page.title,
        html: &page.body,
        toc: &page.toc,
        blocks: page.blocks.len(),
    })
}

/// The splice that turns `before` into `after`, or `None` when there is not one
/// worth sending.
///
/// The shape is the row patch's, for the same reason and with the same trade:
/// trimming the common prefix and then the common suffix finds exactly the run
/// an edit touched, and cannot describe two edits in different places as two
/// hunks — it spans them.  That is the right answer for a preview driven one
/// keystroke at a time.
struct BlockPatch<'a> {
    from: usize,
    del: usize,
    html: &'a str,
    /// What the blocks *below* the splice need doing to their `data-line`.
    /// `None` when they need nothing, which is every edit that neither adds nor
    /// removes a source line.
    shift: Option<Shift>,
}

#[derive(Serialize, Clone, Copy)]
struct Shift {
    from: usize,
    delta: i64,
}

/// Two blocks are the same block when they differ only in which source line
/// they came from.
///
/// Pressing Enter at the top of a document moves every `data-line` below it and
/// changes nothing else about any of them; comparing the markup as it stands
/// would report the whole document as changed and send it.  This is the same
/// trap [`crate::protocol::Line`] avoids by not comparing its own `src`, and
/// the correction is carried the same way: separately, as one integer.
fn same_but_for_lines(a: &str, b: &str) -> bool {
    const ATTR: &str = " data-line=\"";
    let (mut a, mut b) = (a, b);
    loop {
        let (at_a, at_b) = (a.find(ATTR), b.find(ATTR));
        let (Some(at_a), Some(at_b)) = (at_a, at_b) else {
            // Neither has another one, or only one does: what is left has to
            // match exactly either way.
            return at_a.is_none() && at_b.is_none() && a == b;
        };
        if a[..at_a] != b[..at_b] {
            return false;
        }
        let (Some(end_a), Some(end_b)) = (
            a[at_a + ATTR.len()..].find('"'),
            b[at_b + ATTR.len()..].find('"'),
        ) else {
            return false;
        };
        a = &a[at_a + ATTR.len() + end_a + 1..];
        b = &b[at_b + ATTR.len() + end_b + 1..];
    }
}

fn block_patch<'a>(before: &Page, after: &'a Page) -> Option<BlockPatch<'a>> {
    if !before.splittable || !after.splittable {
        return None;
    }
    let old = &before.blocks;
    let new = &after.blocks;
    let same = |a: &crate::html::Block, b: &crate::html::Block| {
        same_but_for_lines(&before.body[a.at.clone()], &after.body[b.at.clone()])
    };

    let mut head = 0;
    while head < old.len() && head < new.len() && same(&old[head], &new[head]) {
        head += 1;
    }
    let mut tail = 0;
    while tail < old.len() - head
        && tail < new.len() - head
        && same(&old[old.len() - 1 - tail], &new[new.len() - 1 - tail])
    {
        tail += 1;
    }

    let del = old.len() - head - tail;
    let kept = &new[head..new.len() - tail];
    let html = match (kept.first(), kept.last()) {
        (Some(first), Some(last)) => &after.body[first.at.start..last.at.end],
        // A pure deletion: nothing replaces the blocks that went.
        _ => "",
    };

    // What the blocks that survive the splice need doing to their `data-line`.
    //
    // Indexed against the document the page is *holding*, and applied before
    // the splice, because the blocks the splice inserts already carry the right
    // lines and shifting them again would move them twice.  The prefix is
    // walked as well as the tail: `same_but_for_lines` is what let the prefix
    // swallow every block below an inserted line in the first place, so the
    // blocks needing correction are frequently the ones it matched.
    //
    // Almost always one integer — `n` lines inserted anywhere above moves
    // everything below by `n` — and where it is not, the honest answer is the
    // whole document.
    let mut shift: Option<Shift> = None;
    let mut note = |from: usize, was: usize, now: usize| -> bool {
        if was == now {
            return true;
        }
        // A block that came from no source line at all — the footnote section —
        // is 0 on both sides and would look like an enormous shift.
        if was == 0 || now == 0 {
            return false;
        }
        let delta = now as i64 - was as i64;
        match shift {
            None => {
                shift = Some(Shift { from, delta });
                true
            }
            Some(seen) => seen.delta == delta,
        }
    };
    for index in 0..head {
        if !note(index, old[index].line, new[index].line) {
            return None;
        }
    }
    for offset in 0..tail {
        let index = old.len() - tail + offset;
        if !note(index, old[index].line, new[new.len() - tail + offset].line) {
            return None;
        }
    }

    if del == 0 && html.is_empty() && shift.is_none() {
        // Nothing moved at all.
        return Some(BlockPatch {
            from: head,
            del: 0,
            html: "",
            shift: None,
        });
    }
    // Not worth the splice unless it is substantially smaller, exactly as the
    // row patch decides: a rewrite of most of the document is cheaper for the
    // page to take as one replacement than as a splice of nearly everything.
    if html.len() * 2 > after.body.len() {
        return None;
    }
    Some(BlockPatch {
        from: head,
        del,
        html,
        shift,
    })
}

/// One SSE event.  The JSON must be a single line and `serde_json` guarantees
/// that much — a newline inside the rendered HTML comes back as `\n` — so the
/// framing is the two trailing newlines and nothing else.
///
/// Serialisation cannot fail for these types, but a stream that goes quiet is
/// the one failure mode this module is most anxious about, so the impossible
/// case sends a comment: the browser stays connected and the next edit repairs
/// what it is showing.
fn frame<T: Serialize>(event: &T) -> String {
    match serde_json::to_string(event) {
        Ok(json) => format!("data: {json}\n\n"),
        Err(error) => {
            eprintln!("simplemarkdown-daemon: could not encode a preview event: {error}");
            PING.to_string()
        }
    }
}

// ─────────────────────────── binding ───────────────────────────

async fn bind(host: &str, port: u16, attempts: u16) -> io::Result<TcpListener> {
    let tries = attempts.max(1);
    let mut last = io::Error::new(io::ErrorKind::AddrInUse, "no port was tried");
    for offset in 0..tries {
        let Some(candidate) = port.checked_add(offset) else {
            break;
        };
        match TcpListener::bind((host, candidate)).await {
            Ok(listener) => return Ok(listener),
            // Only a taken port moves the search up.  A host that does not
            // resolve, or a privileged port, fails identically two dozen times
            // and the user is owed that error rather than a report about a
            // range of ports that were never the problem.
            Err(error) if error.kind() == io::ErrorKind::AddrInUse => last = error,
            Err(error) => return Err(error),
        }
    }
    let highest = port.saturating_add(tries - 1);
    Err(io::Error::new(
        last.kind(),
        format!("no free port in {port}..={highest} on {host}: {last}"),
    ))
}

/// Whether a request's `Host` may be answered.
///
/// Rebinding an address the browser already holds requires a *name*: the
/// attacker's page is served from `evil.example`, the record then flips to
/// this server's address, and every fetch the page makes is same-origin as
/// far as the browser is concerned.  An address literal cannot be rebound, so
/// the rule is a literal, or `localhost` — which covers both deployments this
/// server documents, `http://127.0.0.1:3030/` and, under the wildcard bind,
/// the machine's own address typed into a phone.  A `Host` this server does
/// not answer to is not a request it should have received.
fn host_allowed(host: &str) -> bool {
    let host = host.trim();
    // No `Host` at all is a hand-written client (`nc`, HTTP/1.0); a browser
    // always sends one, so nothing that needs rebinding gets in this way.
    if host.is_empty() {
        return true;
    }
    let name = match host.strip_prefix('[') {
        // `[::1]:3030` — the brackets are what make the port unambiguous.
        Some(rest) => match rest.split_once(']') {
            Some((inside, _)) => inside,
            None => return false,
        },
        None => match host.rsplit_once(':') {
            Some((name, port)) if !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()) => {
                name
            }
            _ => host,
        },
    };
    name.eq_ignore_ascii_case("localhost") || name.parse::<std::net::IpAddr>().is_ok()
}

/// Where the *browser* has to be sent.  A wildcard bind is reachable on the
/// loopback address and on nothing else that can be named without knowing the
/// machine's routing, which is the same rule the Vim side applies before it
/// probes a port.
fn browser_host(host: &str) -> String {
    match host.trim() {
        "" | "0.0.0.0" => "127.0.0.1".to_string(),
        "::" | "[::]" => "[::1]".to_string(),
        // A bare IPv6 literal has to be bracketed before it can carry a port.
        other if other.contains(':') && !other.starts_with('[') => format!("[{other}]"),
        other => other.to_string(),
    }
}

/// Resolves once [`Server::stop`] has been called.
///
/// A function rather than the expression written straight into `select!`:
/// `wait_for` resolves to a *guard* over the watched value, and a guard sitting
/// in a `select!` arm's output is enough to make the whole connection future
/// non-`Send`, which `tokio::spawn` then refuses.
async fn stopped(shutdown: &mut watch::Receiver<bool>) {
    let _ = shutdown.wait_for(|stopped| *stopped).await;
}

// ─────────────────────────── the accept loop ───────────────────────────

async fn accept(listener: TcpListener, state: Arc<State>) {
    let mut shutdown = state.shutdown.subscribe();
    loop {
        tokio::select! {
            _ = stopped(&mut shutdown) => break,
            accepted = listener.accept() => match accepted {
                Ok((stream, _)) => {
                    tokio::spawn(connection(stream, state.clone()));
                }
                // A failed accept is about one connection — a peer that
                // vanished, a file-descriptor limit — and tearing the server
                // down over it would take the user's preview with it.  The
                // pause is for the EMFILE case, where retrying immediately is
                // a busy loop.
                Err(_) => tokio::time::sleep(Duration::from_millis(50)).await,
            },
        }
    }
    // Returning here drops the listener, which is the point: `stop()` has to
    // give the port back.
}

async fn connection(mut stream: TcpStream, state: Arc<State>) {
    // An event is a few dozen bytes and its whole value is arriving before the
    // next keystroke; Nagle would hold it back waiting for company.
    let _ = stream.set_nodelay(true);
    // A connection that errors is a browser that closed a tab.  There is
    // nobody to tell.
    let _ = handle(&mut stream, &state).await;
}

async fn handle(stream: &mut TcpStream, state: &State) -> io::Result<()> {
    let (head, rest) = match read_head(stream).await? {
        Incoming::Head(head, rest) => (head, rest),
        Incoming::TooLarge => return respond_text(stream, HEAD_TOO_LARGE, "head too large").await,
        Incoming::Gone => return Ok(()),
    };
    let Some(request) = parse_head(&head) else {
        return respond_text(stream, BAD_REQUEST, "bad request").await;
    };
    if !host_allowed(&request.host) {
        return respond_text(stream, BAD_REQUEST, "bad host").await;
    }

    match (request.method.as_str(), request.path.as_str()) {
        ("GET", "/") => {
            let snapshot = current(state);
            let page = document(&snapshot.page, &state.opts, snapshot.seq);
            respond(stream, OK, "text/html; charset=utf-8", page.as_bytes()).await
        }
        ("GET", "/events") => events(stream, state, already_has(&request.query)).await,
        ("POST", "/cursor") => cursor(stream, state, &request, rest).await,
        ("GET", path) => asset(stream, state, path).await,
        _ => respond_text(stream, NOT_ALLOWED, "method not allowed").await,
    }
}

// ─────────────────────────── the event stream ───────────────────────────

/// The document the browser says it already has, from `?have=N`.
///
/// The page it was served carries the whole body, and the stream would
/// otherwise open by sending it again — a quarter of a megabyte on a long
/// document, for a browser that is looking at it already.
fn already_has(query: &str) -> Option<u64> {
    query
        .split('&')
        .find_map(|pair| pair.strip_prefix("have="))
        .and_then(|value| value.parse().ok())
}

async fn events(stream: &mut TcpStream, state: &State, have: Option<u64>) -> io::Result<()> {
    // Subscribed while holding the snapshot, so that the document this
    // connection is handed and the frames it will receive cannot straddle an
    // update: either it takes the lock first and gets the old document plus the
    // patch that moves it on, or `update` takes it first and this gets the new
    // document and misses the patch entirely.  Both are right; the interleaving
    // this excludes is the one where it gets both.
    let (mut events, opening) = {
        let held = lock(&state.snapshot);
        let opening = (have != Some(held.seq)).then(|| held.doc.clone());
        (state.events.subscribe(), opening)
    };
    let mut shutdown = state.shutdown.subscribe();

    write_bounded(stream, SSE_HEAD.as_bytes()).await?;
    // The current document goes out before anything else: a browser that
    // connects between two edits — a reload, a second tab — would otherwise sit
    // blank until the user next typed something.  Unless it has just been
    // handed that very document in the page it is running from, which is the
    // ordinary case and the expensive one.
    if let Some(opening) = opening {
        write_bounded(stream, opening.as_bytes()).await?;
    }
    stream.flush().await?;

    let start = tokio::time::Instant::now() + KEEPALIVE;
    let mut keepalive = tokio::time::interval_at(start, KEEPALIVE);
    loop {
        let payload: Arc<str> = tokio::select! {
            _ = stopped(&mut shutdown) => {
                write_bounded(stream, BYE.as_bytes()).await?;
                return stream.flush().await;
            }
            event = events.recv() => match event {
                Ok(frame) => frame,
                // Lagged means this browser is slower than the typist.  The
                // events it missed described documents that no longer exist, so
                // the honest repair is the one that is current.
                Err(broadcast::error::RecvError::Lagged(_)) => current_doc(state),
                Err(broadcast::error::RecvError::Closed) => return Ok(()),
            },
            _ = keepalive.tick() => Arc::from(PING),
        };
        // Bounded, and this is the write that matters most: an event stream is
        // the one response here that stays open for hours, so it is the one a
        // browser can stop draining — a suspended laptop, a tab a phone froze —
        // and `write_all` on a socket whose peer has stopped reading parks
        // until the peer comes back.  That connection would hold its task and
        // its share of this server past `stop()`.
        write_bounded(stream, payload.as_bytes()).await?;
        stream.flush().await?;
    }
}

// ─────────────────────────── scroll reports ───────────────────────────

async fn cursor(
    stream: &mut TcpStream,
    state: &State,
    request: &RequestHead,
    prefix: Vec<u8>,
) -> io::Result<()> {
    // Refused at the route rather than accepted and dropped: with sync-back off
    // the page must not be able to move the editor at all, and a 404 says so to
    // the script as plainly as to whoever reads the log.
    let Some(sender) = &state.cursor else {
        return respond_text(stream, NOT_FOUND, "not found").await;
    };
    if request.content_length > MAX_BODY {
        return respond_text(stream, BODY_TOO_LARGE, "body too large").await;
    }
    let Some(body) = read_body(stream, prefix, request.content_length).await? else {
        return Ok(());
    };
    let Ok(report) = serde_json::from_slice::<CursorReport>(&body) else {
        return respond_text(stream, BAD_REQUEST, "expected {\"line\":N}").await;
    };
    // `try_send`, because a full queue means the editor is not keeping up, and
    // a scroll position applied late moves the cursor to where the reader was
    // looking a second ago.  Dropping it is the kinder failure.
    let _ = sender.try_send(report.line);
    respond_empty(stream, NO_CONTENT).await
}

// ─────────────────────────── assets ───────────────────────────

async fn asset(stream: &mut TcpStream, state: &State, path: &str) -> io::Result<()> {
    let Some(candidate) = safe_join(&state.root, path) else {
        return respond_text(stream, NOT_FOUND, "not found").await;
    };
    let root = state.root.clone();
    // On the blocking pool for the same reason a render is: this thread is also
    // driving the event streams of every other browser looking at the document.
    let read = tokio::task::spawn_blocking(move || -> io::Result<(PathBuf, Vec<u8>)> {
        let real = candidate.canonicalize()?;
        // The lexical check in `safe_join` cannot see a symlink: `logo.png`
        // next to the document may point at `~/.ssh/id_rsa`, and this server
        // may be bound to an address the rest of the office can reach.
        if !real.starts_with(root.as_path()) {
            return Err(io::Error::other("outside the document's directory"));
        }
        if real.metadata()?.len() > MAX_FILE {
            return Err(io::Error::other("too large to serve"));
        }
        let bytes = std::fs::read(&real)?;
        Ok((real, bytes))
    })
    .await;

    match read {
        Ok(Ok((real, bytes))) => respond(stream, OK, content_type(&real), &bytes).await,
        // A file that is missing, a directory, one that is too big and one that
        // is outside the root all answer the same 404.  This port may be
        // reachable from the network, and a preview server has no business
        // reporting what does and does not exist on the disk behind it.
        _ => respond_text(stream, NOT_FOUND, "not found").await,
    }
}

/// The path a URL is allowed to name under `root`, decided lexically.
///
/// Exactly one leading slash is the URL's own root and is removed; what is left
/// is percent-decoded first, so that `%2e%2e%2f` is judged as the `../` it is,
/// and then every component of it has to be an ordinary name.  Anything still
/// absolute after that (`//etc/passwd`, `/%2Fetc%2Fpasswd`), any `..`, any
/// Windows drive prefix and anything that does not decode to UTF-8 is refused
/// outright rather than normalised into something plausible.
fn safe_join(root: &Path, target: &str) -> Option<PathBuf> {
    let decoded = percent_decode(target.strip_prefix('/')?)?;
    if decoded.is_empty() || decoded.contains('\0') {
        return None;
    }
    let relative = Path::new(&decoded);
    if relative
        .components()
        .any(|part| !matches!(part, Component::Normal(_)))
    {
        return None;
    }
    Some(root.join(relative))
}

/// Percent-decoding, which is a dozen lines and no crate.
///
/// `+` is left alone: it means a space in a query string and nothing at all in
/// a path, and `a+b.png` is a file people really do have.
fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'%' => {
                let hex = text.get(index + 1..index + 3)?;
                if !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                    // `from_str_radix` would happily read `%+1` as 1.
                    return None;
                }
                out.push(u8::from_str_radix(hex, 16).ok()?);
                index += 3;
            }
            byte => {
                out.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

/// Enough of a MIME table for what a Markdown document links to.  Everything
/// else is `application/octet-stream`, which browsers download rather than
/// guess at — the right answer for a file this server does not understand.
fn content_type(path: &Path) -> &'static str {
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    match extension.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "avif" => "image/avif",
        "svg" => "image/svg+xml",
        "ico" => "image/x-icon",
        "css" => "text/css; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "json" => "application/json",
        "txt" => "text/plain; charset=utf-8",
        "md" => "text/markdown; charset=utf-8",
        "pdf" => "application/pdf",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        _ => "application/octet-stream",
    }
}

// ─────────────────────────── reading a request ───────────────────────────

/// What arrived on a connection before it was worth parsing.
enum Incoming {
    /// The head, and whatever of the body shared its packets.
    Head(String, Vec<u8>),
    TooLarge,
    /// Nothing usable: end of stream, a timeout, or bytes that are not text.
    Gone,
}

struct RequestHead {
    method: String,
    path: String,
    query: String,
    host: String,
    content_length: usize,
}

async fn read_head(stream: &mut TcpStream) -> io::Result<Incoming> {
    let mut buffer: Vec<u8> = Vec::with_capacity(1024);
    let deadline = tokio::time::Instant::now() + HEAD_TIMEOUT;
    loop {
        if let Some(end) = head_end(&buffer) {
            let (head, rest) = buffer.split_at(end);
            return Ok(match std::str::from_utf8(head) {
                Ok(text) => Incoming::Head(text.to_string(), rest.to_vec()),
                Err(_) => Incoming::Gone,
            });
        }
        if buffer.len() > MAX_HEAD {
            return Ok(Incoming::TooLarge);
        }
        let mut chunk = [0u8; 1024];
        let read = match tokio::time::timeout_at(deadline, stream.read(&mut chunk)).await {
            Ok(result) => result?,
            Err(_) => return Ok(Incoming::Gone),
        };
        if read == 0 {
            return Ok(Incoming::Gone);
        }
        buffer.extend_from_slice(&chunk[..read]);
    }
}

/// Where the head stops, counting the blank line.  A bare `\n\n` is accepted
/// alongside `\r\n\r\n` because hand-written clients — including this module's
/// own tests, and anyone poking at the port with `nc` — send it.
fn head_end(buffer: &[u8]) -> Option<usize> {
    let crlf = buffer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|at| at + 4);
    let lf = buffer
        .windows(2)
        .position(|window| window == b"\n\n")
        .map(|at| at + 2);
    crlf.into_iter().chain(lf).min()
}

/// The request line and the one header this server cares about.
///
/// The HTTP version is read and ignored: everything here answers 1.1 and closes,
/// which a 1.0 client understands perfectly well.  The query and fragment are
/// cut off the target because no route takes a parameter.
fn parse_head(text: &str) -> Option<RequestHead> {
    let mut lines = text.lines();
    let mut request_line = lines.next()?.split_whitespace();
    let method = request_line.next()?.to_string();
    let target = request_line.next()?;
    let path = target.split(['?', '#']).next()?.to_string();
    let query = target.split_once('?').map_or(String::new(), |(_, rest)| {
        rest.split('#').next().unwrap_or("").to_string()
    });

    let mut content_length = 0;
    let mut host = String::new();
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        if name.trim().eq_ignore_ascii_case("host") {
            host = value.trim().to_string();
        }
        if name.trim().eq_ignore_ascii_case("content-length") {
            // A length that is not a number reads no body, the JSON parse then
            // fails, and the client is told so — which beats guessing.
            content_length = value.trim().parse().unwrap_or(0);
        }
    }

    Some(RequestHead {
        method,
        path,
        query,
        host,
        content_length,
    })
}

async fn read_body(
    stream: &mut TcpStream,
    prefix: Vec<u8>,
    length: usize,
) -> io::Result<Option<Vec<u8>>> {
    let mut body = prefix;
    // Anything past the declared length is a pipelined second request, and this
    // server closes after one answer, so it is not ours to read.
    body.truncate(length);
    let deadline = tokio::time::Instant::now() + HEAD_TIMEOUT;
    while body.len() < length {
        let mut chunk = [0u8; 4096];
        let read = match tokio::time::timeout_at(deadline, stream.read(&mut chunk)).await {
            Ok(result) => result?,
            Err(_) => return Ok(None),
        };
        if read == 0 {
            return Ok(None);
        }
        let wanted = read.min(length - body.len());
        body.extend_from_slice(&chunk[..wanted]);
    }
    Ok(Some(body))
}

// ─────────────────────────── writing a response ───────────────────────────

/// Everything is `no-store`, assets included.  The document being previewed is
/// the one the user is editing this second, and so is the diagram beside it; a
/// cached copy of either is a bug report about a preview that "does not update".
async fn respond(
    stream: &mut TcpStream,
    status: &str,
    content_type: &str,
    body: &[u8],
) -> io::Result<()> {
    let head = format!(
        "HTTP/1.1 {status}\r\n\
         Content-Type: {content_type}\r\n\
         Content-Length: {length}\r\n\
         Cache-Control: no-store\r\n\
         Connection: close\r\n\
         \r\n",
        length = body.len()
    );
    write_bounded(stream, head.as_bytes()).await?;
    write_bounded(stream, body).await?;
    stream.flush().await
}

/// `write_all` parks for ever once the peer stops reading; the deadline is
/// reset whenever bytes actually move, so a slow phone is fine and a socket
/// that has gone quiet is not.
async fn write_bounded(stream: &mut TcpStream, mut body: &[u8]) -> io::Result<()> {
    while !body.is_empty() {
        let wrote = tokio::time::timeout(WRITE_STALL, stream.write(body))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "peer stopped reading"))??;
        if wrote == 0 {
            return Err(io::Error::from(io::ErrorKind::WriteZero));
        }
        body = &body[wrote..];
    }
    Ok(())
}

async fn respond_text(stream: &mut TcpStream, status: &str, message: &str) -> io::Result<()> {
    respond(
        stream,
        status,
        "text/plain; charset=utf-8",
        message.as_bytes(),
    )
    .await
}

async fn respond_empty(stream: &mut TcpStream, status: &str) -> io::Result<()> {
    let head = format!("HTTP/1.1 {status}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
    write_bounded(stream, head.as_bytes()).await?;
    stream.flush().await
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Rendered rather than hand-built, so that the block index every patch is
    /// computed from is the one the emitter really produces.
    fn rendered(markdown: &str) -> Page {
        crate::html::render(markdown, &crate::html::Options::default())
    }

    fn page() -> Page {
        rendered("## A heading\n\nhello from the preview\n")
    }

    fn options(sync_back: bool) -> PageOptions {
        PageOptions {
            name: "notes.md".to_string(),
            theme: "auto".to_string(),
            math: "off".to_string(),
            math_url: String::new(),
            max_width: 880,
            live: true,
            follow: true,
            sync_back,
        }
    }

    fn config(sync_back: bool) -> Config {
        Config {
            host: "127.0.0.1".to_string(),
            // Port 0 is the kernel's own free-port search; the test only cares
            // that `port()` reports what was actually bound.
            port: 0,
            attempts: 4,
            root: std::env::temp_dir(),
            page: page(),
            page_opts: options(sync_back),
        }
    }

    #[test]
    fn a_request_line_yields_the_method_and_the_bare_path() {
        let head = "GET /images/a%20b.png?v=2 HTTP/1.1\r\nHost: localhost\r\n\r\n";
        let parsed = parse_head(head).expect("parses");
        assert_eq!(parsed.method, "GET");
        assert_eq!(parsed.path, "/images/a%20b.png");
        assert_eq!(parsed.content_length, 0);

        let post = "POST /cursor HTTP/1.1\r\ncontent-length: 11\r\n\r\n";
        let parsed = parse_head(post).expect("parses");
        assert_eq!(parsed.method, "POST");
        assert_eq!(
            parsed.content_length, 11,
            "the header name is case-insensitive"
        );

        assert!(parse_head("").is_none());
        assert!(
            parse_head("GET\r\n\r\n").is_none(),
            "no target is not a request"
        );
    }

    #[test]
    fn a_head_ends_at_the_blank_line_in_either_dialect() {
        assert_eq!(head_end(b"GET / HTTP/1.1\r\n\r\nbody"), Some(18));
        assert_eq!(head_end(b"GET / HTTP/1.1\n\nbody"), Some(16));
        assert_eq!(head_end(b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n"), None);
    }

    #[test]
    fn percent_escapes_decode_and_rubbish_is_refused() {
        assert_eq!(percent_decode("a%20b.png").as_deref(), Some("a b.png"));
        assert_eq!(percent_decode("%2Fetc").as_deref(), Some("/etc"));
        assert_eq!(percent_decode("caf%C3%A9.md").as_deref(), Some("café.md"));
        assert_eq!(percent_decode("a+b.png").as_deref(), Some("a+b.png"));
        assert!(percent_decode("%").is_none());
        assert!(percent_decode("%2").is_none());
        assert!(percent_decode("%zz").is_none());
        assert!(percent_decode("%+1").is_none());
        // A byte that is not part of any UTF-8 sequence is not a file name.
        assert!(percent_decode("%ff").is_none());
    }

    #[test]
    fn a_url_cannot_escape_the_document_directory() {
        let root = Path::new("/home/writer/notes");
        assert_eq!(
            safe_join(root, "/images/diagram.png"),
            Some(PathBuf::from("/home/writer/notes/images/diagram.png"))
        );
        assert!(safe_join(root, "/../../etc/passwd").is_none());
        assert!(safe_join(root, "/images/../../../etc/passwd").is_none());
        // The same attack wearing an escape, which is why decoding comes first.
        assert!(safe_join(root, "/%2e%2e/%2e%2e/etc/passwd").is_none());
        // An absolute path: the leading slash is the URL's root, and what is
        // left must still not be one.
        assert!(safe_join(root, "//etc/passwd").is_none());
        assert!(safe_join(root, "/%2Fetc%2Fpasswd").is_none());
        assert!(
            safe_join(root, "/").is_none(),
            "nothing named is not an asset"
        );
    }

    #[test]
    fn content_types_cover_what_a_document_links_to() {
        assert_eq!(content_type(Path::new("a.png")), "image/png");
        assert_eq!(content_type(Path::new("a.JPEG")), "image/jpeg");
        assert_eq!(content_type(Path::new("a.svg")), "image/svg+xml");
        assert_eq!(content_type(Path::new("a.woff2")), "font/woff2");
        assert!(content_type(Path::new("a.css")).starts_with("text/css"));
        assert_eq!(
            content_type(Path::new("a.tar.gz")),
            "application/octet-stream"
        );
        assert_eq!(
            content_type(Path::new("LICENSE")),
            "application/octet-stream"
        );
    }

    #[test]
    fn a_doc_event_is_one_line_of_json_in_an_sse_frame() {
        // A newline in the body is the case that would break the framing if the
        // JSON were assembled by hand.
        let page = rendered("## A heading\n\n```\none\ntwo\n```\n");
        assert!(page.body.contains('\n'), "{}", page.body);
        let framed = doc_frame(&page, 1);

        assert!(framed.starts_with("data: {"), "{framed}");
        assert!(framed.ends_with("\n\n"), "{framed}");
        assert_eq!(
            framed.matches('\n').count(),
            2,
            "the payload has to survive as a single line: {framed}"
        );
        assert!(framed.contains(r#""k":"doc""#), "{framed}");
        assert!(framed.contains(r#""anchor":"a-heading""#), "{framed}");
        assert!(framed.contains(r#"one\ntwo"#), "{framed}");
    }

    /// The property the whole scheme rests on: applying the splice to the
    /// blocks the page is holding yields the blocks the daemon has.  Held over
    /// several shapes of edit, because the one that matters is not the one in
    /// the middle of a paragraph — it is the one that adds or removes a block,
    /// where an off-by-one moves every heading below it.
    #[test]
    fn a_patch_turns_the_old_blocks_into_the_new_ones() {
        let base = "# Title\n\nalpha\n\nbeta\n\n## Two\n\ngamma\n";
        let edits = [
            // in place
            "# Title\n\nalpha!\n\nbeta\n\n## Two\n\ngamma\n",
            // inserted in the middle
            "# Title\n\nalpha\n\nnew\n\nbeta\n\n## Two\n\ngamma\n",
            // removed from the middle
            "# Title\n\nbeta\n\n## Two\n\ngamma\n",
            // appended
            "# Title\n\nalpha\n\nbeta\n\n## Two\n\ngamma\n\ndelta\n",
            // removed from the end
            "# Title\n\nalpha\n\nbeta\n",
            // nothing at all
            "",
        ];

        let before = rendered(base);
        // What the page is holding: the markup of each child, and the source
        // line the sync reads off it.  Both have to come out right.
        let held: Vec<(&str, usize)> = before
            .blocks
            .iter()
            .map(|block| (&before.body[block.at.clone()], block.line))
            .collect();

        for edit in edits {
            let after = rendered(edit);
            let want: Vec<(&str, usize)> = after
                .blocks
                .iter()
                .map(|block| (&after.body[block.at.clone()], block.line))
                .collect();
            let Some(splice) = block_patch(&before, &after) else {
                // Refusing to patch is always allowed — the page then takes the
                // whole document — so it is not a failure, only a missed saving.
                continue;
            };
            let kept = after.blocks.len() - (held.len() - splice.from - splice.del);
            let inserted: Vec<(&str, usize)> = after.blocks[splice.from..kept]
                .iter()
                .map(|block| (&after.body[block.at.clone()], block.line))
                .collect();
            assert_eq!(
                inserted.iter().map(|(html, _)| *html).collect::<String>(),
                splice.html,
                "the html a patch carries is exactly the blocks it inserts, for {edit:?}"
            );

            // In the page's order: the lines of what is already there are
            // corrected first, indexed against the children as they stand, and
            // only then are the blocks spliced in — they arrive with their own
            // lines already right.
            let mut applied = held.clone();
            if let Some(shift) = splice.shift {
                for entry in applied.iter_mut().skip(shift.from) {
                    if entry.1 != 0 {
                        entry.1 = (entry.1 as i64 + shift.delta) as usize;
                    }
                }
            }
            applied.splice(splice.from..splice.from + splice.del, inserted);
            // Compared the way the diff compares: the `data-line` written into
            // the markup of an untouched block is stale until the page applies
            // the shift, and applying it is what the next assertion checks.
            assert_eq!(applied.len(), want.len(), "block count after {edit:?}");
            for (had, wanted) in applied.iter().zip(&want) {
                assert!(
                    same_but_for_lines(had.0, wanted.0),
                    "markup after {edit:?}:\n  {}\n  {}",
                    had.0,
                    wanted.0
                );
            }
            let applied_lines: Vec<usize> = applied.iter().map(|(_, line)| *line).collect();
            let want_lines: Vec<usize> = want.iter().map(|(_, line)| *line).collect();
            assert_eq!(applied_lines, want_lines, "source lines after {edit:?}");
        }
    }

    /// A document the page cannot splice — raw HTML can open a tag it closes
    /// three blocks later, so what the browser builds is not one element per
    /// block and a child index means nothing.
    #[test]
    fn a_document_with_raw_html_is_never_patched() {
        let before = rendered("<div>\n\nalpha\n\n</div>\n");
        let after = rendered("<div>\n\nbeta\n\n</div>\n");
        assert!(!before.splittable, "{:?}", before.blocks);
        assert!(block_patch(&before, &after).is_none());
    }

    #[test]
    fn a_browser_is_not_re_sent_the_document_it_arrived_with() {
        assert_eq!(already_has("have=7"), Some(7));
        assert_eq!(already_has("x=1&have=12&y=2"), Some(12));
        assert_eq!(already_has(""), None);
        assert_eq!(already_has("have=soon"), None);
    }

    #[test]
    fn a_line_event_says_only_where_to_scroll() {
        let framed = frame(&LineEvent {
            k: "line",
            line: 42,
        });
        assert_eq!(framed, "data: {\"k\":\"line\",\"line\":42}\n\n");
    }

    #[test]
    fn a_wildcard_bind_sends_the_browser_to_loopback() {
        assert_eq!(browser_host("0.0.0.0"), "127.0.0.1");
        assert_eq!(browser_host("::"), "[::1]");
        assert_eq!(browser_host("127.0.0.1"), "127.0.0.1");
        assert_eq!(browser_host("::1"), "[::1]");
    }

    /// Everything above this line is testable without a socket, which is most
    /// of what can go wrong.  What follows is the wiring.
    async fn ask(port: u16, request: &str) -> String {
        let mut stream = TcpStream::connect(("127.0.0.1", port))
            .await
            .expect("the server accepts connections");
        stream
            .write_all(request.as_bytes())
            .await
            .expect("the request goes out");
        let mut response = Vec::new();
        stream
            .read_to_end(&mut response)
            .await
            .expect("the server closes when it is done");
        String::from_utf8_lossy(&response).into_owned()
    }

    /// Read until `needle` turns up, and fail the test rather than hang the
    /// suite on a stream that has stopped saying anything.
    async fn expect(stream: &mut TcpStream, seen: &mut String, needle: &str) {
        let mut chunk = [0u8; 4096];
        while !seen.contains(needle) {
            let read = tokio::time::timeout(Duration::from_secs(5), stream.read(&mut chunk))
                .await
                .unwrap_or(Ok(0))
                .unwrap_or(0);
            assert!(read > 0, "the stream ended before {needle:?}: {seen:?}");
            seen.push_str(&String::from_utf8_lossy(&chunk[..read]));
        }
    }

    #[tokio::test]
    async fn a_raw_get_returns_the_rendered_page() {
        let server = Server::start(config(false)).await.expect("binds a port");
        assert!(
            server.port() != 0,
            "the bound port is reported, not the asked-for one"
        );
        assert!(
            server.url().starts_with("http://127.0.0.1:"),
            "{}",
            server.url()
        );

        let response = ask(server.port(), "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n").await;
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");
        assert!(response.contains("text/html"), "{response}");
        assert!(response.contains("hello from the preview"), "{response}");

        // Sync-back is off in this configuration, so the page must not be able
        // to move the editor at all.
        let refused = ask(
            server.port(),
            "POST /cursor HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\n{\"line\":42}",
        )
        .await;
        assert!(refused.starts_with("HTTP/1.1 404"), "{refused}");

        let unsupported = ask(
            server.port(),
            "DELETE / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        )
        .await;
        assert!(unsupported.starts_with("HTTP/1.1 405"), "{unsupported}");

        server.stop();
    }

    #[tokio::test]
    async fn the_browser_can_move_the_editor_when_sync_back_is_on() {
        let mut server = Server::start(config(true)).await.expect("binds a port");
        let mut lines = server.sync_back().expect("the channel exists once");
        assert!(
            server.sync_back().is_none(),
            "there is one receiver and the daemon owns it"
        );

        let accepted = ask(
            server.port(),
            "POST /cursor HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\n{\"line\":42}",
        )
        .await;
        assert!(accepted.starts_with("HTTP/1.1 204"), "{accepted}");
        assert_eq!(lines.recv().await, Some(42));

        let nonsense = ask(
            server.port(),
            "POST /cursor HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nnope",
        )
        .await;
        assert!(nonsense.starts_with("HTTP/1.1 400"), "{nonsense}");

        server.stop();
    }

    /// `stop()` has to give the port back: the next `:SimpleMarkdownExternal`
    /// on the same buffer asks for exactly that port, and a preview that lands
    /// on a different one each time leaves a stale tab open on every restart.
    #[tokio::test]
    async fn stopping_frees_the_port() {
        let server = Server::start(config(false)).await.expect("binds a port");
        let port = server.port();
        server.stop();

        // The accept loop drops the listener the next time it is polled, which
        // is after this task has yielded; rebinding is the only honest way to
        // ask whether it has.
        let mut freed = false;
        for _ in 0..100 {
            tokio::time::sleep(Duration::from_millis(10)).await;
            if TcpListener::bind(("127.0.0.1", port)).await.is_ok() {
                freed = true;
                break;
            }
        }
        assert!(freed, "the port was still held a second after stop()");
    }

    /// The `Host` check, which is the whole of this server's defence against
    /// DNS rebinding: a page on `evil.example` cannot read a preview it can
    /// reach, because the name it must send to reach it is one this server
    /// refuses to answer to.
    #[tokio::test]
    async fn a_request_for_a_name_this_server_does_not_answer_to_is_refused() {
        let server = Server::start(config(false)).await.expect("binds a port");

        for host in [
            "127.0.0.1",
            "127.0.0.1:8080",
            "localhost:3030",
            "[::1]:3030",
        ] {
            let answer = ask(
                server.port(),
                &format!("GET / HTTP/1.1\r\nHost: {host}\r\n\r\n"),
            )
            .await;
            assert!(answer.starts_with("HTTP/1.1 200"), "{host}: {answer}");
        }

        for host in ["evil.example", "evil.example:3030", "preview.local"] {
            let answer = ask(
                server.port(),
                &format!("GET / HTTP/1.1\r\nHost: {host}\r\n\r\n"),
            )
            .await;
            assert!(answer.starts_with("HTTP/1.1 400"), "{host}: {answer}");
        }

        server.stop();
    }

    /// Assets, and the two ways out of the directory they may come from.  The
    /// guard tested above is lexical; this is the half of it only the
    /// filesystem can answer.
    #[tokio::test]
    async fn assets_come_from_the_document_directory_and_nowhere_else() {
        let base =
            std::env::temp_dir().join(format!("simplemarkdown-serve-{}", std::process::id()));
        let root = base.join("notes");
        std::fs::create_dir_all(&root).expect("a directory to serve from");
        std::fs::write(root.join("diagram.png"), b"\x89PNG\r\n\x1a\n").expect("an asset");
        std::fs::write(base.join("secret.txt"), b"not yours").expect("a file outside the root");

        let mut settings = config(false);
        settings.root = root.clone();
        let server = Server::start(settings).await.expect("binds a port");

        let found = ask(
            server.port(),
            "GET /diagram.png HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        )
        .await;
        assert!(found.starts_with("HTTP/1.1 200"), "{found}");
        assert!(found.contains("Content-Type: image/png"), "{found}");

        let climbed = ask(
            server.port(),
            "GET /../secret.txt HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        )
        .await;
        assert!(climbed.starts_with("HTTP/1.1 404"), "{climbed}");

        // A symlink is what a lexical guard cannot see, and the reason the
        // resolved path is canonicalised before it is read.
        #[cfg(unix)]
        {
            let link = root.join("innocent.txt");
            std::os::unix::fs::symlink(base.join("secret.txt"), &link).expect("a symlink");
            let followed = ask(
                server.port(),
                "GET /innocent.txt HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            )
            .await;
            assert!(followed.starts_with("HTTP/1.1 404"), "{followed}");
        }

        server.stop();
        let _ = std::fs::remove_dir_all(&base);
    }

    /// The failure this module is most anxious about is a stream that has gone
    /// quiet without saying so, which makes the whole life of one worth a test:
    /// the document a browser is handed on connect, an update pushed to it, a
    /// scroll position, and the goodbye `stop()` owes it.
    #[tokio::test]
    async fn an_event_stream_opens_with_the_document_and_closes_with_a_goodbye() {
        let server = Server::start(config(false)).await.expect("binds a port");
        let mut stream = TcpStream::connect(("127.0.0.1", server.port()))
            .await
            .expect("the server accepts connections");
        stream
            .write_all(b"GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n")
            .await
            .expect("the request goes out");

        let mut seen = String::new();
        // A browser that connects between two edits is never left blank.
        expect(&mut stream, &mut seen, "hello from the preview").await;
        assert!(seen.contains("text/event-stream"), "{seen}");

        // Only now is this connection certainly subscribed, which is why the
        // update comes after the first frame rather than before it.
        server.update(rendered("## A heading\n\nthe second draft\n"));
        expect(&mut stream, &mut seen, "the second draft").await;

        server.cursor(9);
        expect(&mut stream, &mut seen, r#"{"k":"line","line":9}"#).await;

        server.stop();
        expect(&mut stream, &mut seen, r#"{"k":"bye"}"#).await;
    }
}
