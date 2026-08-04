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
Vim's job is a buffer replace and one `prop_add_list()` call per property
class.

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
:SimpleMarkdownFocus     " jump into it
:SimpleMarkdownToc       " headings, in a popup
:SimpleMarkdownStyle ascii
:SimpleMarkdownHealth
```

Inside the preview: `q` close, `r` re-render, `<CR>` follow a link or jump to
the source line this row came from, `gx` open a link, `gO` contents, `]]`/`[[`
next and previous heading.

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
| `g:simplemarkdown_show_urls` | `0` | show link targets after their text |
| `g:simplemarkdown_sync_scroll` | `1` | preview follows the source cursor |
| `g:simplemarkdown_sync_back` | `0` | source follows the preview cursor too |
| `g:simplemarkdown_auto_open` | `0` | open a preview for every Markdown buffer |

`:help simplemarkdown` documents the rest, including every highlight group.

**If tables and code frames look misaligned**, your terminal is treating East
Asian Ambiguous width characters as double width — box-drawing lives in that
category. Set `g:simplemarkdown_style = 'ascii'`, or configure the terminal to
treat them as single width.

## Develop

```sh
make test          # fmt, clippy, Rust tests, daemon protocol, Vim suites
make preview       # render the fixture to the terminal; WIDTH=100 to change
make check-classes # prove the Rust and Vim text-property class lists agree
```

`make preview` is the fastest way to review a layout change: the diff of two
runs is the whole review.

The daemon is usable on its own:

```sh
./target/release/simplemarkdown-daemon --preview README.md 100
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
