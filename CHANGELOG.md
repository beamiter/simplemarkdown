# Changelog

All notable changes to this project are documented here.  The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### 浏览器预览:自己渲染,自己伺服

- **浏览器预览不再依赖 `omd`。** daemon 现在自己把文档渲染成 HTML,自己用
  一个手写的 HTTP/1.1 循环伺服它,更新经 SSE 推给页面。装机不再需要
  `cargo install omd`;`g:simplemarkdown_omd_*` 六个选项换成
  `g:simplemarkdown_browser_*`。

  换掉它的理由值得写下来:omd 的样式表是 `include_str!` 进它二进制的,于是本
  插件浏览器预览的全部外观——字体、配色、跟不跟随系统的亮/暗——都是另一个项目
  替我们做的决定,而且改不了。**改不了外观的预览不算自己的预览。**代价是
  tokio 多一个 `net` feature(连带 mio / socket2 / libc 三个传递依赖),
  没有新的直接依赖,也没有 web 框架。

- **页面跟的是 buffer,不是文件。** omd 用 notify(7) 看磁盘上的文件,所以只能
  跟着 `:w` 刷新;现在送过去的是 Vim 里的文本,按 `g:simplemarkdown_debounce`
  去抖,边打边变,连没保存的改动也看得到。`g:simplemarkdown_browser_live` 置 0
  可以退回旧行为。没存过盘的 buffer 也能预览,只要它有名字——目录用来解析
  `![](./diagram.png)`,文件名用来当标签页标题。

- **两个光标连着走。** 源文件里移动光标,页面滚到对应的块并短暂高亮它,和两个
  Vim 窗口之间的联动是同一套语义(`g:simplemarkdown_browser_sync`)。
  `g:simplemarkdown_browser_sync_back` 打开反向:读页面时滚动,源文件光标跟着走。

- **页面本身。** 一列有节制的正文宽度、中英文同基线的字体栈、GitHub 的亮/暗两套
  配色(默认 `auto`,跟随系统,页面角上的按钮可以覆盖并记住)、fenced block 里
  真正的语法配色(仍然是 syntect 解析、CSS 上色,和终端预览同一套 class)、
  GitHub 的五种 alert、可滚动的表格与代码块、复制按钮、目录侧栏、`t`/`f`/`d`
  三个快捷键。数学用 KaTeX(`g:simplemarkdown_browser_math`),这是页面上唯一
  一处外部资源,加载不到时公式以源码形式留在页面上而不是消失。

- **`:SimpleMarkdownExternalStatic` 现在写的是一份自包含的 HTML**:样式表在文件
  里,没有服务器,也没有会一直重连的事件流。搬走、寄给别人、明年再打开都还是
  它本来的样子。

- 相对路径引用的图片等文件由服务器从文档所在目录提供,且只从那里提供:URL 里的
  `../` 一律拒绝(词法与 canonicalize 两道,后者才拦得住软链接)——
  `g:simplemarkdown_browser_host` 是可以被设成 `0.0.0.0` 的。同理,只有地址字面量
  和 `localhost` 会被当作合法 `Host` 应答:DNS rebinding 需要一个*名字*,而这个
  服务器不认名字。

- 协议升到 v4。插件更新后需要 `./install.sh` 重新构建 daemon,否则
  `:SimpleMarkdownHealth` 会直说 "this daemon cannot serve"。

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

- **A `g:` option that does not hold what it says it holds is corrected, and
  said out loud.** Every option now lives in one table — its type, its range,
  its default — instead of a normalising expression in `plugin/` and a
  `get(g:, ..., fallback)` at every point of use, which is two answers to the
  same question and no answer at all for a value set after load. There were two
  holes. A `:let` from a later `:source`, a modeline or a `FileType`
  autocommand was never normalised at all, and the render options go straight
  into JSON the daemon deserialises into typed fields: a `'4'` where a 4 was
  meant was a rejected request and, from where the user sits, a preview that
  stops updating with the reason in a log nobody opens. And a value corrected
  at load was corrected *in place* — `g:simplemarkdown_style` reads back
  `'unicode'` whatever you wrote there, so a setting that does not work looked
  exactly like a setting that does. Now every read goes through
  `simplemarkdown#Setting()`, so a wrong value costs a fallback rather than the
  preview; `:SimpleMarkdownHealth` lists everything that had to be corrected,
  the load-time corrections included; and the first use of the backend in a
  session says the same list once — not at load, where a message is scrolled
  away by whatever loads next, and not on every render, which is the other way
  to make a warning invisible. A `g:simplemarkdown_` variable that is not an
  option at all is reported, named alongside the option it is closest to when
  one is close enough to be a slip: `g:simplemarkdown_stlye` is otherwise
  perfectly silent, because nothing reads it. New `simplemarkdown#Setting()`,
  `simplemarkdown#ValidateConfig()` and
  `simplemarkdown#SettingNames()`; new `make test-config`, which also holds the
  table against the `*g:simplemarkdown_*` tags in the help — an option
  documented and not implemented is this suite's oldest recurring defect — and
  `make check-settings`, which catches a *caller* asking for a name the table
  does not declare, since that name is a string no `:defcompile` can check.

- **`:SimpleMarkdownPromote`, `:SimpleMarkdownDemote` and
  `:SimpleMarkdownRenumber` restructure the source.** Shifting heading levels is
  the most common structural edit there is, and the received way to do it is
  `:%s/^#/##/` — which turns the comments of every fenced shell block into
  headings, misses every setext heading (an `====` underline makes a heading of
  a line with no `#` on it at all), and takes a chapter one level down while
  leaving its subsections where they were. All three are parsing questions, and
  the parser is already running. With no range the whole section the cursor is
  in moves — heading and everything nested under it — so the tree the document
  describes still says what it said; with a range, exactly the headings inside
  it. A setext heading keeps its form where it can, its underline switching
  between `=` and `-`, and becomes an ATX heading below H2 because setext has no
  H3. Going past H1 or H6 is refused whole and names the heading, since half a
  shift leaves a structure nothing recorded. `renumber` renumbers the ordered
  lists the range touches from the number each declares: the `1.` `1.` `1.` GFM
  renders as 1, 2, 3 becomes what it renders as, a list starting at `5)` keeps
  both its start and its `)`, nested lists are numbered on their own, and `1.`
  in a code sample stays a code sample. Each answer is a list of replacements
  applied bottom-up, so the prose between two headings — and its marks, and its
  undo history — is left alone, and the whole edit is one `u`. New capability
  `edit`, new `<Plug>(simplemarkdown-promote)`, `(-demote)` and `(-renumber)` in
  Normal and Visual mode; a backend that predates them says so instead of
  failing obscurely.

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
  cell is padded rather than truncated, a row with one too many keeps it rather
  than the table gaining a column, and cell contents are moved but never
  reflowed: a command whose whole promise is that it changes no cell, in one
  undo step, over the table's own lines and nothing else. New capability
  `format`, new `<Plug>(simplemarkdown-format-table)`; a backend that predates
  it says so instead of failing obscurely.

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

- **The background heading refresh is debounced, and a superseded one is
  withdrawn.** With `g:simplemarkdown_folding` on, the outline behind the fold
  levels was re-requested once per `changedtick` — which is once per edit, and
  every one of those requests carries the whole document and buys a whole
  `pulldown-cmark` parse. Typing a word into a folded file sent a full copy of
  it per keystroke and left as many parses running as the typing outran the
  daemon; the render path had been debouncing exactly the same cost since it was
  written. The refresh now waits `g:simplemarkdown_debounce` after the last edit
  like a render does, and the request an edit overtakes is cancelled, which the
  daemon now honours for an outline as it already did for a render. Both halves
  are measured on the wire, in `tests/vim_outline.vim`: twenty edits with a
  foldexpr sweep after each used to be twenty requests and are one, and an edit
  that arrives while a refresh is still outstanding puts a `cancel` for it on
  the wire before the replacement.

- **`:SimpleMarkdownResize {columns}` no longer leaves the plugin complaining
  about the plugin.** The argument went straight into `g:simplemarkdown_width`
  with only the floor applied, so `:SimpleMarkdownResize 500` stored 500 in an
  option declared `0..400` — and `:SimpleMarkdownHealth`, whose whole job is to
  name real configuration mistakes, then reported that one for the rest of the
  session against a user who had never written it. The value is written through
  the same table a `vimrc` value goes through, and a number that had to be moved
  to fit — capped at the range's ceiling, or raised to
  `g:simplemarkdown_min_width` — is said out loud rather than quietly applied.
  The floor is this command's own rather than the table's, so raising one used
  to be silent even after capping stopped being: `:SimpleMarkdownResize 5` gave
  you a 30-column preview without a word.

- **The help no longer promises that `:SimpleMarkdownFormatTable` leaves an
  empty `git diff -w`.** It does not, and never did: a table written without
  outer pipes gains them, a row short of a cell gains the `|` it was missing,
  and the delimiter row's dashes are re-run to the new column widths — all three
  documented behaviours of the formatter, and none of them whitespace. What the
  command actually promises is that no cell's text changes, which is what the
  help, the README and `format.rs` now say.

- **`:SimpleMarkdownFormatTable` no longer widens a table to fit a row with a
  cell too many.** How many columns a GFM table has is declared by its delimiter
  row, and every renderer drops whatever a row carries past that. The formatter
  laid the table out to the widest row instead, so one stray `|` turned a
  two-column table into a three-column one — header rewritten, delimiter
  rewritten, and a cell the document had been hiding suddenly rendering. That is
  an edit to what the file *says*, from the one command whose entire promise is
  that it moves cells without changing any of them. The declared shape now wins;
  the surplus cell is not deleted either (a formatter that drops text is one
  nobody runs twice) but carried through unpadded on the end of its row, where
  `:SimpleMarkdownLint` goes on reporting it as the `ragged-table-row` it is.
  Before this, running the formatter on that diagnostic silenced it by changing
  the table.

- **A background outline refresh no longer opens folds you closed.** With
  `g:simplemarkdown_folding` on, the reply to an outline request has to make Vim
  ask foldexpr again — the answers changed without the buffer changing, and
  nothing else would. It did that with `zx`, which is *defined* as "undo
  manually opened and closed folds", and which ends in a `zv` that also opens
  folds around every other window's cursor on the buffer. So a section closed
  with `zc` sprang open on the next keystroke, in every window, which is the
  opposite of the "folds do not flap open" the help promised. Setting
  `'foldexpr'` to the value it already has invalidates the same cache and leaves
  manual fold state alone.

- **An outline reply that arrives late no longer sticks the folds.** The backend
  answers concurrently, so two outlines in flight can land in the other order.
  The older one was taken, which stales the heading tree — and worse, wrote back
  an older changedtick while the refresh bookkeeping was waiting on the newer
  one, so nothing ever asked again and the folds stayed wrong until the next
  edit. Replies older than what is cached are now dropped.

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

- What an authoring command says when it went well now reaches `:messages`.
  Those lines are printed from a channel callback, which is to say some time
  after the keystroke that asked for them, and a plain `echo` from there is
  painted over by the next redraw with nothing left behind — so "the table is
  already aligned" was an answer a user could receive and never see.

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
