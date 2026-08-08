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
///
/// v3 took the source line out of a row's identity and patches the row →
/// source map separately ([`SrcPatch`]), which is what made the incremental
/// reply apply to insertions and deletions rather than only to edits in place.
pub const PROTOCOL_VERSION: u32 = 3;

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
    /// Realign the GFM table containing source line `line`.  Answered with the
    /// replacement for the table's own lines and nothing else, so the client
    /// edits a range it can undo rather than rewriting the buffer.
    ///
    /// Deliberately not a `render` option: this hands text back to be written
    /// into the document, and confusing "what the document says" with "what the
    /// preview shows" is how a preview plugin corrupts a file.
    #[serde(rename = "format_table")]
    FormatTable {
        id: u64,
        #[serde(default)]
        lines: Vec<String>,
        /// 1-based source line the cursor is on.
        #[serde(default)]
        line: usize,
    },
    /// A structural edit to the source: `promote`/`demote` shift heading levels,
    /// `renumber` renumbers the ordered lists the range touches.  Answered with
    /// the replacements to make and nothing else, for the same reason
    /// `format_table` is: the daemon never touches a file.
    ///
    /// `from`..=`to` is the range the command was given.  When they are equal —
    /// a bare `:SimpleMarkdownDemote`, i.e. the cursor's line — the ops that act
    /// on headings take the whole section, which is what keeps the tree saying
    /// what it said.
    #[serde(rename = "edit")]
    Edit {
        id: u64,
        /// `promote`, `demote` or `renumber`.  A closed set: an op the daemon
        /// does not know is refused rather than guessed at.
        #[serde(default)]
        op: String,
        #[serde(default)]
        lines: Vec<String>,
        #[serde(default)]
        from: usize,
        #[serde(default)]
        to: usize,
    },
    /// The heading tree, answered with `outline_result`.  Cheaper than a
    /// render by everything a render does: no width, no wrapping, no syntect —
    /// which is what lets folding, asked about once per line per redraw, be
    /// driven by the parser instead of by a pattern over `^#`.
    #[serde(rename = "outline")]
    Outline {
        id: u64,
        #[serde(default)]
        lines: Vec<String>,
    },
    /// Diagnostics for the document, answered with `lint_result`.  Carries no
    /// width and no options: nothing here depends on how the document would be
    /// laid out.
    #[serde(rename = "lint")]
    Lint {
        id: u64,
        #[serde(default)]
        lines: Vec<String>,
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
    /// The answer to `format_table`: replace source lines `from`..=`to` with
    /// `lines`.  `from` is 0 when the cursor was not in a table, which is a
    /// perfectly ordinary thing for a user to ask and not an error.
    #[serde(rename = "format_result")]
    FormatResult {
        id: u64,
        from: usize,
        to: usize,
        lines: Vec<String>,
    },
    /// The answer to `edit`: the replacements to make, in source order.  The
    /// client applies them from the bottom up so one that changes the document's
    /// height cannot invalidate the ranges above it.  An empty list means there
    /// was nothing to do — no heading under the cursor, a list already numbered
    /// — which is an answer, not an error.
    #[serde(rename = "edit_result")]
    EditResult {
        id: u64,
        edits: Vec<crate::format::Replacement>,
    },
    #[serde(rename = "outline_result")]
    OutlineResult { id: u64, toc: Vec<OutlineEntry> },
    #[serde(rename = "lint_result")]
    LintResult { id: u64, items: Vec<LintItem> },
    #[serde(rename = "error")]
    Error { id: u64, message: String },
}

/// One heading, and the section it opens.
///
/// Not [`TocEntry`]: that one carries the rendered row a heading landed on,
/// which only exists once something has been laid out for a window of some
/// width.  This one carries where the heading's section *ends* in the source,
/// which is what a fold range and a section motion are made of.
#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct OutlineEntry {
    pub level: u8,
    pub text: String,
    pub anchor: String,
    /// 1-based source line of the heading.
    pub src: usize,
    /// 1-based source line the section ends on: the line before the next
    /// heading of the same level or shallower, or the last line of the
    /// document.
    pub end_src: usize,
}

/// One diagnostic.  The field names are Vim's own quickfix keys, and
/// `severity` carries a quickfix `type` letter, so the Vim side hands the list
/// to `setloclist()` with the text prefixed and nothing else translated.
#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct LintItem {
    /// 1-based source line.
    pub line: usize,
    /// 1-based byte column, which is what quickfix wants.
    pub col: usize,
    /// `W` for something a reader will notice, `I` for advice.
    pub severity: &'static str,
    /// One of `lint::codes::ALL`, and documented in the help.
    pub code: &'static str,
    pub text: String,
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
    /// Sum of every row's source line.  A second checksum beside `total`,
    /// because the rows and the source map are now spliced independently and a
    /// map that has drifted while the text has not would otherwise be invisible
    /// until it moved the cursor — or an `x` — to the wrong line.
    pub src_sum: u64,
    /// The outline, the link spans and the top-level block index.  Each is
    /// absent when it is byte-for-byte what this session was last sent, which on
    /// a small patch is the difference between a reply of a hundred bytes and
    /// one of thirty thousand: they describe the whole document however little
    /// of it moved, and Vim parses the JSON on the main thread.  Absent means
    /// "keep what you have", exactly as an absent `lines` already means "the
    /// patch is the whole answer".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub toc: Option<Vec<TocEntry>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub links: Option<Vec<LinkRef>>,
    /// Top-level blocks, for painting the one the source cursor is in.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blocks: Option<Vec<BlockSpan>>,
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
    /// What the rows *below* the splice need doing to their source lines.
    /// Absent when they need nothing, which is every edit that neither adds nor
    /// removes a source line.
    #[serde(rename = "s", skip_serializing_if = "Option::is_none")]
    pub src: Option<SrcPatch>,
}

/// The correction the client's row → source map needs below a [`Patch`].
///
/// Inserting one line in the source moves every row below it in the map while
/// changing nothing about how those rows look.  That is why [`Line`] compares
/// only its appearance — including `src` made the common suffix vanish, and
/// with it the whole point of patching — and it is why the map is repaired
/// here, as a second and much cheaper splice.
///
/// It is computed against exactly what the client holds once it has spliced
/// the rows in, so the usual case — everything from some row on moved by the
/// same amount — is one integer for a document of any size.
#[derive(Debug, Serialize)]
pub struct SrcPatch {
    /// 1-based row of the first entry that needs correcting.  Not necessarily
    /// below the row splice: a row whose appearance did not change is kept by
    /// the diff, and its source line may still have moved.
    #[serde(rename = "f")]
    pub from: usize,
    /// Add this to every non-zero entry from `from` to the end.  Rows that came
    /// from no particular source line stay at 0.
    #[serde(rename = "d", skip_serializing_if = "is_zero_i64")]
    pub delta: i64,
    /// Those entries in full instead, for the rare tail that a single delta
    /// cannot describe — a reflow that moved rows between blocks, say.
    #[serde(rename = "s", skip_serializing_if = "Option::is_none")]
    pub tail: Option<Vec<u32>>,
}

fn is_zero_i64(value: &i64) -> bool {
    *value == 0
}

/// `[row, rows, src_first, src_last]` — a top-level block's rendered extent
/// and the source lines it came from.  Serialises as an array for the same
/// reason [`Prop`] does.
#[derive(Debug, Serialize, PartialEq, Eq, Hash)]
pub struct BlockSpan(pub u32, pub u32, pub u32, pub u32);

/// One rendered row.
#[derive(Debug, Serialize, Default, Clone)]
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

/// Two rows are the same row when they *look* the same.
///
/// `src` is deliberately not part of this.  It is bookkeeping about where a row
/// came from, not about the row, and it shifts on every row below an inserted
/// line while nothing on screen moves at all.  Comparing it made the diff's
/// common suffix vanish for `Enter`, `dd`, `o` and every paste — half of all
/// editing — so the incremental reply, the feature this daemon was built
/// around, silently degraded to a full document for exactly those edits.  The
/// map is patched separately; see [`SrcPatch`].
impl PartialEq for Line {
    fn eq(&self, other: &Self) -> bool {
        self.text == other.text && self.props == other.props
    }
}

impl Eq for Line {}

/// Serialises as a three-element array; see the module comment.
#[derive(Debug, Serialize, PartialEq, Eq, Clone)]
pub struct Prop(pub usize, pub usize, pub &'static str);

#[derive(Debug, Serialize, Hash)]
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

#[derive(Debug, Serialize, Hash)]
pub struct LinkRef {
    /// 1-based rendered row.
    pub row: u32,
    /// 1-based byte column of the link text.
    pub col: usize,
    pub len: usize,
    pub href: String,
}
