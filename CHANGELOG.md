# Changelog

All notable changes to this project are documented here.  The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-08-04

First release.

### Added

- **In-Vim Markdown preview.**  `:SimpleMarkdown` opens a side window holding
  the current buffer rendered as prose, re-rendered as you type and kept in
  scroll sync with the source cursor.  One preview per tab page; switching to
  another Markdown buffer re-points the existing one.
- **Rust rendering backend** (`simplemarkdown-daemon`), speaking JSON lines
  over stdin/stdout under the shared simplecore supervisor.  Parsing with
  pulldown-cmark, display-width-correct line breaking with unicode-width, and
  fenced-code syntax highlighting with syntect.
- **CommonMark plus GFM**: headings with rules, tight and loose lists nested
  to any depth, task lists, block quotes and GFM alerts, fenced and indented
  code blocks in labelled frames, tables with per-column alignment and
  proportional column fitting, links and autolinks, images, footnotes
  numbered consistently between reference and definition, definition lists,
  strikethrough, superscript and subscript, raw HTML, and YAML/TOML front
  matter.
- **Correct CJK layout.**  Wide glyphs count as two columns and are their own
  break opportunity, so a Chinese paragraph wraps between glyphs instead of
  being hard-split at the column.
- **Text-property styling** through 55 classes, all linked with
  `highlight default link` to groups a colour scheme already defines.  Code
  highlighting maps syntect scopes onto sixteen coarse classes rather than
  emitting RGB from a bundled theme.
- **Navigation inside the preview**: `<CR>` follows a link or jumps the source
  window to the line a row came from, `gx` opens a link, `gO` and
  `:SimpleMarkdownToc` show a heading popup, `]]` and `[[` move between
  headings.
- **ASCII decoration mode** (`:SimpleMarkdownStyle ascii`) for terminals that
  render East Asian Ambiguous width characters — box-drawing among them — as
  double width.
- **Operational commands**: `:SimpleMarkdownHealth`, `:SimpleMarkdownLog`,
  `:SimpleMarkdownRestart`, `:SimpleMarkdownDebug`, plus `--self-test`,
  `--preview` and `--classes` on the daemon itself.
- `make check-classes`, which diffs the daemon's property-class list against
  the plugin's.  An unregistered property type is a hard `prop_add()` error
  inside a channel callback; this catches the mismatch at build time instead.
