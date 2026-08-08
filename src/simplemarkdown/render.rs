//! The block walker: CommonMark events in, rendered rows out.
//!
//! Two ideas carry most of the weight here.
//!
//! *Prefix frames.*  Every nested container — a quote, a list item, a footnote
//! definition — pushes a frame holding the text that must appear at the left of
//! each of its rows, in two variants: the one used on the container's first row
//! (`- `, `▏ `) and the one used on every row after it (`  `, `▏ `).  Emitting
//! a row concatenates the live frames, so `> - a very long item` keeps both the
//! quote bar and the list indent on its wrapped continuation, and no block
//! renderer ever has to know what it is nested inside.
//!
//! *Deferred blank lines.*  Blocks ask for vertical space with [`Renderer::gap`]
//! rather than emitting it, and the blank is materialised by the next row that
//! is actually written.  Consecutive requests collapse, a trailing one is
//! dropped at the end of the document, and — because the blank is built from
//! the prefix in force at flush time, not at request time — the bar of a quote
//! that has just ended does not leak onto the blank line after it.

use crate::classes;
use crate::glyphs::{self, Glyphs};
use crate::highlight;
use crate::inline::{self, HARD_BREAK, Laid, Run, Style, wrap};
use crate::protocol::{BlockSpan, Line, LinkRef, Options, Prop, TocEntry};
use crate::table::{self, Align, Table};
use pulldown_cmark::{
    Alignment, BlockQuoteKind, CodeBlockKind, Event, HeadingLevel, MetadataBlockKind,
    Options as MdOptions, Parser, Tag, TagEnd,
};
use std::collections::HashMap;
use std::ops::Range;
use unicode_width::UnicodeWidthStr;

/// Below this the prefix machinery has eaten the whole window and wrapping
/// would loop; deeply nested content is left to overflow instead.
const MIN_AVAIL: usize = 8;

type Events<'a> = [(Event<'a>, Range<usize>)];

pub struct Output {
    pub lines: Vec<Line>,
    pub toc: Vec<TocEntry>,
    pub links: Vec<LinkRef>,
    pub blocks: Vec<BlockSpan>,
}

pub fn render(source: &str, width: usize, opts: &Options) -> Output {
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

    let events: Vec<(Event, Range<usize>)> =
        Parser::new_ext(source, md).into_offset_iter().collect();

    let text_width = match opts.max_width {
        0 => width,
        cap => width.min(cap),
    }
    .max(MIN_AVAIL);

    let mut renderer = Renderer {
        opts,
        glyphs: glyphs::for_mode(opts.unicode),
        text_width,
        out: Vec::new(),
        toc: Vec::new(),
        links: Vec::new(),
        frames: Vec::new(),
        pending_gap: false,
        line_starts: line_starts(source),
        ambient: None,
        list_depth: 0,
        tight: false,
        footnotes: Vec::new(),
        anchors: HashMap::new(),
    };

    // The top level is walked here rather than through `blocks()` so each
    // block's rendered extent can be recorded as it is produced.  Nested
    // containers are deliberately not indexed: the useful unit for "the block
    // the cursor is in" is the paragraph, the fence, the whole table — not the
    // list item three levels down.
    let mut blocks: Vec<BlockSpan> = Vec::new();
    let mut cursor = 0usize;
    while cursor < events.len() {
        if matches!(events[cursor].0, Event::End(_)) {
            break;
        }
        let range = events[cursor].1.clone();
        let before = renderer.out.len();
        renderer.block(&events, &mut cursor);
        let after = renderer.out.len();

        // A block's first row may be the blank line the *previous* block asked
        // for and this one flushed; it belongs to neither.
        let mut start = before;
        while start < after && renderer.out[start].text.trim().is_empty() {
            start += 1;
        }
        if start < after {
            let src_first = renderer.src_of(range.start);
            let src_last = renderer.src_of(range.end.saturating_sub(1).max(range.start));
            blocks.push(BlockSpan(
                start as u32 + 1,
                (after - start) as u32,
                src_first,
                src_last.max(src_first),
            ));
        }
    }

    Output {
        lines: renderer.out,
        toc: renderer.toc,
        links: renderer.links,
        blocks,
    }
}

/// Byte offset of the start of every source line, for offset → line lookup.
fn line_starts(source: &str) -> Vec<usize> {
    let mut starts = vec![0usize];
    starts.extend(source.match_indices('\n').map(|(index, _)| index + 1));
    starts
}

struct Frame {
    first: String,
    first_props: Vec<(usize, usize, &'static str)>,
    cont: String,
    cont_props: Vec<(usize, usize, &'static str)>,
    used: bool,
    width: usize,
}

struct Renderer<'a> {
    opts: &'a Options,
    glyphs: &'static Glyphs,
    text_width: usize,
    out: Vec<Line>,
    toc: Vec<TocEntry>,
    links: Vec<LinkRef>,
    frames: Vec<Frame>,
    pending_gap: bool,
    line_starts: Vec<usize>,
    /// Class applied to inline text that carries no more specific one, so a
    /// block quote can tint its prose without every inline handler knowing it
    /// is inside one.
    ambient: Option<&'static str>,
    /// Nesting depth of the list being rendered, for picking the bullet glyph.
    /// Counted separately from the prefix frames, which also hold quote bars
    /// and footnote markers.
    list_depth: usize,
    /// Set while rendering the items of a tight list.  CommonMark drops the
    /// paragraph wrapper in a tight list precisely to say "no vertical space
    /// here", so [`Renderer::gap`] honours it and `hard_gap` does not.
    tight: bool,
    /// Footnote labels in first-reference order, so `[^note]` renders as the
    /// same number in the body and at the definition.
    footnotes: Vec<String>,
    /// How many headings have already claimed each slug, so the second `## Notes`
    /// becomes `notes-1` exactly as it does on GitHub.
    anchors: HashMap<String, usize>,
}

// ─────────────────────────── emitting ───────────────────────────

impl Renderer<'_> {
    /// [`slug`] for `text`, suffixed so no two headings in one document share an
    /// anchor.  A repeated heading is common in a changelog or an API reference,
    /// and a link to the second one has to be able to say so.
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

    fn src_of(&self, offset: usize) -> u32 {
        self.line_starts.partition_point(|start| *start <= offset) as u32
    }

    /// The prefix for the next row.  `consume` marks each frame's first-row
    /// variant as spent, so a list marker appears once and its continuations
    /// line up underneath.
    fn prefix(&mut self, consume: bool) -> (String, Vec<Prop>) {
        let mut text = String::new();
        let mut props = Vec::new();
        for frame in &self.frames {
            let base = text.len();
            let (part, part_props) = if frame.used {
                (&frame.cont, &frame.cont_props)
            } else {
                (&frame.first, &frame.first_props)
            };
            text.push_str(part);
            for (offset, len, class) in part_props {
                props.push(Prop(base + offset + 1, *len, class));
            }
        }
        if consume {
            for frame in self.frames.iter_mut() {
                frame.used = true;
            }
        }
        (text, props)
    }

    fn prefix_width(&self) -> usize {
        self.frames.iter().map(|frame| frame.width).sum()
    }

    /// Display columns left for content after the prefix.
    fn avail(&self) -> usize {
        self.text_width
            .saturating_sub(self.prefix_width())
            .max(MIN_AVAIL)
    }

    fn push_frame(
        &mut self,
        first: String,
        first_props: Vec<(usize, usize, &'static str)>,
        cont: String,
        cont_props: Vec<(usize, usize, &'static str)>,
    ) {
        // A blank line requested before this container belongs outside it:
        // flushing here keeps the quote bar off the gap above the quote.
        self.flush_gap();
        // The two variants must occupy the same columns or continuation rows
        // drift left of the text they continue.
        let width = first.width().max(cont.width());
        let mut first = first;
        let mut cont = cont;
        first.push_str(&" ".repeat(width - first.width()));
        cont.push_str(&" ".repeat(width - cont.width()));
        self.frames.push(Frame {
            first,
            first_props,
            cont,
            cont_props,
            used: false,
            width,
        });
    }

    fn pop_frame(&mut self) {
        self.frames.pop();
    }

    /// Ask for a blank line before the next row.  See the module comment.
    /// Suppressed inside a tight list, where the source deliberately has none.
    fn gap(&mut self) {
        if !self.tight {
            self.hard_gap();
        }
    }

    /// A blank line a block needs to be legible at all — around a code box, a
    /// table or a quote — which a tight list does not get to veto.
    fn hard_gap(&mut self) {
        if !self.out.is_empty() {
            self.pending_gap = true;
        }
    }

    fn flush_gap(&mut self) {
        if !self.pending_gap {
            return;
        }
        self.pending_gap = false;
        // Frames keep their unspent first-row variant: a gap must not eat the
        // list marker the next row is about to print.
        let mut text = String::new();
        let mut props = Vec::new();
        for frame in &self.frames {
            let base = text.len();
            text.push_str(&frame.cont);
            for (offset, len, class) in &frame.cont_props {
                props.push(Prop(base + offset + 1, *len, class));
            }
        }
        let trimmed = text.trim_end().len();
        text.truncate(trimmed);
        inline::clamp(&mut props, text.len());
        self.out.push(Line {
            text,
            props,
            src: 0,
        });
    }

    fn emit(
        &mut self,
        body: &str,
        body_props: &[Prop],
        links: &[(usize, usize, String)],
        src: u32,
    ) {
        self.flush_gap();
        let (prefix, mut props) = self.prefix(true);
        let shift = prefix.len();
        let mut text = prefix;
        text.push_str(body);
        for prop in body_props {
            props.push(Prop(prop.0 + shift, prop.1, prop.2));
        }

        // A row that ends in spaces shows a coloured gap wherever a background
        // property reaches the end, and puts `$` past the text in list mode.
        let trimmed = text.trim_end().len();
        text.truncate(trimmed);
        inline::clamp(&mut props, text.len());

        let row = self.out.len() as u32 + 1;
        for (col, len, href) in links {
            let col = col + shift;
            if col <= text.len() {
                self.links.push(LinkRef {
                    row,
                    col,
                    len: (*len).min(text.len() + 1 - col),
                    href: href.clone(),
                });
            }
        }
        self.out.push(Line { text, props, src });
    }

    fn emit_laid(&mut self, laid: &Laid) {
        self.emit(&laid.text, &laid.props, &laid.links, laid.src);
    }

    /// A full-width horizontal line of `glyph`, in `class`.
    fn emit_rule(&mut self, glyph: &str, class: &'static str) {
        let width = self.avail();
        let text = glyph.repeat(width);
        let len = text.len();
        self.emit(&text, &[Prop(1, len, class)], &[], 0);
    }
}

// ─────────────────────────── block walk ───────────────────────────

impl Renderer<'_> {
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
        let src = self.src_of(range.start);
        match event {
            Event::Start(Tag::Paragraph) => {
                *i += 1;
                let runs = self.inline(ev, i, Style::default());
                *i += 1;
                self.paragraph(&runs);
                self.gap();
            }
            Event::Start(Tag::Heading { level, .. }) => {
                let level = heading_level(*level);
                *i += 1;
                let runs = self.inline(ev, i, Style::default());
                *i += 1;
                self.heading(level, &runs, src);
            }
            Event::Start(Tag::BlockQuote(kind)) => {
                let kind = *kind;
                *i += 1;
                self.block_quote(kind, ev, i);
                *i += 1;
            }
            Event::Start(Tag::CodeBlock(kind)) => {
                // An opening fence is a source line of its own, so the code
                // starts one line below the block; an indented block has no
                // marker and starts on the block's own line.  Assuming the
                // fence for both put every row of an indented block one line
                // too far, which is <CR> landing on the next line and scroll
                // sync drifting through the whole block.
                let (info, first) = match kind {
                    CodeBlockKind::Fenced(info) => (info.to_string(), src + 1),
                    CodeBlockKind::Indented => (String::new(), src),
                };
                *i += 1;
                let code = self.raw_text(ev, i);
                *i += 1;
                self.code_block(&info, &code, first);
            }
            Event::Start(Tag::List(start)) => {
                let start = *start;
                *i += 1;
                self.list(start, ev, i);
                *i += 1;
            }
            Event::Start(Tag::Table(aligns)) => {
                let aligns: Vec<Align> = aligns.iter().map(convert_align).collect();
                *i += 1;
                self.table(&aligns, ev, i);
                *i += 1;
            }
            Event::Start(Tag::HtmlBlock) => {
                *i += 1;
                let raw = self.raw_text(ev, i);
                *i += 1;
                self.raw_block(&raw, classes::HTML, src);
            }
            Event::Start(Tag::MetadataBlock(kind)) => {
                let lang = match kind {
                    MetadataBlockKind::YamlStyle => "yaml",
                    MetadataBlockKind::PlusesStyle => "toml",
                };
                *i += 1;
                let raw = self.raw_text(ev, i);
                *i += 1;
                if self.opts.frontmatter {
                    // The `---` or `+++` delimiter is a line of its own.
                    self.code_block(lang, &raw, src + 1);
                }
            }
            Event::Start(Tag::FootnoteDefinition(label)) => {
                let label = label.to_string();
                *i += 1;
                self.footnote_definition(&label, ev, i);
                *i += 1;
            }
            Event::Start(Tag::DefinitionList) => {
                *i += 1;
                self.definition_list(ev, i);
                *i += 1;
                self.hard_gap();
            }
            Event::Rule => {
                *i += 1;
                self.hard_gap();
                self.emit_rule(self.glyphs.rule, classes::RULE);
                self.hard_gap();
            }
            Event::Start(_) => {
                // An inline container opened where a block was expected: fall
                // through to the loose-inline path so nothing is dropped.
                let runs = self.inline(ev, i, Style::default());
                self.paragraph(&runs);
            }
            Event::End(_) => {}
            _ => {
                // Bare inline at block level.  Tight list items arrive this
                // way — CommonMark drops the paragraph wrapper — so this is a
                // normal path, not a fallback.
                let runs = self.inline(ev, i, Style::default());
                self.paragraph(&runs);
            }
        }
    }

    fn paragraph(&mut self, runs: &[Run]) {
        if runs.iter().all(|run| run.text.trim().is_empty()) {
            return;
        }
        let avail = if self.opts.wrap { self.avail() } else { 0 };
        for row in wrap(runs, avail) {
            self.emit_laid(&row);
        }
    }

    fn heading(&mut self, level: u8, runs: &[Run], src: u32) {
        self.hard_gap();
        let class = classes::heading(level);
        let mark = self.glyphs.head_marks[(level - 1) as usize];
        let marker = format!("{mark} ");
        let mark_len = mark.len();
        self.push_frame(
            marker.clone(),
            vec![(0, mark_len, classes::HEAD_MARK)],
            " ".repeat(marker.width()),
            Vec::new(),
        );

        let styled: Vec<Run> = runs
            .iter()
            .map(|run| Run {
                style: Style {
                    base: Some(class),
                    ..run.style
                },
                ..run.clone()
            })
            .collect();
        let avail = if self.opts.wrap { self.avail() } else { 0 };
        let rows = wrap(&styled, avail);
        let row_number = self.out.len() as u32 + 1 + u32::from(self.pending_gap);
        for row in &rows {
            self.emit_laid(row);
        }
        self.pop_frame();

        let text = plain(runs);
        let anchor = self.unique_anchor(&text);
        self.toc.push(TocEntry {
            level,
            text,
            anchor,
            src,
            row: row_number,
        });

        // Only the top two levels get a rule; below that the page turns into
        // more lines than content.
        if level <= 2 {
            let glyph = if level == 1 {
                self.glyphs.head_rule_heavy
            } else {
                self.glyphs.head_rule_light
            };
            self.emit_rule(glyph, classes::HEAD_RULE);
        }
        self.hard_gap();
    }

    fn block_quote(&mut self, kind: Option<BlockQuoteKind>, ev: &Events, i: &mut usize) {
        self.hard_gap();
        let bar = self.glyphs.quote_bar;
        let class = alert_class(kind);
        let prefix = format!("{bar} ");
        self.push_frame(
            prefix.clone(),
            vec![(0, bar.len(), class)],
            prefix,
            vec![(0, bar.len(), class)],
        );

        if let Some(kind) = kind {
            let (glyph, title) = alert_title(self.glyphs, kind);
            let text = format!("{glyph} {title}");
            let len = text.len();
            self.emit(&text, &[Prop(1, len, class)], &[], 0);
        }

        let ambient = self.ambient.replace(classes::QUOTE);
        let tight = std::mem::replace(&mut self.tight, false);
        self.blocks(ev, i);
        self.ambient = ambient;
        self.tight = tight;
        // A quote's own trailing gap belongs outside its bar.
        self.pending_gap = false;
        self.pop_frame();
        self.hard_gap();
    }

    fn list(&mut self, start: Option<u64>, ev: &Events, i: &mut usize) {
        self.gap();
        let depth = self.list_depth;
        let loose = is_loose(ev, *i);
        let mut number = start.unwrap_or(1);
        // Right-align ordered markers to the widest one so `9.` and `10.` put
        // their text in the same column.
        let marker_width = start
            .map(|first| {
                let last = first + count_items(ev, *i) as u64;
                format!("{last}.").len() + 1
            })
            .unwrap_or(0);

        let mut tasks = 0usize;
        let mut done = 0usize;

        while *i < ev.len() {
            match &ev[*i].0 {
                Event::Start(Tag::Item) => {
                    *i += 1;
                    let task = match ev.get(*i).map(|(event, _)| event) {
                        Some(Event::TaskListMarker(done)) => {
                            *i += 1;
                            Some(*done)
                        }
                        _ => None,
                    };
                    if let Some(checked) = task {
                        tasks += 1;
                        done += usize::from(checked);
                    }
                    let (marker, marker_props) =
                        self.item_marker(task, start, number, marker_width, depth);
                    let indent = " ".repeat(marker.width());
                    self.push_frame(marker, marker_props, indent, Vec::new());

                    let tight = std::mem::replace(&mut self.tight, !loose);
                    self.list_depth = depth + 1;
                    self.blocks(ev, i);
                    self.list_depth = depth;
                    self.tight = tight;

                    // Whatever the item asked for at its end applies between
                    // items, but must not be charged to this item's indent.
                    self.pending_gap = false;
                    self.pop_frame();
                    if loose {
                        self.gap();
                    }
                    *i += 1;
                    number += 1;
                }
                Event::End(_) => break,
                // Stray content between items; render it rather than lose it.
                _ => self.block(ev, i),
            }
        }
        self.task_progress(tasks, done);
        self.gap();
    }

    /// Close a task list with how much of it is done.
    ///
    /// Only for lists of two or more checkboxes: a single `- [ ]` needs no
    /// summary, and a list with none is not a task list at all.  The line sits
    /// at the list's own indent, so a nested checklist summarises itself where
    /// it belongs rather than at the left margin.
    fn task_progress(&mut self, tasks: usize, done: usize) {
        if !self.opts.task_progress || tasks < 2 {
            return;
        }
        let glyph = if done == tasks {
            self.glyphs.task_done
        } else {
            self.glyphs.task_todo
        };
        let class = if done == tasks {
            classes::TASK_DONE
        } else {
            classes::TASK
        };
        let label = format!(" {done}/{tasks} done");
        let mut text = String::from(glyph);
        let props = vec![
            Prop(1, glyph.len(), class),
            Prop(glyph.len() + 1, label.len(), classes::TASK),
        ];
        text.push_str(&label);
        self.emit(&text, &props, &[], 0);
    }

    fn item_marker(
        &self,
        task: Option<bool>,
        ordered: Option<u64>,
        number: u64,
        marker_width: usize,
        depth: usize,
    ) -> (String, Vec<(usize, usize, &'static str)>) {
        if let Some(done) = task {
            let glyph = if done {
                self.glyphs.task_done
            } else {
                self.glyphs.task_todo
            };
            let class = if done {
                classes::TASK_DONE
            } else {
                classes::TASK
            };
            return (format!("{glyph} "), vec![(0, glyph.len(), class)]);
        }
        match ordered {
            Some(_) => {
                let label = format!("{number}.");
                let pad = marker_width.saturating_sub(label.width() + 1);
                let text = format!("{}{label} ", " ".repeat(pad));
                (text, vec![(pad, label.len(), classes::NUMBER)])
            }
            None => {
                let glyph = self.glyphs.bullets[depth % self.glyphs.bullets.len()];
                (format!("{glyph} "), vec![(0, glyph.len(), classes::BULLET)])
            }
        }
    }

    fn table(&mut self, aligns: &[Align], ev: &Events, i: &mut usize) {
        self.hard_gap();
        let mut header: Vec<Vec<Run>> = Vec::new();
        let mut rows: Vec<Vec<Vec<Run>>> = Vec::new();

        while *i < ev.len() {
            match &ev[*i].0 {
                Event::Start(Tag::TableHead) => {
                    *i += 1;
                    header = self.table_cells(ev, i);
                    *i += 1;
                }
                Event::Start(Tag::TableRow) => {
                    *i += 1;
                    rows.push(self.table_cells(ev, i));
                    *i += 1;
                }
                Event::End(_) => break,
                _ => *i += 1,
            }
        }

        let laid = table::layout(
            &Table {
                header,
                rows,
                aligns: aligns.to_vec(),
            },
            self.avail(),
            self.glyphs,
            self.opts.table_zebra,
        );
        for row in laid {
            self.emit(&row.text, &row.props, &row.links, row.src);
        }
        self.hard_gap();
    }

    fn table_cells(&mut self, ev: &Events, i: &mut usize) -> Vec<Vec<Run>> {
        let mut cells = Vec::new();
        while *i < ev.len() {
            match &ev[*i].0 {
                Event::Start(Tag::TableCell) => {
                    *i += 1;
                    cells.push(self.inline(ev, i, Style::default()));
                    *i += 1;
                }
                Event::End(_) => break,
                _ => *i += 1,
            }
        }
        cells
    }

    fn footnote_definition(&mut self, label: &str, ev: &Events, i: &mut usize) {
        self.hard_gap();
        let marker = format!("[{}] ", self.footnote_number(label));
        let len = marker.trim_end().len();
        self.push_frame(
            marker.clone(),
            vec![(0, len, classes::FOOTNOTE)],
            " ".repeat(marker.width()),
            Vec::new(),
        );
        self.blocks(ev, i);
        self.pending_gap = false;
        self.pop_frame();
        self.hard_gap();
    }

    fn definition_list(&mut self, ev: &Events, i: &mut usize) {
        while *i < ev.len() {
            match &ev[*i].0 {
                Event::Start(Tag::DefinitionListTitle) => {
                    *i += 1;
                    self.gap();
                    let runs = self.inline(
                        ev,
                        i,
                        Style {
                            base: Some(classes::TERM),
                            ..Default::default()
                        },
                    );
                    *i += 1;
                    self.paragraph(&runs);
                }
                Event::Start(Tag::DefinitionListDefinition) => {
                    *i += 1;
                    self.push_frame("    ".into(), Vec::new(), "    ".into(), Vec::new());
                    self.blocks(ev, i);
                    self.pending_gap = false;
                    self.pop_frame();
                    *i += 1;
                }
                Event::End(_) => break,
                _ => *i += 1,
            }
        }
    }

    /// Raw text with no inline parsing: code block bodies, HTML blocks.
    fn raw_text(&mut self, ev: &Events, i: &mut usize) -> String {
        let mut out = String::new();
        while *i < ev.len() {
            match &ev[*i].0 {
                Event::Text(text)
                | Event::Html(text)
                | Event::InlineHtml(text)
                | Event::Code(text) => {
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

    fn raw_block(&mut self, raw: &str, class: &'static str, src: u32) {
        self.hard_gap();
        for (offset, line) in raw.lines().enumerate() {
            let text = expand_tabs(line, self.opts.tab_width);
            // Raw HTML has no word structure worth respecting, but it must
            // still not run past the window: split it by display width.
            let avail = self.avail();
            for chunk in split_by_width(&text, avail, avail) {
                let body = &text[chunk];
                self.emit(
                    body,
                    &[Prop(1, body.len(), class)],
                    &[],
                    src + offset as u32,
                );
            }
        }
        self.hard_gap();
    }
}

// ─────────────────────────── code blocks ───────────────────────────

impl Renderer<'_> {
    /// `first_src` is the source line the code's first line is on — not the
    /// block's, which for a fenced block is the opening fence.
    fn code_block(&mut self, info: &str, code: &str, first_src: u32) {
        self.gap();
        let glyphs = self.glyphs;
        let avail = self.avail();
        // `│ ` + content + ` │`
        let inner = avail.saturating_sub(4).max(4);

        self.emit_code_border(info, inner, true);

        // Expanded up front, because the block cache is keyed on exactly the
        // text that gets laid out.
        let lines: Vec<String> = code
            .lines()
            .map(|raw| expand_tabs(raw, self.opts.tab_width))
            .collect();
        let highlighted = if self.opts.syntax {
            highlight::block(info, &lines)
        } else {
            std::sync::Arc::new(Vec::new())
        };

        // The line-number gutter, when asked for: as many columns as the
        // highest number needs, plus a space.  It comes out of the content, so
        // a narrow window buys the numbers with wrapped code — which is the
        // right way round, and why this is off by default.
        let digits = if self.opts.code_numbers && !lines.is_empty() {
            lines.len().to_string().len()
        } else {
            0
        };
        let gutter = if digits > 0 { digits + 1 } else { 0 };
        let body_width = inner.saturating_sub(gutter).max(4);

        for (offset, line) in lines.iter().enumerate() {
            let empty: &[(usize, usize, &'static str)] = &[];
            let spans = highlighted.get(offset).map_or(empty, Vec::as_slice);
            let source_line = first_src + offset as u32;

            let chunks = if self.opts.code_wrap {
                split_by_width(line, body_width, body_width.saturating_sub(2).max(1))
            } else {
                vec![clip(line, body_width, glyphs.code_clip)]
            };

            for (index, chunk) in chunks.iter().enumerate() {
                let continued = index > 0;
                let mut text = String::from(glyphs.box_v);
                let mut props = vec![Prop(1, glyphs.box_v.len(), classes::CODE_BORDER)];
                text.push(' ');
                // Everything from here to the closing border is the block's
                // inner span, painted as one background at the end.
                let inner_start = text.len();

                if digits > 0 {
                    let col = text.len() + 1;
                    // A wrapped row belongs to the line above it and gets a
                    // blank gutter, the way an editor's own numbers behave.
                    let label = if continued {
                        " ".repeat(digits)
                    } else {
                        format!("{:>digits$}", offset + 1)
                    };
                    text.push_str(&label);
                    if !continued {
                        props.push(Prop(col, label.len(), classes::CODE_NUMBER));
                    }
                    text.push(' ');
                }

                if continued {
                    let col = text.len() + 1;
                    text.push_str(glyphs.code_cont);
                    props.push(Prop(col, glyphs.code_cont.len(), classes::CODE_CONT));
                    text.push(' ');
                }

                let base = text.len();
                let body = &line[chunk.clone()];
                text.push_str(body);
                let used = body.width() + gutter + if continued { 2 } else { 0 };
                text.push_str(&" ".repeat(inner.saturating_sub(used)));

                for (offset, len, class) in intersect(spans, chunk) {
                    props.push(Prop(base + offset + 1, len, class));
                }

                let col = text.len() + 1;
                text.push(' ');
                text.push_str(glyphs.box_v);
                props.push(Prop(col + 1, glyphs.box_v.len(), classes::CODE_BORDER));

                // One property behind the whole inner span paints the block
                // background; the number and syntax spans sit on top of it.
                props.push(Prop(
                    inner_start + 1,
                    col - 1 - inner_start,
                    classes::CODE_BLOCK,
                ));

                // The padding is real: without it the background stops at the
                // text and the box looks ragged.  Emit bypasses the usual
                // trailing-space trim by keeping the closing border last.
                self.emit(&text, &props, &[], source_line);
            }
        }

        self.emit_code_border("", inner, false);
        self.gap();
    }

    /// `╭─ rust ─────╮` on top, `╰────────────╯` at the bottom.
    fn emit_code_border(&mut self, info: &str, inner: usize, top: bool) {
        let glyphs = self.glyphs;
        let (left, right) = if top {
            (glyphs.box_tl, glyphs.box_tr)
        } else {
            (glyphs.box_bl, glyphs.box_br)
        };
        let label = info
            .split(|c: char| c.is_whitespace() || c == ',' || c == '{')
            .find(|part| !part.is_empty())
            .unwrap_or("");

        let mut text = String::from(left);
        let mut props = vec![Prop(1, left.len(), classes::CODE_BORDER)];
        let span = inner + 2;

        if top && !label.is_empty() && label.width() + 4 <= span {
            text.push_str(glyphs.box_h);
            text.push(' ');
            let col = text.len() + 1;
            text.push_str(label);
            props.push(Prop(col, label.len(), classes::CODE_LANG));
            text.push(' ');
            let fill = span - (2 + label.width() + 1);
            let col = text.len() + 1;
            text.push_str(&glyphs.box_h.repeat(fill));
            props.push(Prop(col, glyphs.box_h.len() * fill, classes::CODE_BORDER));
        } else {
            let col = text.len() + 1;
            text.push_str(&glyphs.box_h.repeat(span));
            props.push(Prop(col, glyphs.box_h.len() * span, classes::CODE_BORDER));
        }

        let col = text.len() + 1;
        text.push_str(right);
        props.push(Prop(col, right.len(), classes::CODE_BORDER));
        self.emit(&text, &props, &[], 0);
    }
}

// ─────────────────────────── inline walk ───────────────────────────

impl Renderer<'_> {
    /// Collect inline events into styled runs, stopping at (but not consuming)
    /// the `End` that closes the enclosing element.
    fn inline(&mut self, ev: &Events, i: &mut usize, style: Style) -> Vec<Run> {
        let style = Style {
            base: style.base.or(self.ambient),
            ..style
        };
        let mut runs: Vec<Run> = Vec::new();
        while *i < ev.len() {
            let (event, range) = &ev[*i];
            let src = self.src_of(range.start);
            match event {
                Event::End(_) => return runs,
                Event::Text(text) => {
                    runs.push(Run::new(text.to_string(), style, src));
                    *i += 1;
                }
                Event::Code(text) => {
                    runs.push(Run::new(
                        text.to_string(),
                        Style {
                            code: true,
                            ..style
                        },
                        src,
                    ));
                    *i += 1;
                }
                Event::InlineMath(text) => {
                    runs.push(Run::new(
                        format!("${text}$"),
                        Style {
                            code: true,
                            ..style
                        },
                        src,
                    ));
                    *i += 1;
                }
                Event::DisplayMath(text) => {
                    runs.push(Run::new(
                        format!("$${text}$$"),
                        Style {
                            code: true,
                            ..style
                        },
                        src,
                    ));
                    *i += 1;
                }
                Event::Html(text) | Event::InlineHtml(text) => {
                    runs.push(Run::new(
                        text.trim_end_matches('\n').to_string(),
                        Style {
                            base: Some(classes::HTML),
                            ..style
                        },
                        src,
                    ));
                    *i += 1;
                }
                Event::SoftBreak => {
                    runs.push(Run::new(" ", style, src));
                    *i += 1;
                }
                Event::HardBreak => {
                    runs.push(Run::new(HARD_BREAK.to_string(), style, src));
                    *i += 1;
                }
                Event::FootnoteReference(label) => {
                    let label = label.to_string();
                    let number = self.footnote_number(&label);
                    runs.push(Run::new(
                        format!("[{number}]"),
                        Style {
                            base: Some(classes::FOOTNOTE),
                            ..style
                        },
                        src,
                    ));
                    *i += 1;
                }
                Event::TaskListMarker(_) => *i += 1,
                Event::Rule => *i += 1,
                Event::Start(tag) => {
                    let nested = match tag {
                        Tag::Emphasis => Style {
                            italic: true,
                            ..style
                        },
                        Tag::Strong => Style {
                            bold: true,
                            ..style
                        },
                        Tag::Strikethrough => Style {
                            strike: true,
                            ..style
                        },
                        Tag::Link { .. } => Style {
                            link: true,
                            ..style
                        },
                        Tag::Image { .. } => Style {
                            image: true,
                            ..style
                        },
                        _ => style,
                    };
                    let target = match tag {
                        Tag::Link { dest_url, .. } | Tag::Image { dest_url, .. } => {
                            Some(dest_url.to_string())
                        }
                        _ => None,
                    };
                    let is_image = matches!(tag, Tag::Image { .. });
                    let closes = matches!(
                        tag,
                        Tag::Emphasis
                            | Tag::Strong
                            | Tag::Strikethrough
                            | Tag::Link { .. }
                            | Tag::Image { .. }
                            | Tag::Superscript
                            | Tag::Subscript
                    );
                    if !closes {
                        // A block tag inside an inline run: stop and let the
                        // block walker deal with it.
                        return runs;
                    }
                    if is_image {
                        runs.push(Run::new(
                            format!("{} ", self.glyphs.image),
                            Style {
                                base: Some(classes::IMAGE),
                                ..style
                            },
                            src,
                        ));
                    }
                    *i += 1;
                    let mut inner = self.inline(ev, i, nested);
                    *i += 1;

                    if let Some(href) = target.as_ref() {
                        // An empty link text (`<https://x>` renders its own URL,
                        // but `[](x)` does not) still needs something visible.
                        if inner.iter().all(|run| run.text.trim().is_empty()) {
                            inner = vec![Run::new(href.clone(), nested, src)];
                        }
                        for run in inner.iter_mut() {
                            run.href = Some(href.clone());
                        }
                    }
                    runs.extend(inner);

                    // Images get their source shown too: `![](diagram.png)` in
                    // a terminal preview is a name and nothing else, and the
                    // name is the only thing that tells you which file it is.
                    if let Some(href) = target
                        && self.opts.show_urls
                        && !href.is_empty()
                    {
                        runs.push(Run::new(
                            format!(" ({href})"),
                            Style {
                                base: Some(classes::LINK_URL),
                                ..style
                            },
                            src,
                        ));
                    }
                }
            }
        }
        runs
    }

    fn footnote_number(&mut self, label: &str) -> usize {
        match self.footnotes.iter().position(|seen| seen == label) {
            Some(index) => index + 1,
            None => {
                self.footnotes.push(label.to_string());
                self.footnotes.len()
            }
        }
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

fn convert_align(align: &Alignment) -> Align {
    match align {
        Alignment::Right => Align::Right,
        Alignment::Center => Align::Center,
        _ => Align::Left,
    }
}

fn alert_class(kind: Option<BlockQuoteKind>) -> &'static str {
    match kind {
        None => classes::QUOTE_BAR,
        Some(BlockQuoteKind::Note) => classes::ALERT_NOTE,
        Some(BlockQuoteKind::Tip) => classes::ALERT_TIP,
        Some(BlockQuoteKind::Important) => classes::ALERT_IMPORTANT,
        Some(BlockQuoteKind::Warning) => classes::ALERT_WARNING,
        Some(BlockQuoteKind::Caution) => classes::ALERT_CAUTION,
    }
}

fn alert_title(glyphs: &Glyphs, kind: BlockQuoteKind) -> (&'static str, &'static str) {
    let word = match kind {
        BlockQuoteKind::Note => "NOTE",
        BlockQuoteKind::Tip => "TIP",
        BlockQuoteKind::Important => "IMPORTANT",
        BlockQuoteKind::Warning => "WARNING",
        BlockQuoteKind::Caution => "CAUTION",
    };
    (glyphs.alert, word)
}

/// Whether a list is loose, i.e. whether its items are separated by blank
/// lines.  CommonMark encodes that by wrapping a loose item's content in a
/// paragraph and a tight item's in nothing at all, so the wrapper is the only
/// signal available — and it is the signal that decides whether the rendered
/// list gets blank rows between its items.
fn is_loose(ev: &Events, from: usize) -> bool {
    let mut depth = 0i32;
    for (event, _) in ev.iter().skip(from) {
        match event {
            Event::Start(Tag::Item) => depth += 1,
            Event::Start(Tag::Paragraph) if depth == 1 => return true,
            Event::Start(_) => depth += 1,
            Event::End(TagEnd::Item) => depth -= 1,
            Event::End(TagEnd::List(_)) if depth == 0 => break,
            Event::End(_) => depth -= 1,
            _ => {}
        }
    }
    false
}

/// How many items a list has, counted without consuming the cursor.
fn count_items(ev: &Events, from: usize) -> usize {
    let mut depth = 0i32;
    let mut items = 0usize;
    for (event, _) in ev.iter().skip(from) {
        match event {
            Event::Start(Tag::Item) => {
                if depth == 0 {
                    items += 1;
                }
                depth += 1;
            }
            Event::Start(_) => depth += 1,
            Event::End(TagEnd::Item) => depth -= 1,
            Event::End(TagEnd::List(_)) if depth == 0 => break,
            Event::End(_) => depth -= 1,
            _ => {}
        }
    }
    items
}

/// GitHub's heading anchor: lower-case the text, drop everything that is not
/// alphanumeric, `_` or `-`, and turn each remaining space into a `-`.  Spaces
/// are not collapsed — `## A & B` is `#a--b` on GitHub, because the `&` is
/// removed after the spaces around it have already become dashes.
///
/// The dialects differ (GitLab strips consecutive dashes, pandoc drops leading
/// digits); GitHub's is the one a Markdown file in a repository is written
/// against, and doc/simplemarkdown.txt says so.  A link that matches no slug
/// still falls back to a fuzzy text match on the Vim side, so picking one
/// dialect costs nothing that worked before.
pub fn slug(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.trim().chars() {
        if ch.is_alphanumeric() || ch == '_' || ch == '-' {
            out.extend(ch.to_lowercase());
        } else if ch.is_whitespace() {
            out.push('-');
        }
    }
    out
}

fn plain(runs: &[Run]) -> String {
    let mut out = String::new();
    for run in runs {
        out.push_str(&run.text.replace(HARD_BREAK, " "));
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Expand tabs to the next multiple of `width`, counting display columns so a
/// tab after a CJK character still lands on the right stop.
fn expand_tabs(line: &str, width: usize) -> String {
    if !line.contains('\t') {
        return line.to_string();
    }
    let width = width.max(1);
    let mut out = String::with_capacity(line.len());
    let mut column = 0usize;
    for ch in line.chars() {
        if ch == '\t' {
            let stop = width - (column % width);
            out.push_str(&" ".repeat(stop));
            column += stop;
        } else {
            out.push(ch);
            column += unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
        }
    }
    out
}

/// Split `line` into byte ranges no wider than `first` display columns, then
/// `rest` columns for every chunk after the first.
fn split_by_width(line: &str, first: usize, rest: usize) -> Vec<Range<usize>> {
    // An empty line needs no special case: the loop body never runs and the
    // trailing push yields the single empty chunk a blank code row wants.
    let mut chunks = Vec::new();
    let mut start = 0usize;
    let mut width = 0usize;
    let mut budget = first.max(1);
    for (offset, ch) in line.char_indices() {
        let cw = unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
        if width + cw > budget && offset > start {
            chunks.push(start..offset);
            start = offset;
            width = 0;
            budget = rest.max(1);
        }
        width += cw;
    }
    chunks.push(start..line.len());
    chunks
}

/// Truncate to `width` columns, marking the cut with `marker`.
fn clip(line: &str, width: usize, marker: &str) -> Range<usize> {
    if line.width() <= width {
        return 0..line.len();
    }
    let limit = width.saturating_sub(marker.width()).max(1);
    let mut used = 0usize;
    for (offset, ch) in line.char_indices() {
        let cw = unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
        if used + cw > limit {
            return 0..offset;
        }
        used += cw;
    }
    0..line.len()
}

/// Clip highlight spans to a chunk and rebase them onto it.
fn intersect(
    spans: &[(usize, usize, &'static str)],
    chunk: &Range<usize>,
) -> Vec<(usize, usize, &'static str)> {
    spans
        .iter()
        .filter_map(|(offset, len, class)| {
            let start = (*offset).max(chunk.start);
            let end = (offset + len).min(chunk.end);
            (start < end).then(|| (start - chunk.start, end - start, *class))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render_text(source: &str, width: usize) -> Vec<String> {
        let out = render(source, width, &Options::default());
        out.lines.into_iter().map(|line| line.text).collect()
    }

    fn checked(source: &str, width: usize) -> Output {
        let out = render(source, width, &Options::default());
        for (index, line) in out.lines.iter().enumerate() {
            assert!(!line.text.contains('\n'), "row {index} contains a newline");
            assert!(!line.text.contains('\t'), "row {index} contains a tab");
            for prop in &line.props {
                assert!(
                    prop.0 >= 1,
                    "row {index}: property column {} is not 1-based",
                    prop.0
                );
                assert!(
                    prop.0 + prop.1 - 1 <= line.text.len(),
                    "row {index}: property {prop:?} escapes {:?}",
                    line.text
                );
                assert!(
                    classes::ALL.contains(&prop.2),
                    "row {index}: unregistered class {:?}",
                    prop.2
                );
                assert!(
                    line.text.is_char_boundary(prop.0 - 1),
                    "row {index}: property {prop:?} starts mid-character"
                );
                assert!(
                    line.text.is_char_boundary(prop.0 - 1 + prop.1),
                    "row {index}: property {prop:?} ends mid-character"
                );
            }
        }
        for link in &out.links {
            let line = &out.lines[link.row as usize - 1];
            assert!(
                link.col + link.len - 1 <= line.text.len(),
                "link {link:?} escapes its row"
            );
        }
        out
    }

    #[test]
    fn heading_gets_a_marker_and_a_rule() {
        let rows = render_text("# Title\n", 40);
        assert_eq!(rows[0], "▌ Title");
        assert_eq!(rows[1], "━".repeat(40));
    }

    #[test]
    fn paragraph_wraps_to_the_window() {
        let rows = render_text("alpha beta gamma delta epsilon zeta\n", 20);
        assert!(rows.iter().all(|row| row.width() <= 20), "{rows:?}");
        assert!(rows.len() > 1);
    }

    #[test]
    fn nested_list_keeps_both_indents() {
        let rows = render_text("- outer\n  - inner\n", 40);
        assert_eq!(rows[0], "• outer");
        assert_eq!(rows[1], "  ◦ inner");
    }

    #[test]
    fn wrapped_list_item_aligns_under_its_text() {
        let rows = render_text("- alpha beta gamma delta\n", 14);
        assert_eq!(rows[0], "• alpha beta");
        assert_eq!(rows[1], "  gamma delta");
    }

    #[test]
    fn quote_bar_repeats_on_every_row_including_blanks() {
        let rows = render_text("> one\n>\n> two\n", 40);
        assert_eq!(rows, vec!["▏ one", "▏", "▏ two"]);
    }

    #[test]
    fn a_quote_inside_a_list_keeps_both_prefixes() {
        let rows = render_text("- item\n\n  > quoted\n", 40);
        assert!(
            rows.iter().any(|row| row.starts_with("  ▏ quoted")),
            "{rows:?}"
        );
    }

    #[test]
    fn ordered_markers_right_align() {
        let source: String = (1..=10).map(|n| format!("{n}. item\n")).collect();
        let rows = render_text(&source, 40);
        assert_eq!(rows[0], " 1. item");
        assert_eq!(rows[9], "10. item");
    }

    #[test]
    fn task_list_markers_render() {
        let rows = render_text("- [ ] todo\n- [x] done\n", 40);
        assert_eq!(rows, vec!["☐ todo", "☑ done", "☐ 1/2 done"]);
    }

    #[test]
    fn a_finished_task_list_says_so_with_the_done_glyph() {
        let rows = render_text("- [x] one\n- [x] two\n", 40);
        assert_eq!(rows.last().map(String::as_str), Some("☑ 2/2 done"));
    }

    #[test]
    fn a_single_checkbox_gets_no_summary() {
        // One item needs no arithmetic, and a summary under it is noise.
        let rows = render_text("- [ ] lonely\n", 40);
        assert_eq!(rows, vec!["☐ lonely"]);
    }

    #[test]
    fn a_plain_list_gets_no_summary() {
        let rows = render_text("- one\n- two\n", 40);
        assert_eq!(rows, vec!["• one", "• two"]);
    }

    #[test]
    fn task_progress_can_be_turned_off() {
        let opts = Options {
            task_progress: false,
            ..Options::default()
        };
        let rows: Vec<String> = render("- [ ] a\n- [x] b\n", 40, &opts)
            .lines
            .into_iter()
            .map(|line| line.text)
            .collect();
        assert_eq!(rows, vec!["☐ a", "☑ b"]);
    }

    #[test]
    fn code_line_numbers_are_gutter_aligned_and_shrink_the_body() {
        let source = "```text\nalpha\nbeta\n```\n";
        let plain = render_text(source, 30);
        let opts = Options {
            code_numbers: true,
            ..Options::default()
        };
        let numbered: Vec<String> = render(source, 30, &opts)
            .lines
            .into_iter()
            .map(|line| line.text)
            .collect();

        assert!(numbered[1].starts_with("│ 1 alpha"), "{:?}", numbered[1]);
        assert!(numbered[2].starts_with("│ 2 beta"), "{:?}", numbered[2]);
        // The box is the same width either way: the gutter comes out of the
        // content, it is not added to the outside.
        assert_eq!(
            plain.iter().map(|row| row.width()).max(),
            numbered.iter().map(|row| row.width()).max()
        );
    }

    #[test]
    fn code_line_numbers_are_right_aligned_across_a_widening_count() {
        // Nine lines and then a tenth: the gutter must widen for all of them,
        // not just the ones that need two digits.
        let mut source = String::from("```text\n");
        for index in 1..=10 {
            source.push_str(&format!("line {index}\n"));
        }
        source.push_str("```\n");
        let opts = Options {
            code_numbers: true,
            ..Options::default()
        };
        let rows: Vec<String> = render(&source, 40, &opts)
            .lines
            .into_iter()
            .map(|line| line.text)
            .collect();
        assert!(rows[1].starts_with("│  1 line 1"), "{:?}", rows[1]);
        assert!(rows[10].starts_with("│ 10 line 10"), "{:?}", rows[10]);
    }

    #[test]
    fn zebra_stripes_every_other_body_row_and_nothing_else() {
        let source = "| a |\n|---|\n| 1 |\n| 2 |\n| 3 |\n";
        let opts = Options {
            table_zebra: true,
            ..Options::default()
        };
        let striped: Vec<bool> = render(source, 40, &opts)
            .lines
            .iter()
            .map(|line| {
                line.props
                    .iter()
                    .any(|prop| prop.2 == classes::TABLE_ROW_ALT)
            })
            .collect();
        // ┌─┐ head ├─┤ 1 2 3 └─┘ — only the second body row is tinted.
        assert_eq!(
            striped,
            vec![false, false, false, false, true, false, false]
        );

        // And nothing is striped when the option is off.
        let plain = render(source, 40, &Options::default());
        assert!(
            !plain
                .lines
                .iter()
                .flat_map(|line| &line.props)
                .any(|prop| prop.2 == classes::TABLE_ROW_ALT)
        );
    }

    #[test]
    fn show_urls_covers_images_as_well_as_links() {
        let opts = Options {
            show_urls: true,
            ..Options::default()
        };
        let rows: Vec<String> = render("![a diagram](./diagram.png)\n", 60, &opts)
            .lines
            .into_iter()
            .map(|line| line.text)
            .collect();
        assert!(
            rows[0].contains("./diagram.png"),
            "an image should show its source: {rows:?}"
        );
    }

    #[test]
    fn code_block_is_boxed_and_labelled() {
        let rows = render_text("```rust\nfn main() {}\n```\n", 30);
        assert!(rows[0].starts_with("╭─ rust ─"), "{:?}", rows[0]);
        assert!(rows[1].starts_with("│ fn main() {}"));
        assert!(rows[2].starts_with("╰─"));
        assert!(rows.iter().all(|row| row.width() == 30), "{rows:?}");
    }

    #[test]
    fn long_code_lines_wrap_with_a_continuation_marker() {
        let source = format!("```\n{}\n```\n", "x".repeat(60));
        let rows = render_text(&source, 30);
        assert!(rows[2].contains('⤷'), "{:?}", rows[2]);
        let recovered: String = rows[1..rows.len() - 1]
            .iter()
            .map(|row| {
                row.trim_start_matches("│ ")
                    .trim_start_matches("⤷ ")
                    .trim_end_matches('│')
                    .trim()
            })
            .collect();
        assert_eq!(recovered, "x".repeat(60));
    }

    #[test]
    fn code_is_syntax_highlighted() {
        let out = render("```rust\nfn main() {}\n```\n", 40, &Options::default());
        assert!(
            out.lines[1]
                .props
                .iter()
                .any(|prop| prop.2 == classes::SYN_KEYWORD),
            "{:?}",
            out.lines[1].props
        );
    }

    #[test]
    fn table_columns_line_up() {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |\n";
        let rows = render_text(source, 40);
        let widths: Vec<usize> = rows
            .iter()
            .filter(|row| !row.is_empty())
            .map(|row| row.width())
            .collect();
        assert!(
            widths.windows(2).all(|pair| pair[0] == pair[1]),
            "{widths:?}"
        );
    }

    #[test]
    fn source_lines_are_tracked() {
        let out = render("# One\n\npara\n\n## Two\n", 40, &Options::default());
        assert_eq!(out.toc.len(), 2);
        assert_eq!(out.toc[0].src, 1);
        assert_eq!(out.toc[1].src, 5);
        assert_eq!(out.lines[out.toc[1].row as usize - 1].text, "▌ Two");
    }

    /// The source line each row says it came from, paired with its text.
    fn sources(out: &Output) -> Vec<(&str, u32)> {
        out.lines
            .iter()
            .map(|line| (line.text.as_str(), line.src))
            .collect()
    }

    fn source_of(rows: &[(&str, u32)], needle: &str) -> u32 {
        rows.iter()
            .find(|(text, _)| text.contains(needle))
            .unwrap_or_else(|| panic!("no row containing {needle:?} in {rows:?}"))
            .1
    }

    #[test]
    fn code_rows_map_to_the_lines_they_came_from() {
        // A fenced block starts one line below its opening fence; an indented
        // block has no marker at all and starts on its own line.  Treating both
        // as fenced put every row of an indented block one line too far, so
        // <CR> on it jumped to the line below and scroll sync drifted through
        // the whole block.
        let fenced = render(
            "para\n\n```rust\nfn one() {}\nfn two() {}\n```\n\ntail\n",
            40,
            &Options::default(),
        );
        let rows = sources(&fenced);
        assert_eq!(source_of(&rows, "fn one"), 4);
        assert_eq!(source_of(&rows, "fn two"), 5);

        let indented = render(
            "para\n\n    indented one\n    indented two\n\ntail\n",
            40,
            &Options::default(),
        );
        let rows = sources(&indented);
        assert_eq!(source_of(&rows, "indented one"), 3);
        assert_eq!(source_of(&rows, "indented two"), 4);
        assert_eq!(source_of(&rows, "tail"), 6);
    }

    #[test]
    fn headings_carry_a_github_anchor() {
        let out = render(
            "# Getting *started*\n\n## Notes: part one!\n\n## A & B\n",
            60,
            &Options::default(),
        );
        let anchors: Vec<&str> = out.toc.iter().map(|entry| entry.anchor.as_str()).collect();
        // The `&` is removed after the spaces around it have become dashes,
        // which is why `A & B` is `a--b` and not `a-b`.
        assert_eq!(anchors, ["getting-started", "notes-part-one", "a--b"]);
    }

    #[test]
    fn a_repeated_heading_gets_a_numbered_anchor() {
        let out = render(
            "## Notes\n\n## Notes\n\n## Notes\n",
            60,
            &Options::default(),
        );
        let anchors: Vec<&str> = out.toc.iter().map(|entry| entry.anchor.as_str()).collect();
        assert_eq!(anchors, ["notes", "notes-1", "notes-2"]);
    }

    #[test]
    fn links_are_reported_with_their_target() {
        let out = render(
            "see [docs](https://example.com) now\n",
            60,
            &Options::default(),
        );
        assert_eq!(out.links.len(), 1);
        let link = &out.links[0];
        assert_eq!(link.href, "https://example.com");
        let text = &out.lines[link.row as usize - 1].text;
        assert_eq!(&text[link.col - 1..link.col - 1 + link.len], "docs");
    }

    #[test]
    fn gfm_alerts_get_a_title_row() {
        let rows = render_text("> [!WARNING]\n> careful\n", 40);
        assert_eq!(rows[0], "▏ ▸ WARNING");
        assert_eq!(rows[1], "▏ careful");
    }

    #[test]
    fn footnotes_are_numbered_consistently() {
        let out = render(
            "text[^a] more[^b]\n\n[^a]: first\n[^b]: second\n",
            60,
            &Options::default(),
        );
        let rows: Vec<&str> = out.lines.iter().map(|line| line.text.as_str()).collect();
        assert!(rows[0].contains("text[1] more[2]"), "{rows:?}");
        assert!(
            rows.iter().any(|row| row.starts_with("[1] first")),
            "{rows:?}"
        );
        assert!(
            rows.iter().any(|row| row.starts_with("[2] second")),
            "{rows:?}"
        );
    }

    #[test]
    fn front_matter_renders_as_a_block() {
        let rows = render_text("---\ntitle: x\n---\n\nbody\n", 40);
        assert!(rows[0].starts_with("╭─ yaml"), "{rows:?}");
    }

    #[test]
    fn ascii_mode_emits_no_wide_characters() {
        let source = "# Title\n\n- item\n\n> quote\n\n```rust\nfn x() {}\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n";
        let opts = Options {
            unicode: false,
            ..Options::default()
        };
        for line in render(source, 40, &opts).lines {
            assert!(line.text.is_ascii(), "{:?}", line.text);
        }
    }

    #[test]
    fn no_trailing_blank_rows() {
        let out = render("# Title\n\npara\n\n", 40, &Options::default());
        assert!(!out.lines.last().unwrap().text.is_empty());
    }

    #[test]
    fn blank_rows_never_double_up() {
        let rows = render_text("a\n\n\n\nb\n", 40);
        assert_eq!(rows, vec!["a", "", "b"]);
    }

    #[test]
    fn everything_stays_inside_the_window() {
        let source = include_str!("../../tests/fixtures/kitchen-sink.md");
        for width in [24usize, 40, 60, 100] {
            let out = checked(source, width);
            for line in &out.lines {
                assert!(
                    line.text.width() <= width,
                    "width {width}: {:?} is {}",
                    line.text,
                    line.text.width()
                );
            }
        }
    }

    #[test]
    fn properties_and_links_are_well_formed_on_the_kitchen_sink() {
        checked(include_str!("../../tests/fixtures/kitchen-sink.md"), 72);
    }

    #[test]
    fn cjk_content_never_overflows() {
        let source = "# 中文标题\n\n这是一段很长的中文段落，用来测试换行是否正确处理全角字符的宽度。\n\n- 列表项目一二三四五六七八九十\n";
        for width in [20usize, 33, 50] {
            for line in render(source, width, &Options::default()).lines {
                assert!(
                    line.text.width() <= width,
                    "{:?} at width {width}",
                    line.text
                );
            }
        }
    }

    #[test]
    fn a_pathologically_narrow_window_still_terminates() {
        let out = render(
            "- - - - deeply nested\n\n> > > quoted\n",
            4,
            &Options::default(),
        );
        assert!(!out.lines.is_empty());
    }

    #[test]
    fn empty_input_renders_nothing() {
        assert!(render("", 40, &Options::default()).lines.is_empty());
    }

    #[test]
    fn tabs_are_expanded_in_code() {
        let rows = render_text("```\n\tindented\n```\n", 40);
        assert!(rows[1].starts_with("│     indented"), "{:?}", rows[1]);
    }

    #[test]
    fn no_wrap_mode_keeps_paragraphs_on_one_row() {
        let opts = Options {
            wrap: false,
            ..Options::default()
        };
        let out = render("alpha beta gamma delta epsilon zeta eta theta\n", 20, &opts);
        assert_eq!(out.lines.len(), 1);
    }

    #[test]
    fn show_urls_appends_the_target() {
        let opts = Options {
            show_urls: true,
            ..Options::default()
        };
        let out = render("[docs](https://x.dev)\n", 60, &opts);
        assert!(
            out.lines[0].text.contains("(https://x.dev)"),
            "{:?}",
            out.lines[0].text
        );
    }

    #[test]
    fn max_width_caps_the_text_column() {
        let opts = Options {
            max_width: 30,
            ..Options::default()
        };
        let out = render("# Title\n", 100, &opts);
        assert_eq!(out.lines[1].text.width(), 30);
    }
}
