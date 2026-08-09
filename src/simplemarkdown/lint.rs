//! Document diagnostics.
//!
//! What a Markdown writer wants to ask — "is anything in this document
//! wrong?" — normally costs a Node install (markdownlint) or an LSP client
//! (marksman).  The parse that answers it has already happened here on every
//! keystroke, so the answer costs one more walk over events that are already in
//! memory.
//!
//! The checks are deliberately the ones a *parser* can be certain about, and
//! not one of the fifty style rules markdownlint ships.  A linter that is
//! opinionated about hard tabs and trailing spaces is a linter people turn off,
//! and once it is off the broken link goes unreported too.  Every check here
//! names something that is already wrong for a reader: a link that lands
//! nowhere, a footnote with no text, a table row the renderer will drop.
//!
//! Nothing here touches the filesystem.  Whether `../design/api.md` exists is a
//! question about a buffer's directory, and the daemon does not know where the
//! buffer is — or whether it has ever been written.
//!
//! The code set is closed: `codes::ALL` is what `--codes` prints, what the help
//! documents, and what `make check-codes` proves those two agree on.  A
//! diagnostic a user cannot look up is one they cannot act on.

use crate::protocol::LintItem;
use pulldown_cmark::{Event, HeadingLevel, Options as MdOptions, Parser, Tag, TagEnd};
use std::collections::{HashMap, HashSet};
use std::ops::Range;

/// Every diagnostic this daemon can emit, with the one-line explanation the
/// help repeats.  Kept in one place so the set stays greppable and closed.
pub mod codes {
    pub const BROKEN_ANCHOR: &str = "broken-anchor";
    pub const DUPLICATE_ANCHOR: &str = "duplicate-anchor";
    pub const EMPTY_LINK: &str = "empty-link";
    pub const HEADING_SKIP: &str = "heading-skip";
    pub const RAGGED_TABLE_ROW: &str = "ragged-table-row";
    pub const UNDEFINED_FOOTNOTE: &str = "undefined-footnote";
    pub const UNUSED_FOOTNOTE: &str = "unused-footnote";

    /// Code and description, in the order `--codes` prints them.
    pub const ALL: &[(&str, &str)] = &[
        (BROKEN_ANCHOR, "a #anchor link that matches no heading"),
        (DUPLICATE_ANCHOR, "two headings share one anchor"),
        (EMPTY_LINK, "a link or image with no destination"),
        (HEADING_SKIP, "a heading level was skipped"),
        (
            RAGGED_TABLE_ROW,
            "a table row has fewer or more cells than its header",
        ),
        (
            UNDEFINED_FOOTNOTE,
            "a footnote reference with no definition",
        ),
        (UNUSED_FOOTNOTE, "a footnote definition nothing refers to"),
    ];
}

/// `W` is something a reader will notice; `I` is advice.  The letters are
/// Vim's own quickfix types, so the location list needs no translation.
const WARN: &str = "W";
const INFO: &str = "I";

pub fn lint(source: &str) -> Vec<LintItem> {
    let mut md = MdOptions::empty();
    md.insert(MdOptions::ENABLE_TABLES);
    md.insert(MdOptions::ENABLE_FOOTNOTES);
    md.insert(MdOptions::ENABLE_STRIKETHROUGH);
    md.insert(MdOptions::ENABLE_TASKLISTS);
    md.insert(MdOptions::ENABLE_HEADING_ATTRIBUTES);
    md.insert(MdOptions::ENABLE_YAML_STYLE_METADATA_BLOCKS);
    md.insert(MdOptions::ENABLE_GFM);

    let events: Vec<(Event, Range<usize>)> =
        Parser::new_ext(source, md).into_offset_iter().collect();
    let mut starts = vec![0usize];
    starts.extend(source.match_indices('\n').map(|(index, _)| index + 1));
    let at = |offset: usize| -> (usize, usize) {
        let line = starts.partition_point(|start| *start <= offset).max(1);
        (line, offset - starts[line - 1] + 1)
    };

    let mut items: Vec<LintItem> = Vec::new();
    let anchors = headings(&events, &mut items, &at);
    links(&events, &anchors, &mut items, &at);
    footnotes(source, &events, &mut items, &at);
    tables(source, &events, &mut items, &at);

    items.sort_by_key(|item| (item.line, item.col, item.code));
    items
}

/// Every heading's anchor, plus the two heading diagnostics.
fn headings(
    events: &[(Event, Range<usize>)],
    items: &mut Vec<LintItem>,
    at: &impl Fn(usize) -> (usize, usize),
) -> HashSet<String> {
    let mut anchors: HashSet<String> = HashSet::new();
    let mut seen: HashMap<String, usize> = HashMap::new();
    let mut previous = 0u8;
    let mut collecting: Option<(u8, Range<usize>, String)> = None;

    for (event, range) in events {
        match event {
            Event::Start(Tag::Heading { level, .. }) => {
                collecting = Some((level_of(*level), range.clone(), String::new()));
            }
            Event::Text(text) | Event::Code(text) => {
                if let Some((_, _, gathered)) = collecting.as_mut() {
                    gathered.push_str(text);
                }
            }
            Event::End(TagEnd::Heading(_)) => {
                let Some((level, range, text)) = collecting.take() else {
                    continue;
                };
                let (line, col) = at(range.start);

                // A jump from H2 straight to H4 breaks every outline built from
                // the document — including this plugin's own — and is nearly
                // always a heading someone demoted without looking up.
                if previous > 0 && level > previous + 1 {
                    items.push(LintItem {
                        line,
                        col,
                        severity: INFO,
                        code: codes::HEADING_SKIP,
                        text: format!("heading level jumps from h{previous} to h{level}"),
                    });
                }
                previous = level;

                let base = crate::render::slug(&text);
                let count = seen.entry(base.clone()).or_insert(0);
                *count += 1;
                let anchor = if *count == 1 {
                    base.clone()
                } else {
                    format!("{base}-{}", *count - 1)
                };
                if *count == 2 {
                    // Reported once, on the second one: a heading repeated
                    // eight times should not be eight diagnostics.
                    items.push(LintItem {
                        line,
                        col,
                        severity: INFO,
                        code: codes::DUPLICATE_ANCHOR,
                        text: format!(
                            "another heading already anchors #{base}; this one is #{anchor}"
                        ),
                    });
                }
                anchors.insert(anchor);
            }
            _ => {}
        }
    }
    anchors
}

fn links(
    events: &[(Event, Range<usize>)],
    anchors: &HashSet<String>,
    items: &mut Vec<LintItem>,
    at: &impl Fn(usize) -> (usize, usize),
) {
    for (event, range) in events {
        let (kind, dest) = match event {
            Event::Start(Tag::Link { dest_url, .. }) => ("link", dest_url),
            Event::Start(Tag::Image { dest_url, .. }) => ("image", dest_url),
            _ => continue,
        };
        let (line, col) = at(range.start);
        if dest.trim().is_empty() {
            items.push(LintItem {
                line,
                col,
                severity: WARN,
                code: codes::EMPTY_LINK,
                text: format!("{kind} has no destination"),
            });
            continue;
        }
        // Only a *bare* anchor can be checked here.  `other.md#section` names a
        // heading in a document this daemon has never seen.
        if let Some(anchor) = dest.strip_prefix('#')
            && !anchor.is_empty()
            && !anchors.contains(&anchor.to_lowercase())
        {
            items.push(LintItem {
                line,
                col,
                severity: WARN,
                code: codes::BROKEN_ANCHOR,
                text: format!("no heading anchors #{anchor}"),
            });
        }
    }
}

fn footnotes(
    source: &str,
    events: &[(Event, Range<usize>)],
    items: &mut Vec<LintItem>,
    at: &impl Fn(usize) -> (usize, usize),
) {
    let mut defined: HashMap<String, Range<usize>> = HashMap::new();
    let mut referenced: HashSet<String> = HashSet::new();
    // Where a `[^a]` means nothing: inside a fence, or inside a code span.
    let mut code: Vec<Range<usize>> = Vec::new();

    for (event, range) in events {
        match event {
            Event::Start(Tag::CodeBlock(_)) => code.push(range.clone()),
            Event::Code(_) => code.push(range.clone()),
            Event::Start(Tag::FootnoteDefinition(name)) => {
                defined.insert(name.to_string(), range.clone());
            }
            Event::FootnoteReference(name) => {
                referenced.insert(name.to_string());
            }
            _ => {}
        }
    }

    // Scanned in the source, not gathered from the events, because a reference
    // with no definition never becomes a `FootnoteReference`: the parser hands
    // `[^b]` back as three ordinary text runs — `[`, `^b`, `]` — which is also
    // precisely what the reader is left looking at.  The events still say where
    // code is, so nothing inside a fence is mistaken for one.
    for (offset, name) in written_references(source, &code) {
        if !defined.contains_key(&name) {
            let (line, col) = at(offset);
            items.push(LintItem {
                line,
                col,
                severity: WARN,
                code: codes::UNDEFINED_FOOTNOTE,
                text: format!("[^{name}] has no definition"),
            });
        }
    }
    for (name, range) in defined {
        if !referenced.contains(&name) {
            let (line, col) = at(range.start);
            items.push(LintItem {
                line,
                col,
                severity: INFO,
                code: codes::UNUSED_FOOTNOTE,
                text: format!("[^{name}] is defined but never referenced"),
            });
        }
    }
}

/// Every `[^label]` written in `source` as a reference: byte offset and label.
/// The definition it belongs to — `[^label]: text` at the head of a line — is
/// not one of them.
fn written_references(source: &str, code: &[Range<usize>]) -> Vec<(usize, String)> {
    let bytes = source.as_bytes();
    let mut found = Vec::new();
    let mut at = 0usize;
    while let Some(open) = source[at..].find("[^") {
        let start = at + open;
        at = start + 2;
        let Some(end) = source[at..].find([']', '\n', '[']).map(|index| at + index) else {
            break;
        };
        if bytes[end] != b']' || end == at {
            continue;
        }
        let label = &source[at..end];
        // A definition, not a reference: nothing but whitespace to its left on
        // the line, and a colon immediately after it.
        let line_start = source[..start].rfind('\n').map_or(0, |index| index + 1);
        let indented = source[line_start..start].trim().is_empty();
        if indented && bytes.get(end + 1) == Some(&b':') {
            continue;
        }
        if code.iter().any(|range| range.contains(&start)) {
            continue;
        }
        found.push((start, label.to_string()));
    }
    found
}

/// A GFM table's shape is declared by its delimiter row, and a row that
/// disagrees with it loses cells or gains empty ones — silently, in every
/// renderer including this one.
///
/// Counted over the source rather than over the events, because the parser has
/// already normalised each row to the declared column count by the time it
/// emits it: what it hands back is what GFM will show, not what the author
/// wrote.  The cells are divided by the formatter's own `split_cells()` and
/// counted against the same `aligns.len()` the formatter lays a table out to,
/// so the two agree on which rows are ragged.  What the formatter then does
/// about it differs by direction, and so does what running it leaves here: a
/// row short of a cell is padded out and stops being reported; a row with one
/// too many keeps its surplus — widening the table would change what GFM
/// renders — and goes on being reported until its author decides which it is.
fn tables(
    source: &str,
    events: &[(Event, Range<usize>)],
    items: &mut Vec<LintItem>,
    at: &impl Fn(usize) -> (usize, usize),
) {
    for (event, range) in events {
        let Event::Start(Tag::Table(aligns)) = event else {
            continue;
        };
        let columns = aligns.len();
        if columns == 0 {
            continue;
        }
        let first = at(range.start).0;
        for (index, raw) in source[range.clone()].lines().enumerate() {
            // Index 1 is the delimiter row, which declares the shape rather
            // than having one.
            if index == 1 || raw.trim().is_empty() {
                continue;
            }
            let cells = crate::format::split_cells(
                raw.trim_start_matches(crate::format::is_container_char),
            )
            .len();
            if cells != columns {
                items.push(LintItem {
                    line: first + index,
                    col: 1,
                    severity: WARN,
                    code: codes::RAGGED_TABLE_ROW,
                    text: format!(
                        "row has {cells} cell{} but the table has {columns} columns",
                        if cells == 1 { "" } else { "s" }
                    ),
                });
            }
        }
    }
}

fn level_of(level: HeadingLevel) -> u8 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn codes_of(source: &str) -> Vec<&'static str> {
        lint(source).into_iter().map(|item| item.code).collect()
    }

    #[test]
    fn a_clean_document_reports_nothing() {
        let source = "# Title\n\n## Section\n\nProse with a [link](https://example.com) and\n\
             a jump to [the section](#section).\n\n| a | b |\n|---|---|\n| 1 | 2 |\n";
        assert_eq!(lint(source), Vec::new(), "{:?}", lint(source));
    }

    #[test]
    fn an_anchor_that_names_no_heading_is_reported_where_it_is_written() {
        let items = lint("# Title\n\nSee [below](#nowhere).\n");
        assert_eq!(items.len(), 1, "{items:?}");
        assert_eq!(items[0].code, codes::BROKEN_ANCHOR);
        assert_eq!(items[0].line, 3);
        assert_eq!(items[0].col, 5, "the column of the link, not of the line");
        assert!(items[0].text.contains("#nowhere"));
    }

    #[test]
    fn a_repeated_heading_is_reported_once_and_still_anchors() {
        let items = lint("## Notes\n\na\n\n## Notes\n\nb\n\n## Notes\n\n[x](#notes-2)\n");
        let duplicates: Vec<&LintItem> = items
            .iter()
            .filter(|item| item.code == codes::DUPLICATE_ANCHOR)
            .collect();
        assert_eq!(duplicates.len(), 1, "{items:?}");
        assert_eq!(duplicates[0].line, 5, "the second one, not the first");
        // The de-duplicated anchors are known, so a link to the third heading
        // is not also reported as broken.
        assert!(
            !items.iter().any(|item| item.code == codes::BROKEN_ANCHOR),
            "{items:?}"
        );
    }

    #[test]
    fn a_footnote_is_checked_both_ways() {
        let codes = codes_of("Text[^a] and more.\n\n[^b]: an orphan\n");
        assert!(codes.contains(&codes::UNDEFINED_FOOTNOTE), "{codes:?}");
        assert!(codes.contains(&codes::UNUSED_FOOTNOTE), "{codes:?}");
    }

    #[test]
    fn a_ragged_table_row_names_its_shape() {
        let items = lint("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |\n");
        let ragged: Vec<&LintItem> = items
            .iter()
            .filter(|item| item.code == codes::RAGGED_TABLE_ROW)
            .collect();
        assert_eq!(ragged.len(), 2, "{items:?}");
        assert_eq!(ragged[0].line, 3);
        assert!(ragged[0].text.contains("1 cell"), "{:?}", ragged[0].text);
    }

    #[test]
    fn a_skipped_heading_level_is_advice_not_an_error() {
        let items = lint("# One\n\n### Three\n");
        assert_eq!(items.len(), 1, "{items:?}");
        assert_eq!(items[0].code, codes::HEADING_SKIP);
        assert_eq!(items[0].severity, INFO);
    }

    #[test]
    fn nothing_inside_a_fence_is_linted() {
        // The whole reason for parsing rather than matching: a code sample is
        // not a broken link and a `[^x]` in it is not a footnote.
        let items = lint("# Title\n\n```sh\n| a | b |\n[x](#nowhere)\n[^nope]\n```\n");
        assert_eq!(items, Vec::new(), "{items:?}");
    }

    #[test]
    fn every_code_emitted_is_documented() {
        // The same discipline as classes::ALL: a diagnostic a user cannot look
        // up is one they cannot act on.
        let declared: HashSet<&str> = codes::ALL.iter().map(|(code, _)| *code).collect();
        let source = "# One\n\n### Three\n\n### Three\n\n[a]()\n\n[b](#nowhere)\n\n\
             text[^x]\n\n[^y]: orphan\n\n| a | b |\n|---|---|\n| 1 |\n";
        let seen: HashSet<&str> = lint(source).into_iter().map(|item| item.code).collect();
        assert_eq!(seen.len(), declared.len(), "{seen:?} vs {declared:?}");
        for code in seen {
            assert!(declared.contains(code), "{code} is not in codes::ALL");
        }
    }
}
