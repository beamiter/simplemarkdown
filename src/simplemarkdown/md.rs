//! The one CommonMark option set.
//!
//! There were six, hand-copied into the renderer, the page emitter, the
//! outline, the linter, the structural edits and the table formatter — and they
//! had drifted into three different sets.  A parser told less than another one
//! reads a different document: `+++` front matter that one file skips is prose
//! to another, so a `# Draft` inside it is a heading to the linter and to
//! nothing else, and a `|` inside it is a table to the formatter and to nothing
//! else.  `outline.rs` already carried a comment describing exactly this after
//! it was bitten once; this is the same fix applied to the cause rather than to
//! the file that happened to show the symptom.
//!
//! Every walker in this daemon parses through here, and the only thing any of
//! them is allowed to differ on is maths — which only the browser preview
//! typesets, and which changes what `$` means in prose.

use pulldown_cmark::Options;

/// What every walker parses with.  `math` is the one dial, and it belongs to
/// the page: `$…$` is only worth taking as a formula when something is going to
/// typeset it, and left on with no engine it would strip the dollars off a
/// price.
pub fn options(math: bool) -> Options {
    let mut md = Options::empty();
    md.insert(Options::ENABLE_TABLES);
    md.insert(Options::ENABLE_FOOTNOTES);
    md.insert(Options::ENABLE_STRIKETHROUGH);
    md.insert(Options::ENABLE_TASKLISTS);
    md.insert(Options::ENABLE_HEADING_ATTRIBUTES);
    md.insert(Options::ENABLE_YAML_STYLE_METADATA_BLOCKS);
    md.insert(Options::ENABLE_PLUSES_DELIMITED_METADATA_BLOCKS);
    md.insert(Options::ENABLE_DEFINITION_LIST);
    md.insert(Options::ENABLE_SUPERSCRIPT);
    md.insert(Options::ENABLE_SUBSCRIPT);
    // GFM alerts (`> [!NOTE]`) ride on this flag.
    md.insert(Options::ENABLE_GFM);
    if math {
        md.insert(Options::ENABLE_MATH);
    }
    md
}
