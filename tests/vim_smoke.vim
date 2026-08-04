" End-to-end smoke test: a real daemon, a real preview window, real text
" properties.  The Rust suite already proves the layout is right; what this
" checks is the seam — that the rows Vim receives land in the buffer, that
" every property the daemon emits has a registered type, and that the scroll
" sync maps a source line onto the row that came from it.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_smoke.vim

set nocompatible
set nomore
set shortmess+=I

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
let g:simplemarkdown_daemon_path = s:root .. '/target/debug/simplemarkdown-daemon'
if !executable(g:simplemarkdown_daemon_path)
  let g:simplemarkdown_daemon_path = s:root .. '/target/release/simplemarkdown-daemon'
endif
" Deterministic: render on demand, never on a timer we would have to race.
let g:simplemarkdown_debounce = 0
let g:simplemarkdown_auto_open = 0
runtime plugin/simplemarkdown.vim

function! s:Wait(expr, ms) abort
  let l:ticks = a:ms / 10
  let l:i = 0
  while l:i < l:ticks
    if eval(a:expr)
      return 1
    endif
    sleep 10m
    let l:i += 1
  endwhile
  return eval(a:expr)
endfunction

function! s:PreviewWin() abort
  for l:win in getwininfo()
    if getbufvar(l:win.bufnr, '&filetype') ==# 'simplemarkdown'
      return l:win.winid
    endif
  endfor
  return 0
endfunction

function! s:PreviewLines() abort
  let l:winid = s:PreviewWin()
  return l:winid ? getbufline(winbufnr(l:winid), 1, '$') : []
endfunction

" ------------------------------------------------------------------ setup ---

call assert_true(executable(g:simplemarkdown_daemon_path),
      \ 'the daemon is built: run `cargo build` first')

let s:doc = tempname() .. '.md'
call writefile([
      \ '# Title',
      \ '',
      \ 'A paragraph with **bold** text and a [link](https://example.com).',
      \ '',
      \ '## Second heading',
      \ '',
      \ '- alpha',
      \ '- beta',
      \ '',
      \ '```rust',
      \ 'fn main() {}',
      \ '```',
      \ '',
      \ '| a | b |',
      \ '|---|---|',
      \ '| 1 | 2 |',
      \ ], s:doc)
execute 'edit ' .. fnameescape(s:doc)
setlocal filetype=markdown
let s:src_win = win_getid()

" --------------------------------------------------------------- commands ---

for s:name in ['SimpleMarkdown', 'SimpleMarkdownOpen', 'SimpleMarkdownClose',
      \ 'SimpleMarkdownRefresh', 'SimpleMarkdownFocus', 'SimpleMarkdownToc',
      \ 'SimpleMarkdownRestart', 'SimpleMarkdownHealth', 'SimpleMarkdownLog',
      \ 'SimpleMarkdownDebug', 'SimpleMarkdownResize', 'SimpleMarkdownStyle']
  call assert_equal(2, exists(':' .. s:name), s:name .. ' is defined')
endfor

" ------------------------------------------------------------- open/render ---

SimpleMarkdownOpen
call assert_true(s:PreviewWin() > 0, 'the preview window opens')
call assert_true(s:Wait('simplemarkdown#core#Ready()', 5000),
      \ 'the daemon completes its handshake')
call assert_equal(1, simplemarkdown#core#Protocol(), 'protocol v1 is negotiated')
call assert_true(simplemarkdown#core#HasCap('render'), 'the render capability is advertised')

SimpleMarkdownRefresh
call assert_true(s:Wait('index(s:PreviewLines(), "▌ Title") >= 0', 5000),
      \ 'the heading is rendered: ' .. string(s:PreviewLines()))

let s:lines = s:PreviewLines()
let s:joined = join(s:lines, "\n")
call assert_true(s:joined =~# '▌ Title', 'the H1 marker is drawn')
call assert_true(s:joined =~# '━━━', 'the H1 rule is drawn')
call assert_true(s:joined =~# '• alpha', 'list bullets are drawn')
call assert_true(s:joined =~# '╭─ rust', 'the code fence is boxed and labelled')
call assert_true(s:joined =~# '┌─', 'the table is boxed')

" The preview must be a scratch buffer the user cannot corrupt.
let s:pbuf = winbufnr(s:PreviewWin())
call assert_false(getbufvar(s:pbuf, '&modifiable'), 'the preview is not modifiable')
call assert_equal('nofile', getbufvar(s:pbuf, '&buftype'))

" ----------------------------------------------------------- text properties ---

" Every property in the buffer must carry a registered type whose name matches
" the daemon's class list; an unregistered one would have thrown during the
" render and left the buffer half-highlighted.
let s:seen = {}
for s:lnum in range(1, len(s:lines))
  for s:prop in prop_list(s:lnum, {'bufnr': s:pbuf})
    let s:seen[s:prop.type] = 1
    call assert_true(!empty(prop_type_get(s:prop.type)),
          \ s:prop.type .. ' is a registered property type')
    call assert_true(s:prop.col >= 1, 'property columns are 1-based')
    call assert_true(s:prop.col + s:prop.length - 1 <= len(s:lines[s:lnum - 1]) + 1,
          \ 'property ' .. string(s:prop) .. ' stays inside row ' .. s:lnum)
  endfor
endfor
call assert_true(has_key(s:seen, 'simplemarkdown:H1'), 'the H1 property is applied')
call assert_true(has_key(s:seen, 'simplemarkdown:Bold'), 'the Bold property is applied')
call assert_true(has_key(s:seen, 'simplemarkdown:Link'), 'the Link property is applied')
call assert_true(has_key(s:seen, 'simplemarkdown:SynKeyword'),
      \ 'code inside the fence is syntax highlighted')
call assert_true(has_key(s:seen, 'simplemarkdown:TableBorder'), 'the table border is highlighted')

" Property types and highlight groups must agree with the declared class list.
for s:class in simplemarkdown#Classes()
  call assert_true(!empty(prop_type_get('simplemarkdown:' .. s:class)),
        \ s:class .. ' has a property type')
  call assert_true(hlexists('SimpleMarkdown' .. s:class),
        \ 'SimpleMarkdown' .. s:class .. ' is a defined highlight group')
endfor

" ------------------------------------------------------------- scroll sync ---

" Putting the source cursor on the fenced block must move the preview cursor
" onto the row that block produced, not merely somewhere nearby.
call win_gotoid(s:src_win)
call cursor(11, 1)
doautocmd CursorMoved
let s:prow = line('.', s:PreviewWin())
call assert_true(s:prow > 0, 'the preview cursor moved')
call assert_true(getbufline(s:pbuf, s:prow)[0] =~# 'fn main',
      \ 'the source cursor maps onto the row it produced, got: '
      \ .. string(getbufline(s:pbuf, s:prow)))

" ------------------------------------------------------------------- style ---

SimpleMarkdownStyle ascii
call assert_true(s:Wait('join(s:PreviewLines(), "") =~# "^# Title"', 5000),
      \ 'ascii style falls back to ASCII decorations: ' .. string(s:PreviewLines()))
for s:line in s:PreviewLines()
  call assert_true(s:line =~# '^[\x00-\x7F]*$', 'ascii style emits no wide glyphs: ' .. s:line)
endfor
SimpleMarkdownStyle unicode
call assert_true(s:Wait('index(s:PreviewLines(), "▌ Title") >= 0', 5000),
      \ 'the unicode style comes back')

" No argument cycles, which is what makes the command worth a single key.
SimpleMarkdownStyle
call assert_equal('ascii', g:simplemarkdown_style, 'a bare :SimpleMarkdownStyle cycles')
SimpleMarkdownStyle
call assert_equal('unicode', g:simplemarkdown_style, 'and cycles back')
call assert_true(s:Wait('index(s:PreviewLines(), "▌ Title") >= 0', 5000),
      \ 'cycling re-renders')

" ---------------------------------------------------------------- re-render ---

" An edit must reach the preview without the window scrolling back to the top
" or the buffer being left modifiable.
call win_gotoid(s:src_win)
call append(line('$'), ['', '### Appended heading'])
call simplemarkdown#Refresh()
call assert_true(s:Wait('join(s:PreviewLines(), "\n") =~# "Appended heading"', 5000),
      \ 'an edit re-renders')
call assert_false(getbufvar(s:pbuf, '&modifiable'), 'the preview stays read-only after a re-render')

" ----------------------------------------------------------------- teardown ---

SimpleMarkdownClose
call assert_equal(0, s:PreviewWin(), 'closing removes the preview window')

" Reopening after a close must work: the session bookkeeping has to be clean.
SimpleMarkdownOpen
call assert_true(s:PreviewWin() > 0, 'the preview reopens')
call assert_true(s:Wait('index(s:PreviewLines(), "▌ Title") >= 0', 5000), 'and renders again')

" The supervisor commands must survive a full restart cycle.
SimpleMarkdownRestart
call assert_true(s:Wait('simplemarkdown#core#Ready()', 5000), 'restart brings the daemon back')
call assert_false(simplemarkdown#core#Health().breaker_open, 'the circuit breaker stayed shut')

call simplemarkdown#Stop()
call delete(s:doc)

if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  call writefile(v:errors, s:root .. '/tests/smoke-errors.log')
  cquit
endif
qall!
