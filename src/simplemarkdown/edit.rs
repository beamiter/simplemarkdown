//! Structural edits to the *source* document: heading levels and list numbers.
//!
//! `format.rs` squares a table up because the widths are a measurement Vimscript
//! cannot take.  These two are here for the other reason the daemon exists:
//! *which lines are the structure* is a parsing question.  A `#` at the start of
//! a line in a fenced shell block is a comment, a `1.` inside a code sample is
//! not a list item, and a setext underline turns the line above it into a
//! heading with no `#` anywhere.  Every heading-shifting Vim plugin in the wild
//! is a pattern over `^#` and gets all three wrong.
//!
//! Each answer is a list of replacements rather than one span, so demoting a
//! section touches its heading lines and leaves every line of prose between them
//! — and their marks, and their undo history — exactly where they were.  They
//! are returned in source order and applied by the client from the bottom up,
//! which is what lets one of them change the document's height (a setext
//! heading demoted past H2 becomes a one-line ATX heading) without invalidating
//! the ranges of the ones above it.
//!
//! Nothing here reflows or rewrites content: a heading keeps its text and its
//! trailing `##` closing sequence, an item keeps everything after its marker.

use crate::format::{Replacement, is_container_char};
use pulldown_cmark::{Event, HeadingLevel, Options as MdOptions, Parser, Tag, TagEnd};

/// What the client asked for.  A closed set, like the diagnostic codes: an op
/// the daemon does not know is a typo in the client, not a request to guess.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    /// One level shallower: `##` → `#`.
    Promote,
    /// One level deeper: `##` → `###`.
    Demote,
    /// Renumber the ordered lists the range touches from their declared start.
    Renumber,
}

impl Op {
    pub fn parse(name: &str) -> Option<Op> {
        match name {
            "promote" => Some(Op::Promote),
            "demote" => Some(Op::Demote),
            "renumber" => Some(Op::Renumber),
            _ => None,
        }
    }
}

/// Apply `op` to source lines `from`..=`to` (1-based, inclusive).
///
/// An empty result means "nothing here to do", which is an ordinary answer —
/// the cursor was not on a heading, or the list is already numbered.  An `Err`
/// means the edit was refused and says why, so the client can show it verbatim.
pub fn edit(op: Op, lines: &[String], from: usize, to: usize) -> Result<Vec<Replacement>, String> {
    match op {
        Op::Promote => shift_headings(lines, from, to, -1),
        Op::Demote => shift_headings(lines, from, to, 1),
        Op::Renumber => Ok(renumber(lines, from, to)),
    }
}

fn parser_options() -> MdOptions {
    crate::md::options(false)
}

/// Byte offset → 1-based line, the same lookup `format.rs` and `outline.rs` use.
fn line_map(source: &str) -> impl Fn(usize) -> usize + '_ {
    let mut starts = vec![0usize];
    starts.extend(source.match_indices('\n').map(|(index, _)| index + 1));
    move |offset: usize| starts.partition_point(|start| *start <= offset).max(1)
}

/// One heading as it sits in the source.
#[derive(Debug, Clone)]
struct Heading {
    level: u8,
    /// 1-based line the heading starts on.
    src: usize,
    /// 1-based last line of the heading: the setext underline, or `src`.
    last: usize,
}

fn headings(lines: &[String], source: &str) -> Vec<Heading> {
    let line_of = line_map(source);
    let mut found = Vec::new();
    for (event, range) in Parser::new_ext(source, parser_options()).into_offset_iter() {
        let Event::Start(Tag::Heading { level, .. }) = event else {
            continue;
        };
        let src = line_of(range.start);
        // `range.end` is one past the heading, which for a heading ending in a
        // newline is the first byte of the next line.
        let mut last = line_of(range.end.saturating_sub(1)).min(lines.len().max(1));
        while last > src && lines[last - 1].trim().is_empty() {
            last -= 1;
        }
        found.push(Heading {
            level: level_of(level),
            src,
            last,
        });
    }
    found
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

/// Which headings a range means.
///
/// A range the user drew means the headings inside it and nothing else — that
/// is what a selection is.  A bare command (`from == to`, the cursor's line)
/// means the *section* it is in: the heading at or above the cursor together
/// with everything nested under it, so demoting a chapter takes its subsections
/// with it and the tree it describes still says what it said before.
fn selected(all: &[Heading], from: usize, to: usize) -> Vec<Heading> {
    if from != to {
        return all
            .iter()
            .filter(|heading| heading.src >= from && heading.src <= to)
            .cloned()
            .collect();
    }
    // A single line: the section it belongs to — the heading the cursor is on,
    // or the nearest one above it, plus everything nested under that.
    let Some(index) = all.iter().rposition(|heading| heading.src <= from) else {
        return Vec::new();
    };
    let level = all[index].level;
    let mut section = vec![all[index].clone()];
    for heading in &all[index + 1..] {
        if heading.level <= level {
            break;
        }
        section.push(heading.clone());
    }
    section
}

fn shift_headings(
    lines: &[String],
    from: usize,
    to: usize,
    delta: i8,
) -> Result<Vec<Replacement>, String> {
    let source = lines.join("\n");
    let chosen = selected(&headings(lines, &source), from, to);
    let mut edits = Vec::new();
    for heading in &chosen {
        let want = i16::from(heading.level) + i16::from(delta);
        if !(1..=6).contains(&want) {
            let text = lines
                .get(heading.src - 1)
                .map_or("", |line| line.trim())
                .to_string();
            return Err(format!(
                "{} would take {text:?} past H{}",
                if delta < 0 { "promoting" } else { "demoting" },
                if want < 1 { 1 } else { 6 }
            ));
        }
        let want = want as u8;
        let head = lines[heading.src - 1].clone();
        let prefix = container_prefix(&head);
        let body = &head[prefix.len()..];
        if heading.last == heading.src {
            // ATX: the `#` run is the level, and everything after it — text,
            // trailing `##`, trailing spaces — is the heading as written.
            let rest = body.trim_start_matches('#');
            let replaced = format!("{prefix}{}{rest}", "#".repeat(want as usize));
            if replaced != head {
                edits.push(Replacement {
                    from: heading.src,
                    to: heading.src,
                    lines: vec![replaced],
                });
            }
        } else if want <= 2 {
            // Setext staying setext: only the underline carries the level, and
            // its length is the author's, not ours.
            let rule = lines[heading.last - 1].clone();
            let rule_prefix = container_prefix(&rule);
            let width = rule[rule_prefix.len()..].trim_end().chars().count().max(1);
            let replaced = format!(
                "{rule_prefix}{}",
                if want == 1 { "=" } else { "-" }.repeat(width)
            );
            if replaced != rule {
                edits.push(Replacement {
                    from: heading.last,
                    to: heading.last,
                    lines: vec![replaced],
                });
            }
        } else {
            // Setext has no H3: below H2 the only way to say it is ATX, so the
            // underline goes and the two lines become one.  Refused rather than
            // guessed when the heading text is itself several lines, because
            // joining them would change where every word sits.
            if heading.last != heading.src + 1 {
                return Err(format!(
                    "the setext heading on line {} spans several lines and cannot become an H{want}",
                    heading.src
                ));
            }
            edits.push(Replacement {
                from: heading.src,
                to: heading.last,
                lines: vec![format!(
                    "{prefix}{} {}",
                    "#".repeat(want as usize),
                    body.trim()
                )],
            });
        }
    }
    Ok(edits)
}

fn container_prefix(line: &str) -> String {
    line[..line.len() - line.trim_start_matches(is_container_char).len()].to_string()
}

/// Renumber every ordered list the range touches, from the number the list
/// declares.  A list written `1. 1. 1.` — which is what a lazy author writes and
/// what GFM renders as 1, 2, 3 — becomes `1. 2. 3.`; a list that starts at 5
/// stays starting at 5.  Bullets are left alone, and so is everything after the
/// marker.
fn renumber(lines: &[String], from: usize, to: usize) -> Vec<Replacement> {
    let source = lines.join("\n");
    let line_of = line_map(&source);

    // One frame per open list.  `Some(next)` is the number the next item of an
    // ordered list takes; `None` is a bullet list, whose items are skipped but
    // whose frame still has to be pushed so nesting stays aligned.
    let mut stack: Vec<Option<u64>> = Vec::new();
    // Whether the innermost open list overlaps the range the user named — a
    // nested list inside it does too, so "renumber the list here" renumbers the
    // whole structure it belongs to rather than one level of it.
    let mut wanted: Vec<bool> = Vec::new();
    let mut edits: Vec<Replacement> = Vec::new();

    for (event, range) in Parser::new_ext(&source, parser_options()).into_offset_iter() {
        match event {
            Event::Start(Tag::List(start)) => {
                let first = line_of(range.start);
                let last = line_of(range.end.saturating_sub(1));
                let overlaps = first <= to && last >= from;
                stack.push(start);
                wanted.push(overlaps || wanted.last().copied().unwrap_or(false));
            }
            Event::End(TagEnd::List(_)) => {
                stack.pop();
                wanted.pop();
            }
            Event::Start(Tag::Item) => {
                let Some(Some(next)) = stack.last_mut() else {
                    continue;
                };
                let number = *next;
                *next += 1;
                if !wanted.last().copied().unwrap_or(false) {
                    continue;
                }
                let line = line_of(range.start);
                let Some(text) = lines.get(line - 1) else {
                    continue;
                };
                if let Some(replaced) = with_number(text, number)
                    && &replaced != text
                {
                    edits.push(Replacement {
                        from: line,
                        to: line,
                        lines: vec![replaced],
                    });
                }
            }
            _ => {}
        }
    }
    edits.sort_by_key(|edit| edit.from);
    edits
}

/// Rewrite the ordered-list marker at the start of `line` to `number`, or
/// `None` when there is not one there (a bullet inside an ordered list's item,
/// a lazy continuation line).
fn with_number(line: &str, number: u64) -> Option<String> {
    let prefix = container_prefix(line);
    let rest = &line[prefix.len()..];
    let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
    if digits.is_empty() {
        return None;
    }
    let after = &rest[digits.len()..];
    let delimiter = after.chars().next()?;
    if delimiter != '.' && delimiter != ')' {
        return None;
    }
    Some(format!("{prefix}{number}{after}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(text: &str) -> Vec<String> {
        text.lines().map(str::to_string).collect()
    }

    /// Apply the edits the way the client does — bottom up, so one that changes
    /// the document's height leaves the ranges above it alone.
    fn applied(op: Op, text: &str, from: usize, to: usize) -> Vec<String> {
        let mut out = lines(text);
        let mut edits = edit(op, &out, from, to).expect("the edit was refused");
        edits.sort_by_key(|edit| std::cmp::Reverse(edit.from));
        for edit in edits {
            out.splice(edit.from - 1..edit.to, edit.lines);
        }
        out
    }

    #[test]
    fn a_bare_demote_takes_the_whole_section_with_it() {
        // The tree has to still say what it said: an H2 demoted while its H3
        // stays put makes the child a sibling.
        let out = applied(
            Op::Demote,
            "# Top\n\n## One\n\na\n\n### Deep\n\nb\n\n## Two\n",
            3,
            3,
        );
        assert_eq!(
            out,
            lines("# Top\n\n### One\n\na\n\n#### Deep\n\nb\n\n## Two\n")
        );
    }

    #[test]
    fn a_range_means_the_headings_inside_it_and_nothing_else() {
        let out = applied(Op::Promote, "## One\n\na\n\n### Deep\n\nb\n", 1, 3);
        assert_eq!(out, lines("# One\n\na\n\n### Deep\n\nb\n"));
    }

    #[test]
    fn the_cursor_below_a_heading_still_means_that_section() {
        let out = applied(Op::Demote, "## One\n\nprose\n", 3, 3);
        assert_eq!(out[0], "### One");
    }

    #[test]
    fn a_hash_inside_a_fence_is_not_a_heading() {
        // The whole reason this is not a `:s/^#/##/`.
        let source = "# Real\n\n```sh\n# a comment\ncode\n```\n";
        let out = applied(Op::Demote, source, 1, 6);
        assert_eq!(out, lines("## Real\n\n```sh\n# a comment\ncode\n```\n"));
    }

    #[test]
    fn a_heading_keeps_its_closing_sequence_and_its_indent() {
        let out = applied(Op::Demote, "> ## Quoted ##\n", 1, 1);
        assert_eq!(out[0], "> ### Quoted ##");
    }

    #[test]
    fn a_setext_heading_changes_its_underline() {
        let out = applied(Op::Demote, "Title\n=====\n\nbody\n", 1, 2);
        assert_eq!(out, lines("Title\n-----\n\nbody\n"));
        let back = applied(Op::Promote, "Title\n-----\n\nbody\n", 1, 2);
        assert_eq!(back, lines("Title\n=====\n\nbody\n"));
    }

    #[test]
    fn a_setext_heading_below_h2_becomes_atx_and_the_document_shrinks() {
        // There is no setext H3: the underline is the only thing that said
        // "heading", so it has to be replaced by the `###` that now says it.
        let out = applied(Op::Demote, "intro\n\nTitle\n-----\n\nbody\n", 3, 3);
        assert_eq!(out, lines("intro\n\n### Title\n\nbody\n"));
    }

    #[test]
    fn going_past_the_ends_is_refused_whole() {
        let source = lines("# Top\n\n## One\n");
        let error = edit(Op::Promote, &source, 1, 1).expect_err("H1 cannot promote");
        assert!(error.contains("past H1"), "{error}");
        // And nothing below it moved either: a partial answer would leave the
        // document half-shifted with no way to tell which half.
        assert_eq!(edit(Op::Promote, &source, 3, 3).unwrap().len(), 1);

        let deep = lines("###### Bottom\n");
        let error = edit(Op::Demote, &deep, 1, 1).expect_err("H6 cannot demote");
        assert!(error.contains("past H6"), "{error}");
    }

    #[test]
    fn a_document_with_no_heading_here_is_not_an_error() {
        assert!(
            edit(Op::Demote, &lines("just prose\n"), 1, 1)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn a_lazy_list_is_numbered_in_order() {
        let out = applied(Op::Renumber, "1. one\n1. two\n1. three\n", 1, 1);
        assert_eq!(out, lines("1. one\n2. two\n3. three\n"));
    }

    #[test]
    fn the_declared_start_and_the_delimiter_are_kept() {
        let out = applied(Op::Renumber, "5) five\n9) six\n9) seven\n", 2, 2);
        assert_eq!(out, lines("5) five\n6) six\n7) seven\n"));
    }

    #[test]
    fn a_nested_list_is_numbered_on_its_own() {
        let out = applied(
            Op::Renumber,
            "1. one\n   1. a\n   1. b\n1. two\n1. three\n",
            1,
            1,
        );
        assert_eq!(out, lines("1. one\n   1. a\n   2. b\n2. two\n3. three\n"));
    }

    #[test]
    fn numbers_inside_a_fence_are_not_list_items() {
        let source = "1. one\n1. two\n\n```\n1. not a list\n1. still not\n```\n";
        let out = applied(Op::Renumber, source, 1, 1);
        assert_eq!(
            out,
            lines("1. one\n2. two\n\n```\n1. not a list\n1. still not\n```\n")
        );
    }

    #[test]
    fn a_list_the_range_does_not_touch_is_left_alone() {
        let source = "1. one\n1. two\n\ntext\n\n1. other\n1. list\n";
        let out = applied(Op::Renumber, source, 6, 7);
        assert_eq!(out, lines("1. one\n1. two\n\ntext\n\n1. other\n2. list\n"));
    }

    #[test]
    fn a_bullet_list_is_not_numbered() {
        assert!(
            edit(Op::Renumber, &lines("- one\n- two\n"), 1, 2)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn renumbering_an_ordered_list_is_idempotent() {
        let once = applied(Op::Renumber, "3. a\n7. b\n2. c\n", 1, 3);
        let twice = applied(Op::Renumber, &once.join("\n"), 1, 3);
        assert_eq!(once, twice);
        assert_eq!(once, lines("3. a\n4. b\n5. c\n"));
    }

    #[test]
    fn an_unknown_op_is_not_guessed_at() {
        assert_eq!(Op::parse("promote"), Some(Op::Promote));
        assert_eq!(Op::parse("Promote"), None);
        assert_eq!(Op::parse(""), None);
    }
}
