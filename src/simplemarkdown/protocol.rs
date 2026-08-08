//! Wire types for the simplemarkdown daemon.
//!
//! The transport is JSON lines in both directions, matching the rest of the
//! simple* suite: one request object per line on stdin, one event object per
//! line on stdout.  Field names in the hot path (rendered lines and their text
//! properties) are deliberately one character long — a 3000-line document
//! carries tens of thousands of property spans, and `{"col":..,"len":..}` on
//! each of them triples the bytes Vim has to parse on the main thread.

use serde::{Deserialize, Serialize};

/// Bumped whenever the wire format changes in a way the Vim side must know
/// about.  The plugin refuses to talk to a daemon it does not understand
/// rather than silently mis-rendering.
///
/// v2 added the incremental reply: a render that only changed a paragraph
/// answers with the rows that moved rather than the whole document.
pub const PROTOCOL_VERSION: u32 = 2;

// ─────────────────────────── requests ───────────────────────────

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
pub enum Request {
    /// Capability handshake, sent once per daemon start by simplecore.
    #[serde(rename = "ping")]
    Ping {
        #[serde(default)]
        id: u64,
    },
    #[serde(rename = "render")]
    Render(Box<RenderRequest>),
    /// Drop a queued render whose answer nobody is waiting for any more.
    #[serde(rename = "cancel")]
    Cancel { id: u64 },
    /// Release the rows kept for a preview window that has gone away.  Not
    /// required for correctness — a stale entry only costs memory, and the
    /// next render for a reused key resynchronises — but a long editing
    /// session opens and closes a lot of previews.
    #[serde(rename = "forget")]
    Forget {
        #[serde(default)]
        session: String,
    },
}

#[derive(Debug, Deserialize)]
pub struct RenderRequest {
    pub id: u64,
    /// The buffer contents, one entry per line, without line terminators.
    #[serde(default)]
    pub lines: Vec<String>,
    /// Total columns available in the preview window.
    #[serde(default = "default_width")]
    pub width: usize,
    #[serde(default)]
    pub opts: Options,
    /// Which preview window this render is for.  The daemon keeps the last
    /// rows it sent under this key so the next render can be answered as a
    /// patch; an empty key opts out and always gets the whole document.
    #[serde(default)]
    pub session: String,
    /// True when the client's copy of the previous render is intact and a
    /// patch against it can be applied.  False after anything that resets the
    /// preview buffer — a placeholder, an error, a fresh window — and the
    /// daemon then answers in full and starts the session over.
    #[serde(default)]
    pub incremental: bool,
}

fn default_width() -> usize {
    80
}

#[derive(Debug, Deserialize, Clone)]
pub struct Options {
    /// Draw boxes and bars with box-drawing characters.  When false every
    /// decoration falls back to ASCII, for terminals or fonts that render the
    /// Unicode ones at the wrong width.
    #[serde(default = "yes")]
    pub unicode: bool,
    /// Syntax-highlight fenced code blocks with syntect.
    #[serde(default = "yes")]
    pub syntax: bool,
    /// Reflow prose to the window width.  With this off each paragraph becomes
    /// one long line and the window scrolls horizontally.
    #[serde(default = "yes")]
    pub wrap: bool,
    /// Wrap over-long code lines onto a continuation row instead of clipping
    /// them at the box edge.
    #[serde(default = "yes")]
    pub code_wrap: bool,
    /// Append the target after a link's text, e.g. `docs (./x.md)`.
    #[serde(default)]
    pub show_urls: bool,
    /// Hard cap on the text column, independent of the window width, so prose
    /// stays readable in a very wide window.  0 disables the cap.
    #[serde(default)]
    pub max_width: usize,
    /// Columns a tab expands to inside code blocks.
    #[serde(default = "four")]
    pub tab_width: usize,
    /// Render a YAML front-matter block instead of hiding it.
    #[serde(default = "yes")]
    pub frontmatter: bool,
    /// Number the lines inside fenced code blocks.  Off by default: it costs
    /// columns, and in a preview beside the source the numbers are usually
    /// already on screen.
    #[serde(default)]
    pub code_numbers: bool,
    /// Tint every other table body row, which is what makes a wide table
    /// scannable across.
    #[serde(default)]
    pub table_zebra: bool,
    /// Close a task list with a `2/5 done` line.
    #[serde(default = "yes")]
    pub task_progress: bool,
}

fn yes() -> bool {
    true
}

fn four() -> usize {
    4
}

impl Default for Options {
    fn default() -> Self {
        Self {
            unicode: true,
            syntax: true,
            wrap: true,
            code_wrap: true,
            show_urls: false,
            max_width: 0,
            tab_width: 4,
            frontmatter: true,
            code_numbers: false,
            table_zebra: false,
            task_progress: true,
        }
    }
}

// ─────────────────────────── events ───────────────────────────

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
pub enum Event {
    #[serde(rename = "pong")]
    Pong {
        id: u64,
        protocol_version: u32,
        version: &'static str,
        capabilities: std::collections::BTreeMap<&'static str, bool>,
    },
    #[serde(rename = "render_result")]
    RenderResult(Box<RenderResult>),
    #[serde(rename = "error")]
    Error { id: u64, message: String },
}

#[derive(Debug, Serialize)]
pub struct RenderResult {
    pub id: u64,
    /// Echoed back so a late reply for a stale window size can be discarded.
    pub width: usize,
    /// Rows the document has after this render.  The client checks its buffer
    /// against it after applying a patch: a mismatch means the two copies have
    /// drifted, and the honest recovery is a full render, not a redraw of
    /// whatever is there.
    pub total: usize,
    /// The whole document.  Present unless `patch` is.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lines: Option<Vec<Line>>,
    /// The rows that moved since the last render for this session.  Present
    /// instead of `lines` when that is the smaller answer.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub patch: Option<Patch>,
    pub toc: Vec<TocEntry>,
    pub links: Vec<LinkRef>,
    /// Top-level blocks, for painting the one the source cursor is in.
    pub blocks: Vec<BlockSpan>,
    pub elapsed_ms: u128,
}

/// A splice: replace `del` rows starting at `from` with `lines`.
///
/// One hunk, not a list of them, because it is computed by trimming the common
/// prefix and suffix — which is exactly the shape of an edit.  A keystroke
/// reflows one paragraph; the rows above and below it are untouched, and the
/// wrong answer here is not an incorrect one but a large one.
#[derive(Debug, Serialize)]
pub struct Patch {
    /// 1-based row where the replacement starts.
    pub from: usize,
    /// How many existing rows it replaces.  0 is a pure insertion.
    pub del: usize,
    #[serde(rename = "l")]
    pub lines: Vec<Line>,
}

/// `[row, rows, src_first, src_last]` — a top-level block's rendered extent
/// and the source lines it came from.  Serialises as an array for the same
/// reason [`Prop`] does.
#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct BlockSpan(pub u32, pub u32, pub u32, pub u32);

/// One rendered row.
#[derive(Debug, Serialize, Default, Clone, PartialEq, Eq)]
pub struct Line {
    /// Display text.  Never contains a newline or a tab.
    #[serde(rename = "t")]
    pub text: String,
    /// Text properties, as `[byte_col, byte_len, class]` with a 1-based column,
    /// which is exactly what `prop_add()` wants.
    #[serde(rename = "p", skip_serializing_if = "Vec::is_empty")]
    pub props: Vec<Prop>,
    /// 1-based source line this row came from, or 0 when it corresponds to no
    /// particular one (a box border, a blank spacer).  Drives scroll sync.
    #[serde(rename = "s", skip_serializing_if = "is_zero")]
    pub src: u32,
}

fn is_zero(value: &u32) -> bool {
    *value == 0
}

/// Serialises as a three-element array; see the module comment.
#[derive(Debug, Serialize, PartialEq, Eq, Clone)]
pub struct Prop(pub usize, pub usize, pub &'static str);

#[derive(Debug, Serialize)]
pub struct TocEntry {
    pub level: u8,
    pub text: String,
    /// GitHub's anchor for this heading, so `[x](#some-heading)` can be
    /// resolved by comparing slugs instead of guessing at the prose.  Computed
    /// here rather than in Vim because only the renderer knows the plain text
    /// of a heading that contains inline markup, and only it sees the whole
    /// document, which is what the `-1`/`-2` de-duplication needs.
    pub anchor: String,
    /// 1-based source line of the heading.
    pub src: u32,
    /// 1-based rendered row of the heading.
    pub row: u32,
}

#[derive(Debug, Serialize)]
pub struct LinkRef {
    /// 1-based rendered row.
    pub row: u32,
    /// 1-based byte column of the link text.
    pub col: usize,
    pub len: usize,
    pub href: String,
}
