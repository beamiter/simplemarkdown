# simplemarkdown

Markdown preview inside Vim, laid out by a Rust daemon.

No browser, no HTTP server, no external viewer — the preview is an ordinary
Vim buffer, so it works over SSH, inside tmux, and in whatever terminal you
already have. The cursor in the source and the cursor in the preview stay
together.

```
┌ README.md ─────────────────────┬ [SimpleMarkdown] README.md ────────────────┐
│ # simplemarkdown               │ ▌ simplemarkdown                           │
│                                │ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│ Markdown preview inside Vim,   │                                            │
│ laid out by a **Rust** daemon. │ Markdown preview inside Vim, laid out by a │
│                                │ Rust daemon.                               │
│ - no browser                   │                                            │
│ - no HTTP server               │ • no browser                               │
│                                │ • no HTTP server                           │
│ > [!NOTE]                      │                                            │
│ > Works over SSH.              │ ▏ ▸ NOTE                                   │
│                                │ ▏ Works over SSH.                          │
│ ```rust                        │                                            │
│ fn main() {}                   │ ╭─ rust ───────────────────────────────╮   │
│ ```                            │ │ fn main() {}                         │   │
│                                │ ╰──────────────────────────────────────╯   │
│ | col | value |                │                                            │
│ |-----|------:|                │ ┌─────┬───────┐                            │
│ | a   |    42 |                │ │ col │ value │                            │
│                                │ ├─────┼───────┤                            │
│                                │ │ a   │    42 │                            │
│                                │ └─────┴───────┘                            │
└────────────────────────────────┴────────────────────────────────────────────┘
```

## Why a daemon

Laying out Markdown for a terminal is more work than it looks: CommonMark
parsing, display-width-correct line breaking (CJK is two columns per glyph,
and a Chinese paragraph has no spaces to break at), table column fitting,
and syntax highlighting for every fenced code block. Doing that in Vim script
on every keystroke is not viable.

So it happens in Rust — [pulldown-cmark](https://github.com/pulldown-cmark/pulldown-cmark)
for parsing, [unicode-width](https://github.com/unicode-rs/unicode-width) for
measuring, [syntect](https://github.com/trishume/syntect) for code — and the
daemon hands Vim finished rows plus the text-property spans to paint on them.
Vim's job is a buffer splice and one `prop_add_list()` call per property class.

And mostly it hands over almost nothing. The daemon remembers the rows it last
sent for a window and replies with the splice that turns them into the new
ones, found by trimming the common prefix and then the common suffix — which is
the shape of an edit, because typing in a paragraph reflows that paragraph and
leaves everything above and below it byte-identical. Rows are compared on how
they *look*, so pressing Enter — which moves every row below it in the
row-to-source map and nothing on screen — is a splice plus one number, not a
new document. Fenced blocks are memoised on their content for the same reason:
syntax highlighting is the most expensive thing in a render and almost never
what changed. On a 4700-row document of prose and code, a keystroke costs 2 ms
in the daemon and moves one row over the wire.

## Install

With [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'beamiter/simplemarkdown', {'do': './install.sh'}
```

Then build the backend once:

```sh
cd ~/.vim/plugged/simplemarkdown
./install.sh          # install.ps1 on Windows
```

Requires Vim 9.0 with `+job`, `+channel` and `+textprop`, and Rust 1.88 to
build. `install.sh` builds with `--locked`, runs the binary's `--self-test`,
and only then moves it into `lib/` — a build whose renderer cannot lay out its
own documentation never replaces a working one.

## Use

```vim
:SimpleMarkdown          " toggle the preview       (also <leader>md)
:SimpleMarkdownClose!    " close previews in every tab
:SimpleMarkdownRefresh   " refresh every tab showing this document
:SimpleMarkdownRefresh!  " refresh every open preview
:SimpleMarkdownFocus     " jump into it
:SimpleMarkdownToc       " headings, in a popup
:SimpleMarkdownToggleTask " toggle the task under either cursor
:SimpleMarkdownFollow    " follow the link under the cursor, source side too
:SimpleMarkdownFormatTable " realign the table the cursor is in
:SimpleMarkdownDemote    " this section one heading level deeper (also Promote)
:SimpleMarkdownRenumber  " renumber the ordered list the cursor is in
:SimpleMarkdownLint      " what is wrong with this document, in the loclist
:SimpleMarkdownStyle ascii
:SimpleMarkdownHealth
```

Inside the preview: `q` close, `r` re-render, `x` check/uncheck a task, `<CR>`
follow a link or jump to the source line this row came from, `gx` open a link,
`gO` contents, `]]`/`[[` next and previous heading, `g?` the list of keys
actually in force. Each is a `<Plug>` you can move or drop on its own with
`g:simplemarkdown_preview_mappings` — `{'toggle-task': ''}` keeps everything
but `x`.

Task toggling edits the Markdown source buffer immediately and works on
nested/quoted task lists too. A preview only edits through a map for the exact
source revision it rendered; if the source changed in the meantime, `x` refuses
the stale action and refreshes. When several tabs preview the same buffer,
edits refresh all of their sessions together.

`:SimpleMarkdownFormatTable` realigns the GFM table the cursor is in, in the
source buffer. Columns are padded to their widest cell in *display* columns —
measured by the daemon, with the same `unicode-width` tables the preview is
laid out with, so a table of CJK cells lines up in the file and not merely in
the terminal that formatted it. The delimiter row is rebuilt from the
alignments it declares, a short row is padded rather than truncated, and cell
contents are moved but never reflowed or deleted, so the table goes on saying
what it said. That is not the same as a whitespace-only change and `git diff -w`
of a run is not reliably empty — a table written without outer pipes gains them,
a short row gains the `|` it was missing, and the delimiter row's dashes are
re-run to the new widths. The number of columns is the delimiter row's to
declare and is left alone too: a row carrying a cell past the last one keeps it
on the end, unpadded, because widening the table would make a cell GFM was
already dropping start rendering.
Which lines are the table comes from the parser: a `|` inside a fenced code
block is not a table row.

`:SimpleMarkdownPromote` and `:SimpleMarkdownDemote` move heading levels, and
`:SimpleMarkdownRenumber` renumbers ordered lists. The usual way to do the
first is `:%s/^#/##/`, which promotes the comments in every fenced shell block,
misses every setext heading, and leaves a chapter's subsections behind when it
takes the chapter down a level. With no range these take the whole section the
cursor is in — heading and everything nested under it — so the tree still says
what it said; with a range, exactly the headings inside it. Going past H1 or H6
is refused whole and names the heading. Renumbering starts from the number the
list declares, keeps `.` versus `)`, numbers nested lists on their own, and
leaves the `1.` in a code sample alone. Each is one undo step, and only the
lines that change are written.

`:SimpleMarkdownLint` puts what is wrong with the document in the location
list: a `#anchor` that matches no heading, a footnote referred to but never
defined (or defined and never referred to), a table row with the wrong number
of cells, a link with no destination, a skipped heading level. Only checks a
parser can be certain about — nothing about trailing spaces, and nothing inside
a fenced code block, so a `# comment` in a shell sample is not a heading.
`simplemarkdown-daemon --codes` lists the set; `make check-codes` proves the
help documents all of it. Set `g:simplemarkdown_lint_on_write` to check on
every save, silently.

`:SimpleMarkdownToc` lists the headings in a popup and jumps to the one you
pick. With no preview open it asks the daemon for just the outline instead of
splitting the window and starting a render — asking what is in a document
should not open one. `]]`/`[[` move between headings in the source buffer too.

Set `g:simplemarkdown_folding` to fold the source by heading, with the fold
levels coming from the same parse. Every Markdown foldexpr in the wild is a
pattern over `^#` and every one of them folds the comments in a fenced shell
block; this one knows the difference. The levels are refreshed in the
background after an edit, and a refresh landing leaves the folds you opened or
closed by hand as you left them.

Links resolve to GitHub's heading slugs, so `#notes-part-one` finds
`## Notes: part one!` and `#notes-1` finds the second `## Notes`;
`other.md#section` opens the file and moves to that section. Following works
from the source buffer too, with no preview open — bind it to `gf` if you like:

```vim
autocmd FileType markdown nmap <buffer> gf <Plug>(simplemarkdown-follow)
```

Manual refresh follows the same document scope: `:SimpleMarkdownRefresh`
skips the debounce for every tab showing the current source. Use
`:SimpleMarkdownRefresh!` to redraw all open previews after changing a global
render option from Vimscript.

`:SimpleMarkdownClose` closes this tab's preview. Its bang form closes every
in-Vim preview session without switching to their tabs; browser preview
servers remain independently controlled by `:SimpleMarkdownExternalClose[!]`.

## Also in a browser

The terminal preview is for reading and navigating a document while you write
it. Some things a terminal cannot do at all — images that are images, LaTeX
that is typeset, proportional type — so there is a second preview that runs
beside it rather than instead of it, served by the daemon you are already
running. Nothing else to install:

```vim
:SimpleMarkdownExternal        " toggle a live browser preview of this buffer
:SimpleMarkdownExternalStatic  " write one self-contained HTML file, no server
:SimpleMarkdownExternalClose!  " stop every server
```

The page follows the **buffer**, not the file: it updates as you type, scrolls
to the block the cursor is in and washes it, and serves images from the
document's directory and nowhere else. It is styled for reading a long
document — a measured text column, CJK and Latin on the same baseline, GitHub's
palette in light *and* dark following the system setting, a real syntax theme
in fenced blocks, the five alert callouts, copy buttons, a contents rail. One
server per buffer, each on its own port, all stopped when Vim exits.

This used to be [omd](https://github.com/ptrglbvc/omd), and stopped being it
for a reason worth stating: omd's stylesheet is `include_str!`d into its
binary, so the entire appearance of this plugin's browser preview belonged to
another project. A preview you cannot restyle is not a preview you own. The
replacement costs one tokio feature (`net`) — and the three crates tokio brings
with it for sockets — rather than a web framework, a file watcher and a
clipboard stack.

## In a remote workspace

[simpleremote](https://github.com/beamiter/simpleremote) opens SSH and Docker
workspaces in Vim. Previewing a document in one needs no configuration, and
none of it requires simpleremote to be installed — every hook is
feature-detected and inert when nothing fires it.

Its projected modes (sshfs, docker-bind, local-map) open ordinary local files,
so there is nothing to say about them. Virtual mode opens `remote:///abs/path`
buffers with `'buftype'` `acwrite`, and those are documents here: the preview,
auto-open, folding, the outline, the linter and the authoring commands all
work on one, and `User SimpleRemoteBufferRead` is what makes text that arrived
from a channel callback reach the preview — a callback's `setbufline()` fires
no `TextChanged`. Nothing is rendered on the remote host; the daemon is fed
`getbufline()`, never a path.

Two things needed more than that. A link written in a remote document is
resolved against the **remote** path and opened as another `remote://` buffer,
with the `#anchor` jump owed until the text arrives. And the browser preview
serves the directory the document is in — which is on another host — so every
picture the document refers to is downloaded into a staging directory laid out
as the URLs the browser will ask for, and the daemon is pointed at that. The
page is told what to call the document as well, since the path it was handed
is a copy in that staging directory and says nothing about which host it came
from. `:help simplemarkdown-remote` has the caps, the clamping rule and what
happens without a connection.

## What it renders

CommonMark plus the GitHub extensions that come up in practice — tables with
per-column alignment, task lists, footnotes, strikethrough, alerts
(`> [!WARNING]`), definition lists, and YAML/TOML front matter. Headings get
rules, quotes get bars that survive wrapping and nesting, ordered markers are
right-aligned so `9.` and `10.` share a text column, and table columns that do
not all fit shrink in proportion to what they asked for rather than uniformly.

Code inside a fence is highlighted with sixteen coarse classes mapped from
syntect's scopes onto the highlight groups your colour scheme already
defines — `Keyword`, `String`, `Comment` and so on. Shipping syntect's own
themes would mean emitting RGB, which looks wrong against every terminal
palette the theme was not authored for.

## Configure

Everything has a working default; these are the ones worth knowing about.

| Variable | Default | |
|---|---|---|
| `g:simplemarkdown_width` | `0` | preview columns; 0 means half the window |
| `g:simplemarkdown_max_text_width` | `0` | cap the text column independently of the window |
| `g:simplemarkdown_side` | `'right'` | `'left'` or `'right'` |
| `g:simplemarkdown_debounce` | `120` | ms after the last change before re-rendering |
| `g:simplemarkdown_style` | `'unicode'` | `'ascii'` for terminals that draw box-drawing double-wide |
| `g:simplemarkdown_syntax` | `1` | highlight fenced code |
| `g:simplemarkdown_show_urls` | `0` | show link and image targets after their text |
| `g:simplemarkdown_link_hint` | `1` | echo the target of the link under the cursor |
| `g:simplemarkdown_code_numbers` | `0` | number lines inside fenced code blocks |
| `g:simplemarkdown_table_zebra` | `0` | tint every other table body row |
| `g:simplemarkdown_task_progress` | `1` | close a task list with `2/5 done` |
| `g:simplemarkdown_focus_block` | `1` | wash the whole block the source cursor is in |
| `g:simplemarkdown_sync_scroll` | `1` | preview follows the source cursor |
| `g:simplemarkdown_sync_back` | `0` | source follows the preview cursor too |
| `g:simplemarkdown_auto_open` | `0` | open a preview for every Markdown buffer |
| `g:simplemarkdown_browser_port` | `3030` | first port the browser preview tries |
| `g:simplemarkdown_browser_theme` | `'auto'` | browser preview: `auto`/`light`/`dark` |
| `g:simplemarkdown_browser_live` | `1` | browser preview follows the buffer, not `:w` |

`:help simplemarkdown` documents the rest, including every highlight group.

**An option that does not hold what it says it holds is corrected, and said out
loud.** Numbers are clamped into their range, anything else falls back to the
documented default, and an entry of the wrong type is dropped from a list —
when the plugin loads, and again on every read, so a `:let` from a later
`:source`, a modeline or a `FileType` autocommand is covered too. Refusing
instead would mean a preview that quietly stops updating: the render options
are serialised into JSON the daemon deserialises into typed fields.

`:SimpleMarkdownHealth` lists whatever had to be corrected, and the first
render of a session says the same list once. That includes the corrections
made at load, which `:echo g:simplemarkdown_style` can no longer show you,
because the variable was rewritten with the corrected value. A
`g:simplemarkdown_` variable that is not an option at all is reported too, named
alongside the option it is closest to when one is close enough to be a slip — a
misspelt option name is otherwise perfectly silent, because nothing reads it.

**If tables and code frames look misaligned**, your terminal is treating East
Asian Ambiguous width characters as double width — box-drawing lives in that
category. Set `g:simplemarkdown_style = 'ascii'`, or configure the terminal to
treat them as single width.

## Develop

```sh
make check          # the gate: fmt, clippy, Rust tests, daemon, Vim suites
make test           # the Rust tests alone
make preview        # render the fixture to the terminal; WIDTH=100 to change
make bench          # first render, steady state, and the size of one edit
make check-protocol # Rust, Vim and the handshake agree on the protocol version
make check-classes  # prove the Rust and Vim text-property class lists agree
make test-links     # link following, from the preview and from the source
make test-protocol  # what a plugin updated without its daemon rebuilt does
make test-external  # the browser preview: serving, updating and teardown
```

CI runs `make check` and nothing else, so the Makefile is the only place the
gate is described.

`make preview` is the fastest way to review a layout change: the diff of two
runs is the whole review.

The daemon is usable on its own:

```sh
./target/release/simplemarkdown-daemon --preview README.md 100
./target/release/simplemarkdown-daemon --bench README.md 100
./target/release/simplemarkdown-daemon --classes
echo '{"type":"ping","id":1}' | ./target/release/simplemarkdown-daemon
```

## Part of the simple\* suite

`simplemarkdown` shares its daemon supervisor with
[simplefinder](https://github.com/beamiter/simplefinder),
[simpletree](https://github.com/beamiter/simpletree),
[simplegit](https://github.com/beamiter/simplegit) and the rest — a vendored
`autoload/simplemarkdown/core.vim` that owns process lifetime, restart backoff,
the crash-loop breaker and request/reply correlation. Each plugin carries a
byte-identical copy so none of them depends on a sibling being installed.

## Licence

MIT.
