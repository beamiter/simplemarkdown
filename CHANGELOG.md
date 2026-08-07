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

### Changed

- `:SimpleMarkdownRefresh` and preview `r` now skip the debounce for every tab
  session showing the current source, matching automatic edit/task refreshes.
  `:SimpleMarkdownRefresh!` redraws every open preview for global option
  changes.
- `g:simplemarkdown_show_urls` now covers images as well as links.  In a
  terminal preview the source path is often the only thing that says which file
  an image is.
- Text-property groups are applied in a stable order, so a patched render and a
  full one paint identically where two classes start at the same column.

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
