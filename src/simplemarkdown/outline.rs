//! The document's heading tree, without laying anything out.
//!
//! A render already produces a table of contents, but only as a by-product of
//! deciding where every row goes: it needs a window width, it runs syntect over
//! every fenced block, and it exists only where a preview window does.  Asking
//! "what are the headings and where does each section end" needs none of that,
//! and two things want the answer without a preview open — `:SimpleMarkdownToc`
//! from a plain source buffer, and folding, which Vim asks about once per line
//! per redraw and can never be made to wait for a render.
//!
//! `end_src` is the reason this is not just the render's `toc` with the rows
//! removed.  A section runs to the line before the next heading of the same
//! level or shallower, which is a question about the whole document and cannot
//! be answered one heading at a time.  It is also exactly a fold range.

use crate::protocol::OutlineEntry;
use crate::render::slug;
use pulldown_cmark::{Event, HeadingLevel, Options as MdOptions, Parser, Tag, TagEnd};
use std::collections::HashMap;

pub fn outline(lines: &[String]) -> Vec<OutlineEntry> {
    let source = lines.join("\n");
    let mut md = MdOptions::empty();
    md.insert(MdOptions::ENABLE_TABLES);
    md.insert(MdOptions::ENABLE_FOOTNOTES);
    md.insert(MdOptions::ENABLE_STRIKETHROUGH);
    md.insert(MdOptions::ENABLE_TASKLISTS);
    md.insert(MdOptions::ENABLE_HEADING_ATTRIBUTES);
    md.insert(MdOptions::ENABLE_YAML_STYLE_METADATA_BLOCKS);
    md.insert(MdOptions::ENABLE_GFM);

    let mut starts = vec![0usize];
    starts.extend(source.match_indices('\n').map(|(index, _)| index + 1));
    let line_of = |offset: usize| starts.partition_point(|start| *start <= offset).max(1);

    let mut entries: Vec<OutlineEntry> = Vec::new();
    let mut seen: HashMap<String, usize> = HashMap::new();
    let mut collecting: Option<(u8, usize, String)> = None;

    for (event, range) in Parser::new_ext(&source, md).into_offset_iter() {
        match event {
            Event::Start(Tag::Heading { level, .. }) => {
                collecting = Some((level_of(level), range.start, String::new()));
            }
            Event::Text(text) | Event::Code(text) => {
                if let Some((_, _, gathered)) = collecting.as_mut() {
                    gathered.push_str(&text);
                }
            }
            Event::End(TagEnd::Heading(_)) => {
                let Some((level, offset, text)) = collecting.take() else {
                    continue;
                };
                let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
                let base = slug(&text);
                let count = seen.entry(base.clone()).or_insert(0);
                *count += 1;
                let anchor = if *count == 1 {
                    base
                } else {
                    format!("{base}-{}", *count - 1)
                };
                entries.push(OutlineEntry {
                    level,
                    text,
                    anchor,
                    src: line_of(offset),
                    // Filled in below: it depends on what comes after.
                    end_src: 0,
                });
            }
            _ => {}
        }
    }

    let last = lines.len().max(1);
    for index in 0..entries.len() {
        let level = entries[index].level;
        entries[index].end_src = entries[index + 1..]
            .iter()
            .find(|entry| entry.level <= level)
            .map_or(last, |next| {
                next.src.saturating_sub(1).max(entries[index].src)
            });
    }
    entries
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

    fn lines(text: &str) -> Vec<String> {
        text.lines().map(str::to_string).collect()
    }

    #[test]
    fn a_section_ends_where_the_next_one_of_its_level_begins() {
        let source = lines(
            "# Top\n\nintro\n\n## One\n\na\n\n### Deep\n\nb\n\n## Two\n\nc\n\n# Another\n\nd\n",
        );
        let entries = outline(&source);
        let shape: Vec<(u8, &str, usize, usize)> = entries
            .iter()
            .map(|entry| (entry.level, entry.text.as_str(), entry.src, entry.end_src))
            .collect();
        assert_eq!(
            shape,
            vec![
                (1, "Top", 1, 16),
                // Up to the line before the next heading, blank line included:
                // that is the fold a reader expects when they close a section.
                (2, "One", 5, 12),
                (3, "Deep", 9, 12),
                (2, "Two", 13, 16),
                (1, "Another", 17, 19),
            ]
        );
    }

    #[test]
    fn a_heading_inside_a_fence_is_not_one() {
        // Every markdown foldexpr in the wild is a pattern over `^#`, and every
        // one of them folds a shell script's comments.
        let entries = outline(&lines(
            "# Real\n\n```sh\n# not a heading\n```\n\n## Also real\n",
        ));
        let texts: Vec<&str> = entries.iter().map(|entry| entry.text.as_str()).collect();
        assert_eq!(texts, vec!["Real", "Also real"]);
    }

    #[test]
    fn a_setext_heading_counts_and_a_repeat_is_numbered() {
        let entries = outline(&lines("Title\n=====\n\n## Notes\n\na\n\n## Notes\n\nb\n"));
        let anchors: Vec<&str> = entries.iter().map(|entry| entry.anchor.as_str()).collect();
        assert_eq!(anchors, vec!["title", "notes", "notes-1"]);
        assert_eq!(entries[0].level, 1, "a setext underline is a heading");
        assert_eq!(entries[0].src, 1);
    }

    #[test]
    fn inline_markup_is_stripped_from_the_text_the_way_the_preview_strips_it() {
        let entries = outline(&lines("## A `code` and **bold** heading\n"));
        assert_eq!(entries[0].text, "A code and bold heading");
        assert_eq!(entries[0].anchor, "a-code-and-bold-heading");
    }

    #[test]
    fn a_document_with_no_headings_has_no_outline() {
        assert!(outline(&lines("just prose\n\nand more\n")).is_empty());
    }

    #[test]
    fn a_deeper_heading_does_not_close_a_shallower_section() {
        // `end_src` is what a fold range is: the H2 has to contain its H3.
        let entries = outline(&lines("## Parent\n\na\n\n### Child\n\nb\n"));
        assert_eq!((entries[0].src, entries[0].end_src), (1, 7));
        assert_eq!((entries[1].src, entries[1].end_src), (5, 7));
    }
}
