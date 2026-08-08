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
contents are moved but never reflowed, so the change is whitespace only. Which
lines are the table comes from the parser: a `|` inside a fenced code block is
not a table row.

`:SimpleMarkdownLint` puts what is wrong with the document in the location
list: a `#anchor` that matches no heading, a footnote referred to but never
defined (or defined and never referred to), a table row with the wrong number
of cells, a link with no destination, a skipped heading level. Only checks a
parser can be certain about — nothing about trailing spaces, and nothing inside
a fenced code block, so a `# comment` in a shell sample is not a heading.
`simplemarkdown-daemon --codes` lists the set; `make check-codes` proves the
help documents all of it. Set `g:simplemarkdown_lint_on_write` to check on
every save, silently.

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
beside it rather than instead of it, served by
[omd](https://github.com/ptrglbvc/omd):

```sh
cargo install omd
```

```vim
:SimpleMarkdownExternal        " toggle a live-reloading browser preview
:SimpleMarkdownExternalStatic  " render once to a temp file, no server
:SimpleMarkdownExternalClose!  " stop every server
```

One server per buffer, each on its own port, all stopped when Vim exits. omd
watches the file on disk, so the browser follows `:w` — the in-Vim preview is
the one that updates as you type. Nothing about omd is linked into
`simplemarkdown-daemon`: it brings a web server, a file watcher and a clipboard
stack, none of which belong in a process whose job is laying out rows of text.

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
| `g:simplemarkdown_omd_port` | `3030` | first port the browser preview tries |

`:help simplemarkdown` documents the rest, including every highlight group.

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
make test-external  # the browser preview, against a stand-in for omd
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
