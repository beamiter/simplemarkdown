//! Formatting a GFM table back into the *source* buffer.
//!
//! Everything else here lays Markdown out for the preview window; this is the
//! one thing that hands text back to be written into the document.  It lives in
//! the daemon rather than in Vimscript for two reasons, both of which are the
//! reason this plugin has a daemon at all.
//!
//! Measuring: a column is as wide as its widest cell *on screen*, and every
//! Vimscript table aligner measures with `strlen()` or `strdisplaywidth()`.
//! The first is bytes, the second is right only for the terminal Vim happens to
//! be running in.  `unicode-width` is already linked here and already the
//! authority the preview aligns against, so a table formatted here and the same
//! table rendered in the preview agree by construction.
//!
//! Finding: which lines *are* the table is a parsing question, not a pattern
//! one.  A `|` inside a fenced code block is not a table row, a table inside a
//! block quote is still a table, and the delimiter row is what declares the
//! column alignments.  The parser answers all three; a regexp answers none of
//! them without becoming a parser.
//!
//! What it deliberately does not do: reflow cell contents.  A cell is moved as
//! written, so a formatter run is a whitespace-only change to the document and
//! `git diff -w` on a formatted table is empty.

use pulldown_cmark::{Alignment, Event, Options as MdOptions, Parser, Tag};
use serde::Serialize;
use unicode_width::UnicodeWidthStr;

/// A replacement for `from`..=`to` (1-based, inclusive) in the source.
///
/// Serialised as it stands for `edit_result`, which answers with a list of
/// them; `format_result` predates that and flattens the one it has.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Replacement {
    pub from: usize,
    pub to: usize,
    pub lines: Vec<String>,
}

/// Minimum dashes in a delimiter cell.  `:-:` needs three; giving every column
/// at least that keeps a table of one-character cells readable.
const MIN_COLUMN: usize = 3;

/// Format the table containing source line `line` (1-based), or `None` when
/// that line is not in a table.
pub fn table_at(lines: &[String], line: usize) -> Option<Replacement> {
    let source = lines.join("\n");
    let starts = line_starts(&source);
    let line_of = |offset: usize| -> usize {
        match starts.binary_search(&offset) {
            Ok(index) => index + 1,
            Err(index) => index,
        }
    };

    let mut md = MdOptions::empty();
    md.insert(MdOptions::ENABLE_TABLES);
    md.insert(MdOptions::ENABLE_STRIKETHROUGH);
    md.insert(MdOptions::ENABLE_TASKLISTS);
    md.insert(MdOptions::ENABLE_GFM);

    for (event, range) in Parser::new_ext(&source, md).into_offset_iter() {
        let Event::Start(Tag::Table(aligns)) = event else {
            continue;
        };
        let from = line_of(range.start).max(1);
        // `range.end` is one past the table, which for a table ending in a
        // newline is the first character of the line after it.
        let mut to = line_of(range.end.saturating_sub(1)).min(lines.len());
        while to > from && lines[to - 1].trim().is_empty() {
            to -= 1;
        }
        if line < from || line > to {
            continue;
        }
        return Some(Replacement {
            from,
            to,
            lines: format(&lines[from - 1..to], &aligns),
        });
    }
    None
}

/// Byte offset of the start of every line, for offset → line lookup.
fn line_starts(source: &str) -> Vec<usize> {
    let mut starts = vec![0usize];
    starts.extend(source.match_indices('\n').map(|(index, _)| index + 1));
    starts
}

/// Rebuild `rows` — the raw source lines of one table — with every column
/// padded to its widest cell.
fn format(rows: &[String], aligns: &[Alignment]) -> Vec<String> {
    // The container prefix (list indent, block-quote markers) comes from the
    // first row and is put back on every row, so a table indented raggedly
    // comes out square.  It is taken rather than assumed because a table inside
    // `> ` has that prefix on every one of its source lines and stripping it
    // would take the table out of the quote.
    let prefix = container_prefix(&rows[0]);
    let cells: Vec<Vec<String>> = rows
        .iter()
        .map(|row| split_cells(row.trim_start_matches(is_container_char)))
        .collect();

    // The delimiter is always the second line of a GFM table; it is rebuilt
    // from the parsed alignments rather than copied, so `|:-|` and `| :--- |`
    // come out identical.
    let delimiter = 1;
    let columns = cells.iter().map(Vec::len).max().unwrap_or(0);
    let mut widths = vec![MIN_COLUMN; columns];
    for (index, row) in cells.iter().enumerate() {
        if index == delimiter {
            continue;
        }
        for (column, cell) in row.iter().enumerate() {
            widths[column] = widths[column].max(cell.width());
        }
    }

    cells
        .iter()
        .enumerate()
        .map(|(index, row)| {
            let rendered: Vec<String> = (0..columns)
                .map(|column| {
                    let width = widths[column];
                    if index == delimiter {
                        return dashes(align_of(aligns, column), width);
                    }
                    pad(
                        row.get(column).map_or("", String::as_str),
                        align_of(aligns, column),
                        width,
                    )
                })
                .collect();
            format!("{prefix}| {} |", rendered.join(" | "))
        })
        .collect()
}

fn align_of(aligns: &[Alignment], column: usize) -> Alignment {
    aligns.get(column).copied().unwrap_or(Alignment::None)
}

pub fn is_container_char(ch: char) -> bool {
    ch == ' ' || ch == '\t' || ch == '>'
}

fn container_prefix(row: &str) -> String {
    row[..row.len() - row.trim_start_matches(is_container_char).len()].to_string()
}

/// `| a | b |` → `["a", "b"]`.  Shared with the linter, which decides whether a
/// row is ragged by the same rule the formatter pads it by.
///
/// A `\|` is an escaped pipe and part of the cell, which is the only way to put
/// one in a table at all; an unescaped one always divides cells, even inside a
/// code span, which is what GFM says and what the renderer here already does.
pub fn split_cells(row: &str) -> Vec<String> {
    let row = row.trim_end();
    let mut cells: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut escaped = false;
    let mut divided = false;
    for ch in row.chars() {
        if escaped {
            current.push(ch);
            escaped = false;
            continue;
        }
        match ch {
            '\\' => {
                current.push(ch);
                escaped = true;
            }
            '|' => {
                cells.push(current.trim().to_string());
                current.clear();
                divided = true;
            }
            _ => current.push(ch),
        }
    }
    // A leading pipe opened an empty cell before the first real one, and a
    // trailing pipe closed the last one; GFM makes both optional, so they are
    // recognised by what they left behind rather than by matching the text.
    if divided && current.trim().is_empty() {
        // The row ended on a divider: nothing after it.
    } else {
        cells.push(current.trim().to_string());
    }
    if row.starts_with('|') && !cells.is_empty() && cells[0].is_empty() {
        cells.remove(0);
    }
    cells
}

fn dashes(align: Alignment, width: usize) -> String {
    match align {
        Alignment::Left => format!(":{}", "-".repeat(width - 1)),
        Alignment::Right => format!("{}:", "-".repeat(width - 1)),
        Alignment::Center => format!(":{}:", "-".repeat(width - 2)),
        Alignment::None => "-".repeat(width),
    }
}

fn pad(cell: &str, align: Alignment, width: usize) -> String {
    let slack = width.saturating_sub(cell.width());
    match align {
        Alignment::Right => format!("{}{cell}", " ".repeat(slack)),
        Alignment::Center => {
            let left = slack / 2;
            format!("{}{cell}{}", " ".repeat(left), " ".repeat(slack - left))
        }
        _ => format!("{cell}{}", " ".repeat(slack)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(text: &str) -> Vec<String> {
        text.lines().map(str::to_string).collect()
    }

    fn formatted(text: &str, line: usize) -> Vec<String> {
        table_at(&lines(text), line)
            .unwrap_or_else(|| panic!("no table at line {line}"))
            .lines
    }

    #[test]
    fn columns_are_padded_to_their_widest_cell() {
        let out = formatted("| a | long header |\n|---|---|\n| xyz | b |\n", 1);
        assert_eq!(
            out,
            vec![
                "| a   | long header |",
                "| --- | ----------- |",
                "| xyz | b           |",
            ]
        );
    }

    #[test]
    fn the_declared_alignment_survives_and_moves_the_content() {
        let out = formatted("| a | b | c |\n|:--|--:|:-:|\n| 1 | 2 | 3 |\n", 3);
        assert_eq!(
            out,
            vec![
                "| a   |   b |  c  |",
                "| :-- | --: | :-: |",
                "| 1   |   2 |  3  |"
            ]
        );
    }

    #[test]
    fn a_wide_glyph_is_measured_in_columns_not_bytes() {
        // The whole reason this is not a Vimscript function: `strlen()` would
        // make the CJK column six bytes wide and `strchars()` two.
        let out = formatted("| name | x |\n|---|---|\n| 名前 | y |\n", 1);
        for row in &out {
            assert_eq!(row.width(), out[0].width(), "{out:?}");
        }
        assert_eq!(out[2], "| 名前 | y   |");
    }

    #[test]
    fn an_escaped_pipe_stays_inside_its_cell() {
        let out = formatted("| a | b |\n|---|---|\n| x \\| y | z |\n", 3);
        assert_eq!(out[2], "| x \\| y | z   |");
        assert_eq!(out[0], "| a      | b   |");
    }

    #[test]
    fn a_ragged_row_is_padded_rather_than_truncated() {
        // The row is short of a cell.  Dropping the column would be a
        // formatter deleting text; padding says what GFM already renders.
        let out = formatted("| a | b |\n|---|---|\n| 1 |\n", 3);
        assert_eq!(out[2], "| 1   |     |");
    }

    #[test]
    fn a_table_without_outer_pipes_gains_them() {
        let out = formatted("a | b\n--|--\n1 | 2\n", 1);
        assert_eq!(out, vec!["| a   | b   |", "| --- | --- |", "| 1   | 2   |"]);
    }

    #[test]
    fn a_quoted_table_stays_quoted() {
        let out = formatted("> | a | b |\n> |---|---|\n> | 1 | 2 |\n", 2);
        assert_eq!(
            out,
            vec!["> | a   | b   |", "> | --- | --- |", "> | 1   | 2   |"]
        );
    }

    #[test]
    fn a_pipe_in_a_fenced_block_is_not_a_table() {
        // A pattern-matching formatter finds a table here; a parser does not.
        let source = lines("```\n| a | b |\n|---|---|\n```\n");
        assert_eq!(table_at(&source, 2), None);
    }

    #[test]
    fn the_range_reported_is_the_table_and_nothing_around_it() {
        let source = lines("intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\ntail\n");
        let replacement = table_at(&source, 4).expect("a table on line 4");
        assert_eq!((replacement.from, replacement.to), (3, 5));
        assert_eq!(table_at(&source, 1), None, "the paragraph above");
        assert_eq!(table_at(&source, 7), None, "the paragraph below");
    }

    #[test]
    fn formatting_is_idempotent() {
        let once = formatted("|a|b|\n|-|-:|\n|longer|2|\n", 1);
        let twice = table_at(&once, 1).expect("still a table").lines;
        assert_eq!(once, twice);
    }
}
