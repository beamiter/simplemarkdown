# Changelog

All notable changes to this project are documented here.  The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### 全套统一

- `.simplecore/` 回来了。10 个仓库里的 supervisor(`autoload/<plugin>/core.vim`
  与三个测试文件)本来就是一套 vendored bundle,但源头目录早已丢失,而每个
  Makefile 都还在引用 `../.simplecore/vendor.sh`。现在 bundle 有了源头,而且
  每个仓库带一份 `.simplecore.manifest` 记录各文件的 sha256,`make core-verify`
  会校验它,`check` 依赖它——手改 vendored 文件会在改它的那个仓库里直接失败,
  不需要 `.simplecore/` 在场。
- 安装器抽成共享的 `install-common.sh`,各仓库的 `install.sh` 只剩配置。
  由此补齐的能力:构建前检查 cargo/rustc 与 MSRV(此前 3 个仓库缺,用户看到的
  是一屏 trait 解析错误);原子替换(此前 2 个仓库是就地覆写,Vim 还开着旧 daemon
  时会 ETXTBSY);Windows 的 `.exe` 后缀;安装前用 `--self-test` 验证刚构建的
  二进制;以及生成 helptags。
- `make check` 现在是每个仓库统一的完整门禁。simplemarkdown 与 simpleminimap
  此前叫 `make test`,旧名字保留为别名。
- daemon 的命令行统一为 `--version` / `--help` / `--self-test`。

### 工具链

- `rust-version` 统一到 1.88(此前 1.85 与 1.88 各半)。实测:1.88 能构建全部
  10 个仓库,1.85 只能构建 5 个。
- `cargo update`:全部为补丁级更新。

  注意:这次更新让 `ignore` 从 0.4.27 升到 0.4.30+,而后者用了 let-chains。
  simplefinder 与 simpletree 此前声明的 1.85 在更新前是真实可用的,更新后不再成立
  ——这是这次依赖刷新付出的代价,不是发现了旧的错误声明。
- MSRV 提到 1.88 后,clippy 的 `collapsible_if` 开始建议用 let-chains 合并
  (该 lint 受 MSRV 门控)。已按建议合并,语义不变。

### Added

- **The outline is its own question now, and three things ask it.** A render's
  table of contents is a by-product of laying rows out for a window of some
  width — it needs syntect, and it only exists where a preview does. The
  backend now answers `outline` on its own: headings, their anchors, and the
  line each section *ends* on, which is what a fold range is made of.
  `:SimpleMarkdownToc` in a plain buffer no longer splits the window and starts
  a render to answer what is in the document; `]]` and `[[` work in the source
  buffer, where they move your cursor rather than reaching across to a preview
  window's; and `g:simplemarkdown_folding` folds Markdown by heading with the
  levels from that parse. Every Markdown foldexpr in the wild is a pattern over
  `^#`, and every one of them folds the comments in a fenced shell block. The
  levels are cached per buffer and refreshed in the background, with the
  previous ones standing while a refresh is in flight, because Vim asks
  foldexpr once per line per redraw and it can never be made to wait.

- **`:SimpleMarkdownLint` says what is wrong with the document, in the location
  list.** "Is anything in this file broken?" normally costs a Node install
  (markdownlint) or an LSP client (marksman); the parse that answers it has
  already happened here on every keystroke, so the answer is one more walk over
  events that are already in memory. Seven checks — `broken-anchor`,
  `duplicate-anchor`, `empty-link`, `heading-skip`, `ragged-table-row`,
  `undefined-footnote`, `unused-footnote` — and deliberately not one of
  markdownlint's fifty style rules: a linter opinionated about trailing spaces
  is one people switch off, and once it is off the broken link goes unreported
  too. Every check names something already wrong for a reader. Nothing inside a
  fenced code block is reported, which is what parsing buys over matching: a
  `# comment` in a shell sample is not a heading and `[x](#nowhere)` in it is
  not a broken link. `W` for what a reader will notice, `I` for advice, so
  `:lnext` can be filtered. The code set is closed the way the property classes
  are: `--codes` prints it, the help documents it, and `make check-codes` fails
  the build when those two disagree — a diagnostic a user cannot look up is one
  they cannot act on. `g:simplemarkdown_lint_on_write` runs it on every save,
  silently: the list is filled and the screen is left alone.

- **`:SimpleMarkdownFormatTable` realigns the GFM table the cursor is in.** The
  first command here that writes Markdown rather than reading it, and the first
  reason the daemon is worth having for something other than the preview: a
  column is as wide as its widest cell *on screen*, and the only measure
  Vimscript has for that is `strdisplaywidth()`, which answers for the terminal
  it is running in rather than for the file — so every Vimscript table aligner
  lines a CJK or emoji table up for its author and for nobody else. The widths
  come from the same `unicode-width` tables the preview is laid out with, and
  which lines are the table comes from the parser, so a `|` inside a fenced code
  block is not a table row and a table inside a block quote keeps its `> `. The
  delimiter row is rebuilt from the alignments it declares, a row short of a
  cell is padded rather than truncated, and cell contents are moved but never
  reflowed: the whole edit is whitespace, in one undo step, over the table's own
  lines and nothing else. New capability `format`, new
  `<Plug>(simplemarkdown-format-table)`; a backend that predates it says so
  instead of failing obscurely.

- **An inserted line is a patch, not a whole document** (protocol v3). A row's
  source line used to be part of its identity, so pressing Enter — which moves
  every row below it in the row → source map and moves nothing on screen — left
  the diff no common suffix and sent the entire document. Measured on a
  1,800-row preview: inserting one line above everything was a 125,303-byte
  reply and is now an 84-byte patch. `Enter`, `o`, `dd` and every paste, which
  is about half of all editing, went the expensive way; only edits in place
  were ever incremental. Rows now compare on appearance alone and the map
  arrives as its own correction, usually a single delta whatever the size of
  the document. Two checksums instead of one (`total` for the rows, `src_sum`
  for the map), because two arrays spliced independently can drift where one
  could not; either mismatching resynchronises with a full render. The
  patch-versus-document heuristic compares wire bytes rather than row counts,
  which had called a patch of ten table rows bigger than a thousand blank ones.
  Requires a rebuilt daemon: `./install.sh`, then `:SimpleMarkdownRestart`.

- **Every preview key is a `<Plug>`, and any one of them can be moved or
  dropped.** `g:simplemarkdown_default_mappings` was all or nothing: disliking
  `x` on tasks meant giving up `q`, `r`, `<CR>`, `gx`, `gO` and `]]` as well,
  and none of them had a `<Plug>` to rebind. `g:simplemarkdown_preview_mappings`
  now takes per-action overrides — `{'toggle-task': ''}` drops that one and
  leaves the rest — and `g?` in the preview shows the keys actually in force,
  built from the same table that installs them so it cannot drift.

- **The outline, link table and block index are sent only when they change.**
  All three describe the whole document however little of it moved, so they
  travelled in full on every keystroke: on an 1,800-row document a one-word edit
  was an 84-byte patch inside a 9,976-byte reply, and Vim parsed that JSON on
  the main thread each time. The daemon fingerprints each per session and leaves
  out the ones the client already has; the same reply is now 195 bytes. Absent
  means "keep what you have", exactly as an absent `lines` already meant "the
  patch is the whole answer".

- **`make bench`.** It was in the Makefile's `.PHONY` list with no rule behind
  it while the CHANGELOG published first-render and steady-state figures that
  nothing in the tree could take. `simplemarkdown-daemon --bench FILE [WIDTH]
  [RUNS]` times a first render, the steady-state renders after it — the gap
  between the two is the highlight cache — and the patch a one-word edit
  produces, against the size of the whole document.

- **`:SimpleMarkdownHealth` reports the two facts it was missing.** It said
  which protocol the plugin speaks and stopped there, so a mismatch showed as
  `[ERROR]` with no second number and no remedy; it now names both versions and
  what to run. It also compares the installed binary against the `src/` beside
  it and warns when the binary is older, which is what a plugin manager leaves
  behind every time it updates the Vim files.

- **The version-skew message is where you can see it.** A plugin updated
  without its backend rebuilt now explains itself in the preview window instead
  of leaving a blank one behind an `echom` that the next redraw eats, and a
  manual `:SimpleMarkdownRefresh` can no longer talk past the check and paint
  rows laid out to a protocol this plugin cannot read. `tests/vim_protocol.vim`
  / `make test-protocol` covers the branch, which had none.

- **Link following that works on all three href shapes.** A bare `#anchor` and
  the `#section` half of `other.md#section` were both documented and neither
  had ever worked: the first was parsed as a file named `#anchor`, the second
  was parsed and then dropped. Anchors now resolve against GitHub's heading
  slug — the daemon sends one per table-of-contents entry, including the
  `-1`/`-2` numbering for a heading that repeats — with the old prose match
  kept as a fallback, so nothing that resolved before stops resolving.
  `:SimpleMarkdownFollow` and `<Plug>(simplemarkdown-follow)` follow a link
  from the Markdown source buffer too, finding it by pattern (inline,
  reference, autolink, bare URL) rather than by asking the daemon, so no
  preview window need be open. New `tests/vim_links.vim` / `make test-links`
  covers every shape from both sides; there was no link test at all before.

- **Global preview close.** `:SimpleMarkdownClose!` closes every in-Vim
  preview session without switching tabs or windows. It snapshots session
  identities before closing, so `WinClosed`/user callbacks cannot make it
  remove a newly-created replacement session.

- **Interactive tasks.** `x` on a real task row in the Vim preview toggles
  its `[ ]` / `[x]` marker in the Markdown source and re-renders immediately;
  `:SimpleMarkdownToggleTask` does the same from either window. Generated
  progress rows cannot accidentally toggle the last task above them. The row
  map is bound to the source `changedtick` and render generation: a stale
  preview action fails closed and refreshes, and every tab session showing the
  same source buffer is refreshed together.
- **Incremental renders** (protocol v2).  The daemon remembers the rows it last
  sent for a preview window and answers with the splice that turns them into
  the new ones, found by trimming the common prefix and suffix.  A keystroke in
  a 4700-row document now moves one row over the wire instead of 4700, and Vim
  repaints one row's text properties instead of all of them.  The reply's row
  count is a checksum: a buffer that disagrees with it asks for a whole
  document rather than redrawing something already wrong.
  `g:simplemarkdown_incremental` turns it off; `:SimpleMarkdownHealth` reports
  how many renders went each way.
- **External browser preview**, served by [omd](https://github.com/ptrglbvc/omd)
  and alongside the in-Vim one rather than instead of it:
  `:SimpleMarkdownExternal`, `…Open`, `…Close[!]` and `…Static`.  One server per
  source buffer, each finding its own free port, all stopped when Vim exits or
  the buffer is wiped.  omd is a binary you install yourself
  (`cargo install omd`) and nothing about it is linked into the daemon.
- **Current-block highlighting.**  The daemon indexes every top-level block by
  its rendered extent and the source lines it came from, so the preview washes
  the whole block the source cursor is in rather than marking one row with
  `cursorline`.  `g:simplemarkdown_focus_block`, `SimpleMarkdownFocusBlock`.
- **Code-block line numbers** (`g:simplemarkdown_code_numbers`).  The gutter
  comes out of the code's columns rather than widening the frame.
- **Table zebra striping** (`g:simplemarkdown_table_zebra`).  A row whose cells
  wrapped onto three lines is one stripe, not three.
- **Task-list progress.**  A list of two or more checkboxes is closed with
  `2/5 done` at its own indent (`g:simplemarkdown_task_progress`).
- **Link hints.**  Moving through the preview echoes the target of the link
  under the cursor, which answers "where does this go" without `show_urls`
  spending a row on every URL (`g:simplemarkdown_link_hint`).

### Fixed

- **The plugin and its supervisor no longer count request ids separately.** Both
  end up as keys in one pending table, and the plugin started at 1 — colliding
  with the handshake the supervisor already had in flight at exactly the moment
  a preview opens. The `pong` then resolved the first render's callback and the
  render's own reply found nobody waiting. A render recovered from it (the
  echoed width did not match, so it resynchronised and asked again), which is
  why it went unnoticed for so long; a one-shot request such as a table format
  simply never arrived. Ids now come from one sequence. While it was in the way:
  a render refused by a daemon speaking another protocol used to overwrite the
  version-skew explanation in the preview window with the daemon's own
  `unknown type render`, which is true and useless.

- **`:SimpleMarkdownDebug` counts patches that were kept, not patches that were
  tried.** A patch is spliced in first and only then checked against the row
  count and the source-map checksum, and one that fails either is thrown away
  and the whole document re-fetched. `patched_renders` was incremented before
  those checks, so a session where every single insertion was rejected and
  resynchronised reported a perfect patch rate — the one number you would look
  at to find out whether protocol v3 was doing anything reported it working at
  exactly the moment it had stopped. The counters now move after validation:
  `patched_renders` means a patch that survived, and a rejected one shows up as
  the `full_renders` it really cost. The smoke suite asserts both halves for an
  insertion and a deletion above everything; asserting the patch count alone had
  left an off-by-one in the source-map splice entirely invisible, with the whole
  gate green and every insertion silently shipping a full document.

- **An indented code block no longer maps one line too far.** Every row of one
  reported the source line below the one it came from, because the mapping
  assumed an opening fence — which an indented block does not have. `<CR>` on
  the first line of such a block jumped to the second, and scroll sync drifted
  by a line through the whole block. Front matter, which does have a delimiter
  line, is unchanged.

- **Withdrawn render ids no longer accumulate.** A cancel is normally removed by
  the render it names; one that loses the race against its own reply was never
  removed at all, and a typing session issues a cancel per keystroke burst. The
  set is now bounded to the recent ids, which are the only ones still
  reachable.

- **A full session table evicts the stalest session**, not whichever one the
  hash order offered first — which could drop the window being looked at and
  keep one closed hours ago.

- **A render discarded for a stale width no longer leaves the preview behind.**
  Resizing the window while a render was in flight threw the reply away and
  stopped there, so the preview kept showing the older document until the next
  edit — and worse, the daemon had already recorded those unseen rows as what
  the client holds and computed the next patch against them. A discarded reply
  now drops the session's claim to be synchronised and re-requests; a patch that
  arrives for a session in that state is refused rather than spliced into the
  wrong rows.

### Changed

- `:SimpleMarkdownToc` with no preview open used to call the preview open —
  a table of contents is a question about the document, not a request for a
  window — and `<Plug>(simplemarkdown-next-heading)` pressed in a source buffer
  used to move a preview window's cursor and leave yours where it was. Both now
  act where they were invoked. With a preview open, nothing changes.

- `:SimpleMarkdownRefresh` and preview `r` now skip the debounce for every tab
  session showing the current source, matching automatic edit/task refreshes.
  `:SimpleMarkdownRefresh!` redraws every open preview for global option
  changes.
- `g:simplemarkdown_show_urls` now covers images as well as links.  In a
  terminal preview the source path is often the only thing that says which file
  an image is.
- Text-property groups are applied in a stable order, so a patched render and a
  full one paint identically where two classes start at the same column.
- **CI runs `make check`.** It used to hand-list a subset of the Makefile's
  targets, and that list had drifted: it asserted `"protocol_version":1` while
  the daemon has emitted 2 since the incremental-render work, so every push
  failed at the handshake step — before the Vim suites, the class-list check or
  `:defcompile` ever ran, and it never ran `core-verify` at all. The MSRV job's
  toolchain is now read out of `Cargo.toml` instead of being written down a
  second time. New `make check-protocol` asserts that `protocol.rs`,
  `autoload/simplemarkdown.vim` and the running daemon's handshake all state
  the same version; nothing in the gate hardcodes a version number any more.
- `<CR>` in the preview now resolves a link exactly as `gx` does.  It asked for
  the row's link and then re-tested that the cursor was inside it, discarding
  the row fallback that lookup exists to provide, so the two keys disagreed
  about the same row.

### Performance

Measured on a 4700-row document of prose and distinct Rust code blocks, one
full render per simulated keystroke:

| | before | after |
|---|---|---|
| first render | 411 ms | 214 ms |
| subsequent renders | 364 ms | 2 ms |
| round trip, Vim's side included | ~375 ms | ~4 ms |

- **Scope classification no longer allocates.**  Mapping a syntect scope to a
  highlight class went through `Scope::build_string()` — which takes a global
  mutex and builds a `String` — and then prefix-matched it with a `format!` per
  candidate: tens of allocations and a lock per token.  The prefixes are now
  interned once and compared with syntect's bitwise `is_prefix_of`.
- **Fenced blocks are memoised on their content.**  Editing a paragraph used to
  re-run syntect over every code block in the file.  Highlighting is by far the
  most expensive thing in a render and almost never what changed.
- A render whose answer a newer render has already superseded is now dropped
  rather than sent.

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
