//! Markdown → HTML for the browser preview.
//!
//! The renderer next door lays a document *out*: it is given a window width, it
//! wraps prose, it draws boxes out of box-drawing characters.  This one does
//! none of that, because the browser owns the layout — and in exchange it has
//! to say two things the terminal never has to.  Every block carries the source
//! line it came from, which is what lets the editor and the page follow each
//! other, and every piece carries a class, which is what lets one stylesheet
//! describe the whole document.
//!
//! Three deliberate omissions.
//!
//! *No HTML library.*  `pulldown-cmark` is a `default-features = false`
//! dependency precisely so the daemon does not carry a renderer it never uses,
//! and `pulldown_cmark::html` went with it; the escaping below is this module's
//! own.
//!
//! *No sanitising.*  Escaping and sanitising are not the same job.  A raw HTML
//! block in the source is passed through verbatim, exactly as the terminal
//! renderer shows it verbatim, because the document is the user's own file and
//! a preview that rewrote it would be showing something the file does not say.
//! The one thing that is refused is a `javascript:` link target, which is not a
//! security boundary — the raw HTML beside it could do anything — but is the
//! one place where a plain Markdown link, in a document the user may have
//! merely downloaded, can turn a click into code.
//!
//! *No network.*  [`document`] inlines the stylesheet and the script, so the
//! page is a single response that works on a train and behind a firewall.  The
//! sole exception is the optional maths engine, and the markup is arranged so
//! that a failure to load it leaves the raw `$…$` on the page.

use crate::classes;
use crate::highlight;
use crate::render::slug;
use pulldown_cmark::{
    Alignment, BlockQuoteKind, CodeBlockKind, Event, HeadingLevel, Options as MdOptions, Parser,
    Tag,
};
use serde::Serialize;
use std::borrow::Cow;
use std::collections::HashMap;
use std::fmt::Write as _;
use std::ops::Range;

/// Formatting into a `String` cannot fail, so every write in this module drops
/// its `Result` here rather than at sixty call sites.
macro_rules! push {
    ($out:expr, $($arg:tt)*) => {{
        let _ = write!($out, $($arg)*);
    }};
}

/// One entry of the page's contents list.
#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct TocItem {
    pub level: u8,
    pub text: String,
    pub anchor: String,
}

/// One top-level block: where its HTML sits in [`Page::body`], and the source
/// line it came from.
///
/// The line is carried beside the HTML as well as inside it, because that is
/// what lets an insertion be pushed as a splice.  Every block below an inserted
/// line has a new `data-line` and identical HTML otherwise, so a diff that
/// compared the markup as it stands would find the whole document changed —
/// which is the same trap the row patch fell into, and is why [`crate::protocol::Line`]
/// does not compare its own source line either.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Block {
    pub at: Range<usize>,
    pub line: usize,
}

/// A rendered document, ready to be dropped into the page shell or pushed
/// down the SSE stream.
#[derive(Debug, Serialize)]
pub struct Page {
    pub title: String,
    pub body: String,
    /// Every top-level block, in document order.
    ///
    /// This is what lets an edit be pushed to a browser as the two or three
    /// blocks that moved rather than as the document: on a 1,800-line document
    /// one keystroke was 264 KB of HTML, against 28 bytes for the same edit on
    /// the terminal preview's side of the daemon.  Every entry is one element
    /// once the browser has parsed it, which is the property `splittable`
    /// exists to guarantee — the page splices by child index and has no way to
    /// find out on its own that a block turned into two nodes.
    #[serde(skip)]
    pub blocks: Vec<Block>,
    /// Whether `blocks` may be trusted as one-element-each.  False for a
    /// document containing a raw HTML block or bare inline text at the top
    /// level: the first can open a tag it closes three blocks later, the second
    /// is not an element at all, and either way the page's child index stops
    /// meaning what the daemon thinks it means.  Such a document is pushed
    /// whole, which is what every document did before.
    #[serde(skip)]
    pub splittable: bool,
    pub toc: Vec<TocItem>,
}

/// What the *document* looks like.
#[derive(Debug, Clone)]
pub struct Options {
    pub syntax: bool,
    pub frontmatter: bool,
    pub math: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            syntax: true,
            frontmatter: true,
            math: true,
        }
    }
}

/// What the *page around it* looks like.
///
/// Separate from [`Options`] because a re-render pushes a new [`Page`] down an
/// SSE stream that the shell outlives: everything here was decided once, when
/// the browser was opened, and nothing here may change without a reload.
#[derive(Debug, Clone)]
pub struct PageOptions {
    /// File name, for `<title>` and for the bar.
    pub name: String,
    /// `auto`, `light` or `dark`.
    pub theme: String,
    /// `off`, `katex` or `mathjax`.
    pub math: String,
    /// Where to fetch the maths engine; empty for the built-in default.
    pub math_url: String,
    /// The content column in px.  0 lifts the cap, exactly as it does for the
    /// terminal renderer.
    pub max_width: usize,
    pub live: bool,
    pub follow: bool,
    pub sync_back: bool,
}

impl Default for PageOptions {
    fn default() -> Self {
        Self {
            name: String::new(),
            theme: String::from("auto"),
            math: String::from("off"),
            math_url: String::new(),
            max_width: 900,
            live: true,
            follow: true,
            sync_back: true,
        }
    }
}

type Events<'a> = [(Event<'a>, Range<usize>)];

/// Walk a document and emit its body, its contents list and its title.
///
/// Everything a re-render can change is in here; everything it cannot is in
/// [`document`].
pub fn render(source: &str, opts: &Options) -> Page {
    let events: Vec<(Event, Range<usize>)> = Parser::new_ext(source, md_options(opts))
        .into_offset_iter()
        .collect();

    let mut emitter = Emitter {
        opts,
        out: String::with_capacity(source.len() * 2),
        toc: Vec::new(),
        title: String::new(),
        line_starts: line_starts(source),
        anchors: HashMap::new(),
        notes: Vec::new(),
        raw_html: false,
    };

    let mut blocks: Vec<Block> = Vec::new();
    let mut cursor = 0usize;
    while cursor < events.len() {
        // A stray `End` at the top level closes nothing; stepping over it keeps
        // the walk moving instead of stopping the document at it.
        if matches!(events[cursor].0, Event::End(_)) {
            cursor += 1;
            continue;
        }
        let line = emitter.line_of(events[cursor].1.start);
        let from = emitter.out.len();
        emitter.block(&events, &mut cursor);
        // A block that emitted nothing — front matter with `frontmatter` off, a
        // footnote definition on its way to the section at the end — is not a
        // block the page has a child for.
        if emitter.out.len() > from {
            blocks.push(Block {
                at: from..emitter.out.len(),
                line,
            });
        }
    }
    let from = emitter.out.len();
    emitter.footnote_section();
    if emitter.out.len() > from {
        // The section is not at any source line: it is assembled from
        // definitions that were written all over the document.
        blocks.push(Block {
            at: from..emitter.out.len(),
            line: 0,
        });
    }

    // Every block has to be exactly one element for the page to be able to
    // splice by child index.  Raw HTML is not: it goes out untouched, so it can
    // be two elements, or half of one.  Bare inline at the top level is not an
    // element at all.
    let splittable = !emitter.raw_html
        && blocks
            .iter()
            .all(|block| emitter.out[block.at.clone()].starts_with('<'));

    Page {
        title: emitter.title,
        body: emitter.out,
        blocks,
        splittable,
        toc: emitter.toc,
    }
}

/// The same option set the terminal renderer builds, plus maths when asked
/// for.  The two previews disagreeing about what the document *is* would be
/// worse than either of them being wrong on its own.
fn md_options(opts: &Options) -> MdOptions {
    let mut md = MdOptions::empty();
    md.insert(MdOptions::ENABLE_TABLES);
    md.insert(MdOptions::ENABLE_FOOTNOTES);
    md.insert(MdOptions::ENABLE_STRIKETHROUGH);
    md.insert(MdOptions::ENABLE_TASKLISTS);
    md.insert(MdOptions::ENABLE_HEADING_ATTRIBUTES);
    md.insert(MdOptions::ENABLE_YAML_STYLE_METADATA_BLOCKS);
    md.insert(MdOptions::ENABLE_PLUSES_DELIMITED_METADATA_BLOCKS);
    md.insert(MdOptions::ENABLE_DEFINITION_LIST);
    md.insert(MdOptions::ENABLE_SUPERSCRIPT);
    md.insert(MdOptions::ENABLE_SUBSCRIPT);
    // GFM alerts (`> [!NOTE]`) ride on this flag.
    md.insert(MdOptions::ENABLE_GFM);
    if opts.math {
        md.insert(MdOptions::ENABLE_MATH);
    }
    md
}

/// Byte offset of the start of every source line, for offset → line lookup.
fn line_starts(source: &str) -> Vec<usize> {
    let mut starts = vec![0usize];
    starts.extend(source.match_indices('\n').map(|(index, _)| index + 1));
    starts
}

/// A footnote, in first-reference order.
struct Note {
    label: String,
    /// The definition's blocks, once one has been walked.
    html: String,
    /// A definition may be missing, and an empty one is still a definition.
    defined: bool,
    /// How many times the body has pointed at it.  Only the first reference
    /// carries the `id` the back-link aims at: two elements with one id is not
    /// HTML, and the back-link has to land somewhere.
    refs: usize,
}

struct Emitter<'a> {
    opts: &'a Options,
    out: String,
    toc: Vec<TocItem>,
    title: String,
    line_starts: Vec<usize>,
    /// How many headings have already claimed each slug, so the second
    /// `## Notes` becomes `notes-1` exactly as it does on GitHub — and exactly
    /// as `outline.rs` numbers it, so a link into the document resolves the
    /// same way in the browser and in the terminal.
    anchors: HashMap<String, usize>,
    notes: Vec<Note>,
    /// Set when a raw HTML block has gone out verbatim; see [`Page::splittable`].
    raw_html: bool,
}

// ─────────────────────────── block walk ───────────────────────────

impl Emitter<'_> {
    fn line_of(&self, offset: usize) -> usize {
        self.line_starts
            .partition_point(|start| *start <= offset)
            .max(1)
    }

    fn unique_anchor(&mut self, text: &str) -> String {
        let base = slug(text);
        let seen = self.anchors.entry(base.clone()).or_insert(0);
        *seen += 1;
        if *seen == 1 {
            base
        } else {
            format!("{base}-{}", *seen - 1)
        }
    }

    /// Render inline content into a string of its own instead of into the page.
    /// Used where the markup has to be inspected before it is placed — a
    /// heading's text, a link with nothing between its brackets.
    fn capture(&mut self, ev: &Events, i: &mut usize) -> String {
        let held = std::mem::take(&mut self.out);
        self.inline(ev, i);
        std::mem::replace(&mut self.out, held)
    }

    fn blocks(&mut self, ev: &Events, i: &mut usize) {
        while *i < ev.len() {
            if matches!(ev[*i].0, Event::End(_)) {
                return;
            }
            self.block(ev, i);
        }
    }

    fn block(&mut self, ev: &Events, i: &mut usize) {
        let (event, range) = &ev[*i];
        let line = self.line_of(range.start);
        match event {
            Event::Start(Tag::Paragraph) => {
                *i += 1;
                match lone_display_math(ev, *i) {
                    // `$$…$$` alone is a paragraph as far as the parser is
                    // concerned, and a `<div>` inside a `<p>` closes the
                    // paragraph in every HTML parser there is.  A formula that
                    // is its own paragraph is emitted as the block it looks
                    // like; one sharing a line with prose stays inline below.
                    Some(tex) => {
                        push!(
                            self.out,
                            "<div class=\"sm-math sm-math-display\" data-line=\"{line}\" data-tex=\"{}\">$${}$$</div>\n",
                            escape_attr(tex),
                            escape_text(tex)
                        );
                        while *i < ev.len() && !matches!(ev[*i].0, Event::End(_)) {
                            *i += 1;
                        }
                    }
                    None => {
                        push!(self.out, "<p data-line=\"{line}\">");
                        self.inline(ev, i);
                        self.out.push_str("</p>\n");
                    }
                }
                *i += 1;
            }
            Event::Start(Tag::Heading { level, .. }) => {
                let level = heading_level(*level);
                *i += 1;
                let from = *i;
                let inner = self.capture(ev, i);
                let text = plain_text(&ev[from..*i]);
                *i += 1;
                self.heading(level, &inner, text, line);
            }
            Event::Start(Tag::BlockQuote(kind)) => {
                let kind = *kind;
                *i += 1;
                match kind {
                    Some(kind) => {
                        let (class, title, icon) = alert(kind);
                        push!(
                            self.out,
                            "<blockquote class=\"sm-alert {class}\" data-line=\"{line}\">\n<p class=\"sm-alert-title\">{icon}{title}</p>\n"
                        );
                    }
                    None => push!(self.out, "<blockquote data-line=\"{line}\">\n"),
                }
                self.blocks(ev, i);
                self.out.push_str("</blockquote>\n");
                *i += 1;
            }
            Event::Start(Tag::CodeBlock(kind)) => {
                let info = match kind {
                    CodeBlockKind::Fenced(info) => info.to_string(),
                    CodeBlockKind::Indented => String::new(),
                };
                *i += 1;
                let code = raw_text(ev, i);
                *i += 1;
                self.code_block(&info, &code, line);
            }
            Event::Start(Tag::List(first)) => {
                let first = *first;
                *i += 1;
                match first {
                    // `start="1"` is where the browser starts anyway.
                    Some(1) => push!(self.out, "<ol data-line=\"{line}\">\n"),
                    Some(number) => {
                        push!(self.out, "<ol start=\"{number}\" data-line=\"{line}\">\n")
                    }
                    None => push!(self.out, "<ul data-line=\"{line}\">\n"),
                }
                self.list_items(ev, i);
                self.out.push_str(if first.is_some() {
                    "</ol>\n"
                } else {
                    "</ul>\n"
                });
                *i += 1;
            }
            Event::Start(Tag::Table(aligns)) => {
                let aligns = aligns.clone();
                *i += 1;
                self.table(&aligns, ev, i, line);
                *i += 1;
            }
            Event::Start(Tag::HtmlBlock) => {
                *i += 1;
                let raw = raw_text(ev, i);
                *i += 1;
                // Verbatim, and unwrapped: see the module comment.  It also
                // means the block carries no `data-line`, which costs it a
                // scroll-sync anchor and is the honest price of not touching it
                // — and it is why the document as a whole stops being pushed to
                // the browser a block at a time; see [`Page::splittable`].
                self.raw_html = true;
                self.out.push_str(&raw);
            }
            Event::Start(Tag::MetadataBlock(_)) => {
                *i += 1;
                let raw = raw_text(ev, i);
                *i += 1;
                if self.opts.frontmatter {
                    push!(
                        self.out,
                        "<details class=\"sm-frontmatter\" data-line=\"{line}\"><summary>front matter</summary><pre><code>{}</code></pre></details>\n",
                        escape_text(raw.trim_end_matches('\n'))
                    );
                }
            }
            Event::Start(Tag::FootnoteDefinition(label)) => {
                let label = label.to_string();
                *i += 1;
                let held = std::mem::take(&mut self.out);
                self.blocks(ev, i);
                let html = std::mem::replace(&mut self.out, held);
                *i += 1;
                let number = self.note_number(&label);
                let note = &mut self.notes[number - 1];
                // Stripped, because this block is about to be moved.  The page's
                // scroll sync bisects `data-line` and so needs it to ascend down
                // the document; a definition written in the middle of the source
                // and rendered at the end would carry a line number from behind
                // everything around it, and every lookup past that point would
                // land somewhere else.  Losing the mapping for a footnote's own
                // paragraphs costs the cursor a jump to the nearest block above
                // them, which is what an unmapped block gets everywhere else.
                note.html = strip_source_lines(&html);
                note.defined = true;
            }
            Event::Start(Tag::DefinitionList) => {
                *i += 1;
                push!(self.out, "<dl data-line=\"{line}\">\n");
                self.definitions(ev, i);
                self.out.push_str("</dl>\n");
                *i += 1;
            }
            Event::Rule => {
                push!(self.out, "<hr data-line=\"{line}\">\n");
                *i += 1;
            }
            Event::End(_) => *i += 1,
            _ => {
                // Bare inline where a block was expected.  A tight list item
                // arrives this way — CommonMark drops the paragraph wrapper —
                // so this is a normal path and not a fallback.
                let from = *i;
                self.inline(ev, i);
                if *i == from {
                    // `inline` stops at any container it does not recognise.
                    // Stepping over it is what keeps the walk finite when a
                    // future pulldown-cmark grows a tag neither side knows.
                    *i += 1;
                }
            }
        }
    }

    fn heading(&mut self, level: u8, inner: &str, text: String, line: usize) {
        let anchor = self.unique_anchor(&text);
        // The page title is the document's own H1; the shell falls back to the
        // file name when there is none.
        if level == 1 && self.title.is_empty() {
            self.title = text.clone();
        }
        let id = escape_attr(&anchor);
        push!(
            self.out,
            "<h{level} id=\"{id}\" data-line=\"{line}\">{inner}<a class=\"sm-anchor\" href=\"#{id}\" aria-hidden=\"true\">#</a></h{level}>\n"
        );
        self.toc.push(TocItem {
            level,
            text,
            anchor,
        });
    }

    fn list_items(&mut self, ev: &Events, i: &mut usize) {
        while *i < ev.len() {
            match &ev[*i].0 {
                Event::Start(Tag::Item) => {
                    let line = self.line_of(ev[*i].1.start);
                    *i += 1;
                    // The marker, when there is one, is the item's first event.
                    let task = match ev.get(*i).map(|(event, _)| event) {
                        Some(Event::TaskListMarker(done)) => {
                            *i += 1;
                            Some(*done)
                        }
                        _ => None,
                    };
                    match task {
                        Some(done) => {
                            let checked = if done { " checked" } else { "" };
                            push!(
                                self.out,
                                "<li class=\"sm-task\" data-line=\"{line}\"><input class=\"sm-check\" type=\"checkbox\" disabled{checked}>"
                            );
                        }
                        None => push!(self.out, "<li data-line=\"{line}\">"),
                    }
                    self.blocks(ev, i);
                    self.out.push_str("</li>\n");
                    *i += 1;
                }
                Event::End(_) => break,
                // Stray content between items; render it rather than lose it.
                _ => self.block(ev, i),
            }
        }
    }

    fn table(&mut self, aligns: &[Alignment], ev: &Events, i: &mut usize, line: usize) {
        // The wrapper is what scrolls: a table wider than the column has to
        // take its overflow with it rather than give the whole page a
        // horizontal scrollbar.
        push!(
            self.out,
            "<div class=\"sm-table-wrap\" data-line=\"{line}\">\n<table>\n"
        );
        let mut body = false;
        while *i < ev.len() {
            match &ev[*i].0 {
                Event::Start(Tag::TableHead) => {
                    *i += 1;
                    self.out.push_str("<thead>\n<tr>");
                    self.cells("th", aligns, ev, i);
                    self.out.push_str("</tr>\n</thead>\n");
                    *i += 1;
                }
                Event::Start(Tag::TableRow) => {
                    *i += 1;
                    if !body {
                        self.out.push_str("<tbody>\n");
                        body = true;
                    }
                    self.out.push_str("<tr>");
                    self.cells("td", aligns, ev, i);
                    self.out.push_str("</tr>\n");
                    *i += 1;
                }
                Event::End(_) => break,
                _ => *i += 1,
            }
        }
        if body {
            self.out.push_str("</tbody>\n");
        }
        self.out.push_str("</table>\n</div>\n");
    }

    fn cells(&mut self, name: &str, aligns: &[Alignment], ev: &Events, i: &mut usize) {
        let mut column = 0usize;
        while *i < ev.len() {
            match &ev[*i].0 {
                Event::Start(Tag::TableCell) => {
                    *i += 1;
                    let align = aligns.get(column).copied().unwrap_or(Alignment::None);
                    push!(self.out, "<{name}{}>", align_style(align));
                    self.inline(ev, i);
                    push!(self.out, "</{name}>");
                    *i += 1;
                    column += 1;
                }
                Event::End(_) => break,
                _ => *i += 1,
            }
        }
    }

    fn definitions(&mut self, ev: &Events, i: &mut usize) {
        while *i < ev.len() {
            match &ev[*i].0 {
                Event::Start(Tag::DefinitionListTitle) => {
                    *i += 1;
                    self.out.push_str("<dt>");
                    self.inline(ev, i);
                    self.out.push_str("</dt>\n");
                    *i += 1;
                }
                Event::Start(Tag::DefinitionListDefinition) => {
                    *i += 1;
                    self.out.push_str("<dd>");
                    self.blocks(ev, i);
                    self.out.push_str("</dd>\n");
                    *i += 1;
                }
                Event::End(_) => break,
                _ => *i += 1,
            }
        }
    }

    fn code_block(&mut self, info: &str, code: &str, line: usize) {
        let label = language_label(info);
        push!(
            self.out,
            "<figure class=\"sm-code\" data-line=\"{line}\" data-lang=\"{}\">",
            escape_attr(label)
        );
        push!(
            self.out,
            "<figcaption class=\"sm-code-head\"><span class=\"sm-code-lang\">{}</span><button class=\"sm-copy\" type=\"button\">Copy</button></figcaption>",
            escape_text(label)
        );
        self.out.push_str("<pre><code>");

        // Nothing expands the tabs.  The terminal renderer has to, because a
        // terminal cell is a cell; in a browser `tab-size` is the stylesheet's
        // business, and expanding them here would take that away from it.
        let lines: Vec<String> = code.lines().map(str::to_string).collect();
        // `highlight::block` is the memoised entry point, and it is memoised for
        // exactly this: the preview re-renders the whole document on every
        // keystroke burst, and the fences are almost never what changed.
        let highlighted = self
            .opts
            .syntax
            .then(|| highlight::block(info, &lines))
            .filter(|spans| !spans.is_empty());
        let empty: &[(usize, usize, &'static str)] = &[];

        for (index, text) in lines.iter().enumerate() {
            if index > 0 {
                self.out.push('\n');
            }
            let spans = highlighted
                .as_ref()
                .and_then(|all| all.get(index))
                .map_or(empty, Vec::as_slice);
            let mut at = 0usize;
            for (offset, len, class) in spans {
                let end = offset + len;
                // A span that does not line up with the bytes it was computed
                // from is dropped rather than slicing mid-character: this is a
                // user's document, and the cost of being wrong here is a panic
                // in the middle of a render.
                if *offset < at
                    || end > text.len()
                    || !text.is_char_boundary(*offset)
                    || !text.is_char_boundary(end)
                {
                    continue;
                }
                push!(self.out, "{}", escape_text(&text[at..*offset]));
                match syntax_class(class) {
                    Some(name) => push!(
                        self.out,
                        "<span class=\"{name}\">{}</span>",
                        escape_text(&text[*offset..end])
                    ),
                    None => push!(self.out, "{}", escape_text(&text[*offset..end])),
                }
                at = end;
            }
            push!(self.out, "{}", escape_text(&text[at..]));
        }
        self.out.push_str("</code></pre></figure>\n");
    }
}

// ─────────────────────────── inline walk ───────────────────────────

impl Emitter<'_> {
    /// Emit inline content, stopping at (but not consuming) the `End` that
    /// closes the enclosing element, or at a block tag the caller must handle.
    fn inline(&mut self, ev: &Events, i: &mut usize) {
        while *i < ev.len() {
            match &ev[*i].0 {
                Event::End(_) => return,
                Event::Text(text) => {
                    push!(self.out, "{}", escape_text(text));
                    *i += 1;
                }
                Event::Code(text) => {
                    push!(self.out, "<code>{}</code>", escape_text(text));
                    *i += 1;
                }
                Event::InlineMath(tex) => {
                    // The literal `$…$` stays in the element.  That is what the
                    // reader sees when the engine does not load, and what the
                    // engine replaces when it does.
                    push!(
                        self.out,
                        "<span class=\"sm-math\" data-tex=\"{}\">${}$</span>",
                        escape_attr(tex),
                        escape_text(tex)
                    );
                    *i += 1;
                }
                Event::DisplayMath(tex) => {
                    // A formula that shares its paragraph with prose: a `<span>`
                    // the stylesheet shows as a block, because a real `<div>`
                    // here would end the paragraph around it.
                    push!(
                        self.out,
                        "<span class=\"sm-math sm-math-display\" data-tex=\"{}\">$${}$$</span>",
                        escape_attr(tex),
                        escape_text(tex)
                    );
                    *i += 1;
                }
                Event::Html(text) | Event::InlineHtml(text) => {
                    self.out.push_str(text);
                    *i += 1;
                }
                Event::SoftBreak => {
                    // A newline, not a `<br>`.  CSS's segment-break rules delete
                    // a line break between two CJK characters and turn one
                    // between Latin words into a space, which is exactly what
                    // the source meant; `<br>` would instead print a Chinese
                    // paragraph one source line at a time.
                    self.out.push('\n');
                    *i += 1;
                }
                Event::HardBreak => {
                    self.out.push_str("<br>\n");
                    *i += 1;
                }
                Event::FootnoteReference(label) => {
                    let number = self.note_number(label);
                    let note = &mut self.notes[number - 1];
                    note.refs += 1;
                    let id = if note.refs == 1 {
                        format!(" id=\"fnref-{number}\"")
                    } else {
                        String::new()
                    };
                    push!(
                        self.out,
                        "<sup class=\"sm-fnref\"{id}><a href=\"#fn-{number}\">{number}</a></sup>"
                    );
                    *i += 1;
                }
                Event::Start(tag) => {
                    if !self.inline_tag(tag, ev, i) {
                        // A block tag inside an inline run: hand it back.
                        return;
                    }
                }
                _ => *i += 1,
            }
        }
    }

    /// Emit one inline container and its children.  False when `tag` is not an
    /// inline one, having consumed nothing.
    fn inline_tag(&mut self, tag: &Tag, ev: &Events, i: &mut usize) -> bool {
        let simple = match tag {
            Tag::Emphasis => Some("em"),
            Tag::Strong => Some("strong"),
            Tag::Strikethrough => Some("del"),
            Tag::Superscript => Some("sup"),
            Tag::Subscript => Some("sub"),
            _ => None,
        };
        if let Some(name) = simple {
            push!(self.out, "<{name}>");
            *i += 1;
            self.inline(ev, i);
            *i += 1;
            push!(self.out, "</{name}>");
            return true;
        }
        match tag {
            Tag::Link {
                dest_url, title, ..
            } => {
                *i += 1;
                let inner = self.capture(ev, i);
                *i += 1;
                // `[](x)` has nothing between its brackets and would render as
                // a link with no surface to click.
                let text = if inner.trim().is_empty() {
                    escape_text(dest_url).into_owned()
                } else {
                    inner
                };
                push!(
                    self.out,
                    "<a href=\"{}\"{}>{text}</a>",
                    escape_href(dest_url),
                    title_attr(title)
                );
                true
            }
            Tag::Image {
                dest_url, title, ..
            } => {
                *i += 1;
                let from = *i;
                skip_inline(ev, i);
                // An `<img>` has nowhere to put marked-up children, so the alt
                // text is the image's inline content flattened.
                let alt = plain_text(&ev[from..*i]);
                *i += 1;
                // A relative source stays relative: the server serves the
                // document's own directory, so `./diagram.png` resolves to the
                // file sitting next to it.
                push!(
                    self.out,
                    "<img src=\"{}\" alt=\"{}\"{} loading=\"lazy\">",
                    escape_href(dest_url),
                    escape_attr(&alt),
                    title_attr(title)
                );
                true
            }
            _ => false,
        }
    }
}

// ─────────────────────────── footnotes ───────────────────────────

impl Emitter<'_> {
    /// The number a label gets, assigned in order of first appearance so a
    /// reference and its definition agree — and so the reader counts upwards
    /// down the page rather than in the order the definitions were typed.
    fn note_number(&mut self, label: &str) -> usize {
        match self.notes.iter().position(|note| note.label == label) {
            Some(index) => index + 1,
            None => {
                self.notes.push(Note {
                    label: label.to_string(),
                    html: String::new(),
                    defined: false,
                    refs: 0,
                });
                self.notes.len()
            }
        }
    }

    /// Move the definitions to the foot of the document.
    ///
    /// A footnote's label is the user's text (`[^a note]`), so it cannot be
    /// used in an id; the numbers are the identity, here and at the references.
    fn footnote_section(&mut self) {
        let notes = std::mem::take(&mut self.notes);
        if !notes.iter().any(|note| note.defined) {
            return;
        }
        self.out.push_str(
            "<section class=\"sm-footnotes\">\n<h2 class=\"sm-footnotes-title\">Footnotes</h2>\n<ol>\n",
        );
        for (index, note) in notes.iter().enumerate() {
            if !note.defined {
                continue;
            }
            let number = index + 1;
            let back = format!("<a class=\"sm-fnback\" href=\"#fnref-{number}\">↩</a>");
            let body = note.html.trim_end();
            // The back-link belongs at the end of the last sentence, the way
            // GitHub places it, not on a line of its own below the note.
            let filled = match body.strip_suffix("</p>") {
                Some(head) => format!("{head}{back}</p>"),
                None => format!("{body}{back}"),
            };
            // A label that was referred to and never defined is skipped above
            // and leaves a hole; `value` states each note's own number rather
            // than letting the browser count its way out of step with the
            // references pointing at it.
            push!(
                self.out,
                "<li id=\"fn-{number}\" value=\"{number}\">\n{filled}\n</li>\n"
            );
        }
        self.out.push_str("</ol>\n</section>\n");
    }
}

// ─────────────────────────── the page shell ───────────────────────────

// jsDelivr, not cdnjs or unpkg: it is the one of the three that resolves from
// inside China, which is where this plugin is written and used.  Pinning the
// minor is deliberate — a maths engine that silently becomes a major version
// newer is a preview that breaks on a Tuesday.
const KATEX_JS: &str = "https://cdn.jsdelivr.net/npm/katex@0.16/dist/katex.min.js";
const KATEX_CSS: &str = "https://cdn.jsdelivr.net/npm/katex@0.16/dist/katex.min.css";
const MATHJAX_JS: &str = "https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js";

/// The whole page: shell, stylesheet, script and body in one response.
pub fn document(page: &Page, opts: &PageOptions, seq: u64) -> String {
    let css = include_str!("assets/preview.css");
    let js = include_str!("assets/preview.js");

    let title = if page.title.is_empty() {
        opts.name.as_str()
    } else {
        page.title.as_str()
    };
    let column = if opts.max_width == 0 {
        // `max-width: none` — the same meaning 0 has for the terminal renderer.
        String::from("none")
    } else {
        format!("{}px", opts.max_width)
    };

    let config = Config {
        seq,
        live: opts.live,
        follow: opts.follow,
        sync_back: opts.sync_back,
        theme: &opts.theme,
        math: &opts.math,
        math_url: math_src(opts).unwrap_or_default(),
        toc: &page.toc,
        name: &opts.name,
    };
    // Nothing in here was escaped by hand, and nothing needs to be — except
    // that the HTML parser is still reading this element while the JSON sits
    // inside it, and a document's own text reaches it through the title and the
    // contents list.  `</script>` would end the element; `<!--` is worse, since
    // it puts the parser into a state where the *next* element's `</script>`
    // does not end it either, and the page's whole script is swallowed by a
    // heading.  Escaping every `<` as `\u003c` is the same string to a
    // JavaScript parser and is invisible to the HTML one, which covers both and
    // anything else `<` could start.
    let config = serde_json::to_string(&config)
        .unwrap_or_else(|_| String::from("{}"))
        .replace('<', "\\u003c");

    let mut out = String::with_capacity(css.len() + js.len() + page.body.len() + 4096);
    push!(
        out,
        "<!DOCTYPE html>\n<html lang=\"en\" data-theme=\"{}\" style=\"--sm-max-width: {column}\">\n",
        escape_attr(&opts.theme)
    );
    out.push_str("<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    push!(out, "<title>{}</title>\n", escape_text(title));
    push!(out, "<style>\n{css}\n</style>\n");
    out.push_str(&math_head(opts));
    out.push_str("</head>\n<body>\n");
    out.push_str(
        "<aside id=\"sm-toc\" class=\"sm-toc\" hidden><nav id=\"sm-toc-list\"></nav></aside>\n",
    );
    out.push_str("<main id=\"sm-main\"><article id=\"sm-doc\" class=\"sm-body\">\n");
    out.push_str(&page.body);
    out.push_str("</article></main>\n");
    out.push_str(BAR);
    push!(out, "<script>window.SM = {config};</script>\n");
    push!(out, "<script>\n{js}\n</script>\n");
    out.push_str("</body>\n</html>\n");
    out
}

/// `window.SM`.  Built through serde rather than by hand so a document title
/// full of quotes cannot break the page.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Config<'a> {
    /// Which document the shell was built from.  The page tells the daemon on
    /// connect, so a browser that has just been served the document is not
    /// immediately sent it again down the stream.
    seq: u64,
    live: bool,
    follow: bool,
    sync_back: bool,
    theme: &'a str,
    math: &'a str,
    math_url: String,
    toc: &'a [TocItem],
    name: &'a str,
}

/// Where the maths engine comes from, or `None` when there is none.
fn math_src(opts: &PageOptions) -> Option<String> {
    let default = match opts.math.as_str() {
        "katex" => KATEX_JS,
        "mathjax" => MATHJAX_JS,
        _ => return None,
    };
    Some(if opts.math_url.is_empty() {
        default.to_string()
    } else {
        opts.math_url.clone()
    })
}

/// The one remote resource the page is allowed to name.  It is `defer`red, so a
/// browser that cannot reach it has already drawn the document with the raw
/// `$…$` in place — which is a worse-looking page, not a broken one.
fn math_head(opts: &PageOptions) -> String {
    let Some(src) = math_src(opts) else {
        return String::new();
    };
    let mut head = String::new();
    if opts.math == "katex" {
        // KaTeX is a script *and* a stylesheet, and a custom URL names the
        // script; the stylesheet that goes with it is the one beside it.
        let css = match src.strip_suffix(".js") {
            Some(stem) => format!("{stem}.css"),
            None => KATEX_CSS.to_string(),
        };
        // `media="print"` until it has loaded, which is the standard way to
        // fetch a stylesheet without blocking the first paint.  A plain
        // stylesheet link in the head is render-blocking: with the CDN slow or
        // unreachable — and this is the one resource on the page that is not
        // served from this machine — the reader would sit in front of a blank
        // tab until the request gave up, waiting on the typesetting of formulas
        // the document may not even contain.
        push!(
            head,
            "<link rel=\"stylesheet\" href=\"{}\" media=\"print\" onload=\"this.media='all'\">\n",
            escape_attr(&css)
        );
    }
    push!(
        head,
        "<script defer src=\"{}\"></script>\n",
        escape_attr(&src)
    );
    head
}

/// The floating toolbar.  The icons are drawn here rather than fetched from an
/// icon font for the same reason everything else is inlined.
const BAR: &str = r#"<div id="sm-bar" class="sm-bar">
<button id="sm-toc-btn" class="sm-btn" type="button" title="Contents"><svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M2.2 4h11.6M2.2 8h11.6M2.2 12h7.6" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg></button>
<button id="sm-follow" class="sm-btn" type="button" title="Follow the cursor"><svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><circle cx="8" cy="8" r="5" fill="none" stroke="currentColor" stroke-width="1.6"/><circle cx="8" cy="8" r="1.7" fill="currentColor"/><path d="M8 .9v2.2M8 12.9v2.2M.9 8h2.2M12.9 8h2.2" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg></button>
<button id="sm-theme" class="sm-btn" type="button" title="Theme"><svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M8 1.8a6.2 6.2 0 0 1 0 12.4Z" fill="currentColor"/></svg></button>
<span id="sm-dot" class="sm-dot" title="live"></span>
</div>
"#;

// ─────────────────────────── escaping ───────────────────────────

/// The three characters that can start something in text.  Borrowed back
/// unchanged when there are none, which is nearly every run in a document.
fn escape_text(text: &str) -> Cow<'_, str> {
    if !text.contains(['&', '<', '>']) {
        return Cow::Borrowed(text);
    }
    let mut out = String::with_capacity(text.len() + 16);
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(ch),
        }
    }
    Cow::Owned(out)
}

/// Everything [`escape_text`] does, plus both quotes: an attribute value is
/// only as safe as the delimiter it is sitting inside.
fn escape_attr(text: &str) -> Cow<'_, str> {
    if !text.contains(['&', '<', '>', '"', '\'']) {
        return Cow::Borrowed(text);
    }
    let mut out = String::with_capacity(text.len() + 16);
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(ch),
        }
    }
    Cow::Owned(out)
}

/// A link target, made safe to put inside `href="…"`.
///
/// Two things happen here.  Control characters are removed, because a browser
/// ignores tabs and newlines inside a URL and `java&#10;script:` would be a
/// scheme test passed and a script run; testing the cleaned string and then
/// emitting the original would be the same bug with extra steps.  And a
/// `javascript:` target is rewritten to `#`, because the preview renders
/// documents its reader did not necessarily write, and a link is the one thing
/// in a Markdown file a reader is invited to click.  Escaping the `&` on the
/// way out is what stops an entity from re-forming the scheme in the browser's
/// parser.
fn escape_href(url: &str) -> String {
    let cleaned: String = url.chars().filter(|ch| !ch.is_control()).collect();
    let cleaned = cleaned.trim();
    if let Some(colon) = cleaned.find(':') {
        let scheme = &cleaned[..colon];
        if !scheme.is_empty()
            && scheme
                .chars()
                .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '+' | '-' | '.'))
            && matches!(
                scheme.to_ascii_lowercase().as_str(),
                "javascript" | "vbscript"
            )
        {
            return String::from("#");
        }
    }
    escape_attr(cleaned).into_owned()
}

/// A link's or image's title, as an attribute or as nothing at all.
fn title_attr(title: &str) -> String {
    if title.is_empty() {
        String::new()
    } else {
        format!(" title=\"{}\"", escape_attr(title))
    }
}

// ─────────────────────────── helpers ───────────────────────────

fn heading_level(level: HeadingLevel) -> u8 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}

fn align_style(align: Alignment) -> &'static str {
    match align {
        Alignment::Left => " style=\"text-align:left\"",
        Alignment::Center => " style=\"text-align:center\"",
        Alignment::Right => " style=\"text-align:right\"",
        Alignment::None => "",
    }
}

/// The class, title and icon of a GFM alert.
fn alert(kind: BlockQuoteKind) -> (&'static str, &'static str, &'static str) {
    match kind {
        BlockQuoteKind::Note => ("sm-alert-note", "Note", ICON_NOTE),
        BlockQuoteKind::Tip => ("sm-alert-tip", "Tip", ICON_TIP),
        BlockQuoteKind::Important => ("sm-alert-important", "Important", ICON_IMPORTANT),
        BlockQuoteKind::Warning => ("sm-alert-warning", "Warning", ICON_WARNING),
        BlockQuoteKind::Caution => ("sm-alert-caution", "Caution", ICON_CAUTION),
    }
}

const ICON_NOTE: &str = r#"<svg class="sm-alert-icon" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><circle cx="8" cy="8" r="6.6" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M8 7.2v4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><circle cx="8" cy="4.7" r=".95" fill="currentColor"/></svg>"#;
const ICON_TIP: &str = r#"<svg class="sm-alert-icon" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M8 1.6a4.4 4.4 0 0 0-2.6 7.9c.4.3.6.7.6 1.1v.6h4v-.6c0-.4.2-.8.6-1.1A4.4 4.4 0 0 0 8 1.6Z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/><path d="M6.6 13.6h2.8" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>"#;
const ICON_IMPORTANT: &str = r#"<svg class="sm-alert-icon" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M2 2.6h12v8.2H7.6L4.4 13.4v-2.6H2Z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/><path d="M8 4.9v2.9" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><circle cx="8" cy="9.4" r=".9" fill="currentColor"/></svg>"#;
const ICON_WARNING: &str = r#"<svg class="sm-alert-icon" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M8 1.9 15 13.6H1Z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/><path d="M8 6.2v3.1" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><circle cx="8" cy="11.3" r=".9" fill="currentColor"/></svg>"#;
const ICON_CAUTION: &str = r#"<svg class="sm-alert-icon" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M5.5 1.6h5l3.9 3.9v5l-3.9 3.9h-5L1.6 10.5v-5Z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/><path d="M8 4.8v3.4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><circle cx="8" cy="10.6" r=".9" fill="currentColor"/></svg>"#;

/// The CSS class for one of [`crate::classes`]'s syntax classes.  The mapping
/// is spelled out rather than derived from the constant's spelling so that
/// renaming one of them is a compile-time conversation and not a silently
/// unstyled span.
fn syntax_class(class: &str) -> Option<&'static str> {
    let name = match class {
        classes::SYN_KEYWORD => "syn-keyword",
        classes::SYN_STRING => "syn-string",
        classes::SYN_COMMENT => "syn-comment",
        classes::SYN_NUMBER => "syn-number",
        classes::SYN_BOOLEAN => "syn-boolean",
        classes::SYN_TYPE => "syn-type",
        classes::SYN_FUNCTION => "syn-function",
        classes::SYN_CONSTANT => "syn-constant",
        classes::SYN_OPERATOR => "syn-operator",
        classes::SYN_PUNCT => "syn-punct",
        classes::SYN_VARIABLE => "syn-variable",
        classes::SYN_PROPERTY => "syn-property",
        classes::SYN_PREPROC => "syn-preproc",
        classes::SYN_TAG => "syn-tag",
        classes::SYN_ESCAPE => "syn-escape",
        classes::SYN_INVALID => "syn-invalid",
        _ => return None,
    };
    Some(name)
}

/// Remove every `data-line` attribute from a fragment.
///
/// Only relocated content needs this, and only because the index that reads
/// those attributes is bisected rather than scanned; see the call site.
fn strip_source_lines(html: &str) -> String {
    const ATTR: &str = " data-line=\"";
    let mut out = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(at) = rest.find(ATTR) {
        out.push_str(&rest[..at]);
        let after = &rest[at + ATTR.len()..];
        match after.find('"') {
            Some(end) => rest = &after[end + 1..],
            // Unterminated, which nothing this module emits can produce.
            // Keeping the tail is a better answer than truncating it.
            None => {
                out.push_str(after);
                return out;
            }
        }
    }
    out.push_str(rest);
    out
}

/// The first word of a fence's info string: `rust`, `js`, `sh`.
fn language_label(info: &str) -> &str {
    info.split(|ch: char| ch.is_whitespace() || ch == ',' || ch == '{')
        .find(|part| !part.is_empty())
        .unwrap_or("")
        .trim_start_matches('.')
}

/// Raw text with no inline parsing: code block bodies, HTML blocks, front
/// matter.
fn raw_text(ev: &Events, i: &mut usize) -> String {
    let mut out = String::new();
    while *i < ev.len() {
        match &ev[*i].0 {
            Event::Text(text) | Event::Html(text) | Event::InlineHtml(text) | Event::Code(text) => {
                out.push_str(text);
                *i += 1;
            }
            Event::SoftBreak | Event::HardBreak => {
                out.push('\n');
                *i += 1;
            }
            Event::End(_) => break,
            _ => *i += 1,
        }
    }
    out
}

/// Walk to the `End` that closes the container the cursor is inside, emitting
/// nothing.  For content that has to be flattened rather than rendered.
fn skip_inline(ev: &Events, i: &mut usize) {
    let mut depth = 0usize;
    while *i < ev.len() {
        match &ev[*i].0 {
            Event::Start(_) => depth += 1,
            Event::End(_) if depth == 0 => return,
            Event::End(_) => depth -= 1,
            _ => {}
        }
        *i += 1;
    }
}

/// The plain text of a run of inline events, whitespace collapsed: what a
/// heading's anchor is built from and what an `<img>` puts in its `alt`.
fn plain_text(ev: &Events) -> String {
    let mut out = String::new();
    for (event, _) in ev {
        match event {
            Event::Text(text)
            | Event::Code(text)
            | Event::InlineMath(text)
            | Event::DisplayMath(text) => out.push_str(text),
            Event::SoftBreak | Event::HardBreak => out.push(' '),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The formula of a paragraph that holds one display formula and nothing else.
fn lone_display_math<'a>(ev: &'a Events, from: usize) -> Option<&'a str> {
    let mut found: Option<&str> = None;
    for (event, _) in ev.iter().skip(from) {
        match event {
            Event::End(_) => return found,
            Event::DisplayMath(tex) if found.is_none() => found = Some(tex),
            Event::SoftBreak => {}
            Event::Text(text) if text.trim().is_empty() => {}
            _ => return None,
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(source: &str) -> String {
        render(source, &Options::default()).body
    }

    #[test]
    fn headings_carry_a_github_anchor_and_repeats_are_numbered() {
        let page = render(
            "# Getting *started*\n\n## Notes\n\n## Notes\n",
            &Options::default(),
        );
        let anchors: Vec<&str> = page.toc.iter().map(|item| item.anchor.as_str()).collect();
        assert_eq!(anchors, ["getting-started", "notes", "notes-1"]);
        assert_eq!(page.title, "Getting started");
        assert!(
            page.body
                .contains("<h2 id=\"notes-1\" data-line=\"5\">Notes<a class=\"sm-anchor\""),
            "{}",
            page.body
        );
    }

    #[test]
    fn text_is_escaped_wherever_it_is_the_document_talking() {
        // A `<script>` the user *wrote about* — in a fence, in a code span, in
        // prose — is text, and text is escaped.
        let out = body("AT&T <3 `<script>` and\n\n```\n<script>alert(1)</script>\n```\n");
        assert!(out.contains("AT&amp;T &lt;3"), "{out}");
        assert!(out.contains("<code>&lt;script&gt;</code>"), "{out}");
        assert!(out.contains("&lt;script&gt;alert(1)"), "{out}");
        assert!(!out.contains("<script>"), "{out}");
    }

    #[test]
    fn a_javascript_href_is_neutralised() {
        let out = body("[click](JavaScript:alert(1)) and [ok](./notes.md)\n");
        assert!(out.contains("href=\"#\""), "{out}");
        assert!(!out.to_lowercase().contains("javascript:"), "{out}");
        // Ordinary targets are left exactly as the document wrote them.
        assert!(out.contains("href=\"./notes.md\""), "{out}");
    }

    #[test]
    fn a_quote_cannot_escape_an_attribute() {
        let out = body("![a \"quoted\" caption](x.png)\n");
        assert!(
            out.contains("alt=\"a &quot;quoted&quot; caption\""),
            "{out}"
        );
    }

    #[test]
    fn every_block_says_which_source_line_it_came_from() {
        let out = body("# T\n\n```rust\nfn x() {}\n```\n\ntail\n");
        assert!(out.contains("<h1 id=\"t\" data-line=\"1\">"), "{out}");
        assert!(
            out.contains("<figure class=\"sm-code\" data-line=\"3\" data-lang=\"rust\">"),
            "{out}"
        );
        assert!(out.contains("<p data-line=\"7\">tail</p>"), "{out}");
    }

    #[test]
    fn code_is_highlighted_into_the_agreed_classes() {
        let out = body("```rust\nfn main() {}\n```\n");
        assert!(out.contains("class=\"syn-keyword\""), "{out}");
        assert!(out.contains("<button class=\"sm-copy\" type=\"button\">Copy</button>"));
    }

    #[test]
    fn an_unknown_language_still_renders_its_code() {
        let out = body("```definitely-not-a-language\nplain <text>\n```\n");
        assert!(out.contains("plain &lt;text&gt;"), "{out}");
        assert!(!out.contains("<span class=\"syn-"), "{out}");
    }

    #[test]
    fn a_gfm_alert_gets_its_class_title_and_icon() {
        let out = body("> [!WARNING]\n> careful\n");
        assert!(
            out.contains("<blockquote class=\"sm-alert sm-alert-warning\" data-line=\"1\">"),
            "{out}"
        );
        assert!(out.contains("<p class=\"sm-alert-title\">"), "{out}");
        assert!(out.contains("class=\"sm-alert-icon\""), "{out}");
        assert!(out.contains("Warning</p>"), "{out}");
        assert!(out.contains("careful"), "{out}");
    }

    #[test]
    fn a_plain_quote_is_not_an_alert() {
        let out = body("> just a quote\n");
        assert!(out.contains("<blockquote data-line=\"1\">"), "{out}");
        assert!(!out.contains("sm-alert"), "{out}");
    }

    #[test]
    fn task_items_carry_a_disabled_checkbox() {
        let out = body("- [x] done\n- [ ] todo\n");
        assert!(
            out.contains(
                "<li class=\"sm-task\" data-line=\"1\"><input class=\"sm-check\" type=\"checkbox\" disabled checked>"
            ),
            "{out}"
        );
        assert!(
            out.contains(
                "<li class=\"sm-task\" data-line=\"2\"><input class=\"sm-check\" type=\"checkbox\" disabled>"
            ),
            "{out}"
        );
    }

    #[test]
    fn an_ordered_list_keeps_the_number_it_starts_at() {
        let out = body("3. three\n4. four\n");
        assert!(out.contains("<ol start=\"3\" data-line=\"1\">"), "{out}");
        // A list starting at 1 says nothing: that is what the browser does.
        assert!(body("1. one\n").contains("<ol data-line=\"1\">"));
    }

    #[test]
    fn a_table_carries_its_alignment_into_every_cell() {
        let out = body("| a | b |\n|:--|--:|\n| 1 | 2 |\n");
        assert!(
            out.contains("<div class=\"sm-table-wrap\" data-line=\"1\">"),
            "{out}"
        );
        assert!(
            out.contains("<th style=\"text-align:left\">a</th>"),
            "{out}"
        );
        assert!(
            out.contains("<th style=\"text-align:right\">b</th>"),
            "{out}"
        );
        assert!(
            out.contains("<td style=\"text-align:right\">2</td>"),
            "{out}"
        );
    }

    #[test]
    fn footnotes_move_to_the_end_and_are_numbered_by_first_reference() {
        // `b` is referred to first, so `b` is footnote 1 however the
        // definitions are ordered.
        let out = body("see[^b] then[^a]\n\n[^a]: alpha\n[^b]: beta\n");
        assert!(
            out.contains("<sup class=\"sm-fnref\" id=\"fnref-1\"><a href=\"#fn-1\">1</a></sup>"),
            "{out}"
        );
        assert!(out.contains("<a href=\"#fn-2\">2</a>"), "{out}");

        let section = out
            .find("<section class=\"sm-footnotes\">")
            .expect("a section for the definitions");
        assert!(section > out.find("see").expect("the paragraph"));
        let notes = &out[section..];
        assert!(notes.contains("<li id=\"fn-1\" value=\"1\">"), "{notes}");
        assert!(
            notes.find("beta").expect("note 1") < notes.find("alpha").expect("note 2"),
            "{notes}"
        );
        assert!(
            notes.contains("<a class=\"sm-fnback\" href=\"#fnref-1\">↩</a></p>"),
            "{notes}"
        );
        // The definition is no longer where it was written.
        assert!(!out[..section].contains("alpha"), "{out}");
    }

    #[test]
    fn a_document_without_footnotes_gets_no_section() {
        assert!(!body("plain\n").contains("sm-footnotes"));
    }

    #[test]
    fn a_soft_break_is_a_newline_and_a_hard_break_is_a_br() {
        // CSS deletes the newline between two CJK characters and turns the one
        // between Latin words into a space; `<br>` could do neither.
        let out = body("中文\n断行\n\nfirst  \nsecond\n");
        assert!(out.contains("中文\n断行"), "{out}");
        assert!(out.contains("first<br>\nsecond"), "{out}");
    }

    #[test]
    fn an_image_keeps_a_relative_source_and_loads_lazily() {
        let out = body("![a diagram](./img/one.png \"caption\")\n");
        assert!(
            out.contains(
                "<img src=\"./img/one.png\" alt=\"a diagram\" title=\"caption\" loading=\"lazy\">"
            ),
            "{out}"
        );
    }

    #[test]
    fn raw_html_passes_through_untouched() {
        let out = body("<div class=\"mine\">kept</div>\n\ntext with <b>tags</b>\n");
        assert!(out.contains("<div class=\"mine\">kept</div>"), "{out}");
        assert!(out.contains("with <b>tags</b>"), "{out}");
    }

    #[test]
    fn front_matter_is_a_details_block_or_nothing() {
        let out = body("---\ntitle: x\n---\n\nbody\n");
        assert!(
            out.contains("<details class=\"sm-frontmatter\" data-line=\"1\">"),
            "{out}"
        );
        assert!(out.contains("title: x"), "{out}");

        let hidden = render(
            "---\ntitle: x\n---\n\nbody\n",
            &Options {
                frontmatter: false,
                ..Options::default()
            },
        );
        assert!(!hidden.body.contains("title: x"), "{}", hidden.body);
        assert!(hidden.body.contains("body"), "{}", hidden.body);
    }

    #[test]
    fn maths_keeps_its_source_so_it_degrades_to_it() {
        let out = body("inline $E=mc^2$ and\n\n$$a^2+b^2$$\n");
        assert!(
            out.contains("<span class=\"sm-math\" data-tex=\"E=mc^2\">$E=mc^2$</span>"),
            "{out}"
        );
        assert!(
            out.contains(
                "<div class=\"sm-math sm-math-display\" data-line=\"3\" data-tex=\"a^2+b^2\">"
            ),
            "{out}"
        );

        let off = render(
            "inline $E=mc^2$\n",
            &Options {
                math: false,
                ..Options::default()
            },
        );
        assert!(!off.body.contains("sm-math"), "{}", off.body);
        assert!(off.body.contains("$E=mc^2$"), "{}", off.body);
    }

    #[test]
    fn a_relocated_footnote_carries_no_source_line() {
        // A definition written in the middle of the document renders at the
        // end, and a `data-line` from behind everything around it would break
        // the page's bisection for every block after it.
        let out = body("one[^a]\n\n[^a]: the note\n\ntwo\n");
        let section = out
            .find("<section class=\"sm-footnotes\">")
            .expect("a footnotes section");
        assert!(!out[section..].contains("data-line"), "{}", &out[section..]);

        // …and the document's own blocks still ascend, which is the property
        // the stripping is there to protect.
        let numbers: Vec<usize> = out[..section]
            .match_indices(" data-line=\"")
            .map(|(at, _)| {
                let rest = &out[at + " data-line=\"".len()..];
                rest[..rest.find('"').expect("a closed attribute")]
                    .parse()
                    .expect("a number")
            })
            .collect();
        assert!(
            numbers.windows(2).all(|pair| pair[0] <= pair[1]),
            "{numbers:?}"
        );
    }

    #[test]
    fn definition_lists_superscript_and_strikethrough_render() {
        // pulldown declines intraword `^`/`~`, exactly as it declines
        // intraword `_`, so the markers here stand on their own.
        let out = body("term\n: meaning\n\n~~gone~~ and ^up^ and ~down~\n");
        assert!(out.contains("<dl data-line=\"1\">"), "{out}");
        assert!(out.contains("<dt>term</dt>"), "{out}");
        assert!(out.contains("<dd>"), "{out}");
        assert!(out.contains("<del>gone</del>"), "{out}");
        assert!(out.contains("<sup>up</sup>"), "{out}");
        assert!(out.contains("<sub>down</sub>"), "{out}");
    }

    #[test]
    fn a_nested_tight_list_keeps_both_levels() {
        let out = body("- outer\n  - inner\n");
        assert!(out.contains("<li data-line=\"1\">outer"), "{out}");
        assert!(out.contains("<ul data-line=\"2\">"), "{out}");
    }

    #[test]
    fn an_empty_document_renders_to_nothing() {
        let page = render("", &Options::default());
        assert!(page.body.is_empty());
        assert!(page.toc.is_empty());
        assert!(page.title.is_empty());
    }

    #[test]
    fn the_kitchen_sink_renders_without_panicking() {
        let source = include_str!("../../tests/fixtures/kitchen-sink.md");
        let page = render(source, &Options::default());
        assert!(!page.body.is_empty());
        // Every heading in the contents can be found again in the body.
        for item in &page.toc {
            assert!(
                page.body.contains(&format!("id=\"{}\"", item.anchor)),
                "no anchor for {:?}",
                item.text
            );
        }
    }

    #[test]
    fn document_inlines_its_assets_and_reaches_for_no_cdn_with_maths_off() {
        let page = render("# Title\n\nbody\n", &Options::default());
        let opts = PageOptions {
            name: String::from("notes.md"),
            ..PageOptions::default()
        };
        let out = document(&page, &opts, 0);
        assert!(out.starts_with("<!DOCTYPE html>"));
        assert!(
            out.contains(include_str!("assets/preview.css")),
            "no stylesheet"
        );
        assert!(out.contains(include_str!("assets/preview.js")), "no script");
        assert!(out.contains(&page.body), "no body");
        assert!(!out.contains("cdn.jsdelivr.net"), "reached for a CDN");
        assert!(!out.contains("<script defer"), "loaded something remote");
        assert!(out.contains("<title>Title</title>"), "{out}");
        assert!(out.contains("id=\"sm-doc\""));
        assert!(out.contains("id=\"sm-bar\""));
    }

    #[test]
    fn document_carries_the_theme_the_column_and_the_config() {
        let page = render("body\n", &Options::default());
        let opts = PageOptions {
            name: String::from("notes.md"),
            theme: String::from("dark"),
            max_width: 720,
            sync_back: false,
            ..PageOptions::default()
        };
        let out = document(&page, &opts, 0);
        assert!(
            out.contains("<html lang=\"en\" data-theme=\"dark\" style=\"--sm-max-width: 720px\">"),
            "{out}"
        );
        // No H1: the shell falls back to the file name.
        assert!(out.contains("<title>notes.md</title>"), "{out}");
        assert!(out.contains("\"syncBack\":false"), "{out}");
        assert!(out.contains("\"theme\":\"dark\""), "{out}");
        assert!(out.contains("\"name\":\"notes.md\""), "{out}");

        // 0 lifts the cap rather than collapsing the column.
        let wide = document(
            &page,
            &PageOptions {
                max_width: 0,
                ..PageOptions::default()
            },
            0,
        );
        assert!(wide.contains("--sm-max-width: none"), "{wide}");
    }

    #[test]
    fn a_heading_cannot_close_or_comment_out_the_config_script() {
        // Both of the ways a document's own text could reach out of the config
        // element: one ends it, the other opens a comment state that swallows
        // the *page's* script along with it.
        let page = render("# a `</script>` and `<!--` heading\n", &Options::default());
        assert!(page.title.contains("</script>"), "{}", page.title);
        let out = document(&page, &PageOptions::default(), 0);
        assert!(out.contains("window.SM = {"), "{out}");
        assert!(!out.contains("</script> and"), "{out}");
        assert!(!out.contains("<!--"), "{out}");
        assert!(out.contains("\\u003c/script>"), "{out}");
        // …and the page's own script still follows, which is the thing `<!--`
        // would have taken away.
        assert!(out.contains("id=\"sm-doc\""), "{out}");
        assert!(
            out.matches("<script>").count() >= 2,
            "the config and the page script are two elements: {out}"
        );
    }

    #[test]
    fn maths_names_exactly_one_remote_resource() {
        let page = render("$x$\n", &Options::default());
        let katex = document(
            &page,
            &PageOptions {
                math: String::from("katex"),
                ..PageOptions::default()
            },
            0,
        );
        assert!(katex.contains("<script defer src=\"https://cdn.jsdelivr.net/npm/katex@0.16/dist/katex.min.js\"></script>"));
        assert!(katex.contains("katex.min.css"));
        // Whatever happens to that script, the formula is still on the page.
        assert!(katex.contains("$x$"));

        let mine = document(
            &page,
            &PageOptions {
                math: String::from("mathjax"),
                math_url: String::from("http://127.0.0.1:8000/mathjax.js"),
                ..PageOptions::default()
            },
            0,
        );
        assert!(
            mine.contains("<script defer src=\"http://127.0.0.1:8000/mathjax.js\"></script>"),
            "{mine}"
        );
        assert!(!mine.contains("cdn.jsdelivr.net"), "{mine}");
    }

    #[test]
    fn every_syntax_class_the_highlighter_can_emit_has_a_css_name() {
        for class in classes::ALL.iter().filter(|name| name.starts_with("Syn")) {
            assert!(
                syntax_class(class).is_some(),
                "no CSS class for {class}, so it would render unstyled"
            );
        }
    }
}
