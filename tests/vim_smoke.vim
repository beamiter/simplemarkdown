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
" Whichever build is newer.  Picking one by name means a stale binary silently
" tests an old renderer against a new suite, which is how a protocol bump shows
" up as a mysterious assertion failure three sections down.
let s:debug = s:root .. '/target/debug/simplemarkdown-daemon'
let s:release = s:root .. '/target/release/simplemarkdown-daemon'
let g:simplemarkdown_daemon_path =
      \ getftime(s:debug) > getftime(s:release) ? s:debug : s:release
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

function! s:PreviewWinForTab(tabnr) abort
  for l:win in getwininfo()
    if l:win.tabnr == a:tabnr
          \ && getbufvar(l:win.bufnr, '&filetype') ==# 'simplemarkdown'
      return l:win.winid
    endif
  endfor
  return 0
endfunction

function! s:PreviewLines() abort
  let l:winid = s:PreviewWin()
  return l:winid ? getbufline(winbufnr(l:winid), 1, '$') : []
endfunction

function! s:PreviewHas(winid, pattern) abort
  return a:winid > 0
        \ && join(getbufline(winbufnr(a:winid), 1, '$'), "\n") =~# a:pattern
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
      \ '- [ ] alpha',
      \ '- [x] beta',
      \ '',
      \ '```rust',
      \ 'fn main() {}',
      \ '```',
      \ '',
      \ '| a | b |',
      \ '|---|---|',
      \ '| 1 | 2 |',
      \ '| 3 | 4 |',
      \ ], s:doc)
execute 'edit ' .. fnameescape(s:doc)
setlocal filetype=markdown
let s:src_win = win_getid()

" --------------------------------------------------------------- commands ---

for s:name in ['SimpleMarkdown', 'SimpleMarkdownOpen', 'SimpleMarkdownClose',
      \ 'SimpleMarkdownRefresh', 'SimpleMarkdownFocus', 'SimpleMarkdownToc',
      \ 'SimpleMarkdownToggleTask',
      \ 'SimpleMarkdownRestart', 'SimpleMarkdownHealth', 'SimpleMarkdownLog',
      \ 'SimpleMarkdownDebug', 'SimpleMarkdownResize', 'SimpleMarkdownStyle']
  call assert_equal(2, exists(':' .. s:name), s:name .. ' is defined')
endfor

" ------------------------------------------------------------- open/render ---

SimpleMarkdownOpen
call assert_true(s:PreviewWin() > 0, 'the preview window opens')
call assert_true(s:Wait('simplemarkdown#core#Ready()', 5000),
      \ 'the daemon completes its handshake')
call assert_equal(2, simplemarkdown#core#Protocol(), 'protocol v2 is negotiated')
call assert_true(simplemarkdown#core#HasCap('render'), 'the render capability is advertised')
call assert_true(simplemarkdown#core#HasCap('incremental'),
      \ 'the daemon advertises incremental renders')

SimpleMarkdownRefresh
call assert_true(s:Wait('index(s:PreviewLines(), "▌ Title") >= 0', 5000),
      \ 'the heading is rendered: ' .. string(s:PreviewLines()))

let s:lines = s:PreviewLines()
let s:joined = join(s:lines, "\n")
call assert_true(s:joined =~# '▌ Title', 'the H1 marker is drawn')
call assert_true(s:joined =~# '━━━', 'the H1 rule is drawn')
call assert_true(s:joined =~# '☐ alpha', 'an unchecked task is drawn')
call assert_true(s:joined =~# '☑ beta', 'a checked task is drawn')
call assert_true(s:joined =~# '╭─ rust', 'the code fence is boxed and labelled')
call assert_true(s:joined =~# '┌─', 'the table is boxed')

" The preview must be a scratch buffer the user cannot corrupt.
let s:pbuf = winbufnr(s:PreviewWin())
call assert_false(getbufvar(s:pbuf, '&modifiable'), 'the preview is not modifiable')
call assert_equal('nofile', getbufvar(s:pbuf, '&buftype'))

" ----------------------------------------------------------- task toggling ---

" `x` in the preview edits the mapped Markdown checkbox, and the same command
" works from the source side too.
call win_gotoid(s:PreviewWin())
call assert_notequal('', maparg('x', 'n'), 'preview maps x to task toggling')
call search('☐ alpha')
SimpleMarkdownToggleTask
call assert_equal('- [x] alpha', getbufline(winbufnr(s:src_win), 7)[0])
call assert_true(s:Wait('join(s:PreviewLines(), "\n") =~# "☑ alpha"', 5000),
      \ 'checking a preview task re-renders it')

" Toggle it back so the rest of the fixture retains its original state.
call win_gotoid(s:src_win)
call cursor(7, 1)
SimpleMarkdownToggleTask
call assert_equal('- [ ] alpha', getline(7))
call assert_true(s:Wait('join(s:PreviewLines(), "\n") =~# "☐ alpha"', 5000),
      \ 'unchecking a source task re-renders it')

for [s:task_source, s:task_want] in [
      \ ['  - [ ] nested', '  - [x] nested'],
      \ ['2. [x] ordered', '2. [ ] ordered'],
      \ ['> - [ ] quoted', '> - [x] quoted'],
      \ ]
  call setline(7, s:task_source)
  SimpleMarkdownToggleTask
  call assert_equal(s:task_want, getline(7),
        \ 'task syntax toggles: ' .. s:task_source)
endfor
call setline(7, '- [ ] alpha')
SimpleMarkdownRefresh
call assert_true(s:Wait('join(s:PreviewLines(), "\n") =~# "☐ alpha"', 5000),
      \ 'task syntax checks restore the fixture')

call win_gotoid(s:PreviewWin())
call search('1/2 done')
let s:tasks_before = getbufline(winbufnr(s:src_win), 7, 8)
SimpleMarkdownToggleTask
call assert_equal(s:tasks_before, getbufline(winbufnr(s:src_win), 7, 8),
      \ 'the generated progress row cannot toggle a real task')

" A preview row must never edit through a map from an older source snapshot.
" Insert a task above alpha while its old preview is still on screen; blindly
" following that map would toggle the newly inserted task on row 7.
let s:race_preview = s:PreviewWin()
let s:saved_debounce = g:simplemarkdown_debounce
let g:simplemarkdown_debounce = 10000
call win_gotoid(s:src_win)
call append(6, '- [ ] inserted race')
call simplemarkdown#OnTextChanged(bufnr('%'))
call win_gotoid(s:race_preview)
call search('☐ alpha')
SimpleMarkdownToggleTask
call assert_equal(['- [ ] inserted race', '- [ ] alpha'],
      \ getbufline(winbufnr(s:src_win), 7, 8),
      \ 'a stale preview map fails closed instead of editing the wrong task')
call assert_true(execute('messages') =~# 'preview mapping is stale; refreshing',
      \ 'the stale action explains that it is refreshing')
call assert_true(s:Wait('s:PreviewHas(s:race_preview, "☐ inserted race")', 5000),
      \ 'a stale task action immediately refreshes the preview')

call win_gotoid(s:src_win)
call deletebufline('%', 7)
let g:simplemarkdown_debounce = s:saved_debounce
call simplemarkdown#OnTextChanged(bufnr('%'))
call assert_true(s:Wait('!s:PreviewHas(s:race_preview, "inserted race")', 5000),
      \ 'the edit-race fixture is removed again')

" Every tab owns a preview session, but sessions that show the same source
" buffer must move together after either an explicit task edit or TextChanged.
let s:first_tab = tabpagenr()
let s:first_preview = s:PreviewWinForTab(s:first_tab)
call win_gotoid(s:src_win)
tab split
let s:second_tab = tabpagenr()
let s:second_src_win = win_getid()
SimpleMarkdownOpen
let s:second_preview = s:PreviewWinForTab(s:second_tab)
call assert_true(s:second_preview > 0, 'a second tab opens its own preview')
call assert_true(s:Wait('s:PreviewHas(s:second_preview, "☐ alpha")', 5000),
      \ 'the second preview renders the shared source')
call assert_equal(2, simplemarkdown#DebugStatus().sessions,
      \ 'two tabs keep two preview sessions')

call win_gotoid(s:second_preview)
call search('☐ alpha')
SimpleMarkdownToggleTask
call assert_equal('- [x] alpha', getbufline(winbufnr(s:second_src_win), 7)[0])
call assert_true(s:Wait('s:PreviewHas(s:first_preview, "☑ alpha")'
      \ .. ' && s:PreviewHas(s:second_preview, "☑ alpha")', 5000),
      \ 'a task edit refreshes every tab showing the source buffer')

call win_gotoid(s:second_src_win)
let s:broadcast_original = getline(3)
call setline(3, 'A paragraph broadcast to every tab.')
call simplemarkdown#OnTextChanged(bufnr('%'))
call assert_true(s:Wait('s:PreviewHas(s:first_preview, "broadcast to every tab")'
      \ .. ' && s:PreviewHas(s:second_preview, "broadcast to every tab")', 5000),
      \ 'TextChanged refreshes every tab showing the source buffer')
call setline(3, s:broadcast_original)
call simplemarkdown#OnTextChanged(bufnr('%'))
call assert_true(s:Wait('!s:PreviewHas(s:first_preview, "broadcast to every tab")'
      \ .. ' && !s:PreviewHas(s:second_preview, "broadcast to every tab")', 5000),
      \ 'both previews return to the restored source text')

call cursor(7, 1)
SimpleMarkdownToggleTask
call assert_equal('- [ ] alpha', getline(7))
call assert_true(s:Wait('s:PreviewHas(s:first_preview, "☐ alpha")'
      \ .. ' && s:PreviewHas(s:second_preview, "☐ alpha")', 5000),
      \ 'source-side task toggling also refreshes every session')

SimpleMarkdownClose
tabclose!
call assert_equal(1, simplemarkdown#DebugStatus().sessions,
      \ 'closing the second tab leaves the original session')

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

" --------------------------------------------------------- incremental renders ---

" Everything below is about one property: an incrementally applied render must
" be indistinguishable from a full one.  A patch that lands a row off, or drops
" the properties on the rows it spliced in, would leave a preview that looks
" almost right — the worst possible failure — so each edit is applied twice and
" the two results compared.

function! s:Snapshot() abort
  let l:buf = winbufnr(s:PreviewWin())
  let l:rows = []
  for l:lnum in range(1, getbufinfo(l:buf)[0].linecount)
    let l:props = []
    for l:prop in prop_list(l:lnum, {'bufnr': l:buf})
      " id and start/end flags are bookkeeping, not appearance.
      call add(l:props, [l:prop.col, l:prop.length, l:prop.type])
    endfor
    call add(l:rows, [getbufline(l:buf, l:lnum)[0], l:props])
  endfor
  return l:rows
endfunction

" Apply the same buffer state twice — once however the daemon chooses, once
" forced to a whole document — and compare.
function! s:BothWaysAgree(what) abort
  call simplemarkdown#Refresh()
  call s:Wait('!simplemarkdown#DebugStatus().in_flight', 5000)
  sleep 50m
  let l:incremental = s:Snapshot()

  let g:simplemarkdown_incremental = 0
  call simplemarkdown#Refresh()
  call s:Wait('!simplemarkdown#DebugStatus().in_flight', 5000)
  sleep 50m
  let l:full = s:Snapshot()
  let g:simplemarkdown_incremental = 1

  call assert_equal(len(l:full), len(l:incremental),
        \ a:what .. ': the two renders have the same row count')
  for l:i in range(min([len(l:full), len(l:incremental)]))
    call assert_equal(l:full[l:i], l:incremental[l:i],
          \ printf('%s: row %d matches a full render', a:what, l:i + 1))
  endfor
endfunction

call win_gotoid(s:src_win)
let s:before_patches = simplemarkdown#DebugStatus().patched_renders

" Edit in the middle: the classic case, and the one prefix/suffix trimming is
" built for.
call setline(3, 'A paragraph with **bold** text, edited, and a [link](https://example.com).')
call s:BothWaysAgree('an edit in the middle')

" Growing the document: rows below the edit shift down, and their properties
" have to shift with them.
call append(4, ['', 'An inserted paragraph that did not exist before and is long enough to wrap.'])
call s:BothWaysAgree('an insertion')

" Shrinking it again.
call deletebufline('%', 5, 6)
call s:BothWaysAgree('a deletion')

" A change inside the fenced block: the syntax properties are the densest
" thing in the document and the easiest to lose on a splice.
call setline(11, 'fn main() { let x = 42; }')
call s:BothWaysAgree('an edit inside a code fence')

" A change at the very top, so the patch starts at row 1.
call setline(1, '# Retitled')
call s:BothWaysAgree('an edit at the first row')

call assert_true(simplemarkdown#DebugStatus().patched_renders > s:before_patches,
      \ 'renders were actually applied as patches, not silently as full ones')

" ------------------------------------------------------- the current block ---

" The source cursor inside the fenced block must wash that whole block in the
" preview, not one row of it.
call win_gotoid(s:src_win)
call cursor(11, 1)
doautocmd CursorMoved
let s:pbuf = winbufnr(s:PreviewWin())
let s:focus = []
for s:lnum in range(1, getbufinfo(s:pbuf)[0].linecount)
  for s:prop in prop_list(s:lnum, {'bufnr': s:pbuf})
    if s:prop.type ==# 'simplemarkdown:FocusBlock'
      call add(s:focus, s:lnum)
    endif
  endfor
endfor
call assert_true(len(s:focus) >= 3,
      \ 'the fenced block is washed whole (border, code, border), got rows ' .. string(s:focus))
for s:lnum in s:focus
  call assert_true(getbufline(s:pbuf, s:lnum)[0] =~# '[╭│╰]',
        \ 'row ' .. s:lnum .. ' belongs to the fence, got: '
        \ .. string(getbufline(s:pbuf, s:lnum)))
endfor

" Moving to a different block must move the wash, not add a second one.
call cursor(1, 1)
doautocmd CursorMoved
let s:moved = []
for s:lnum in range(1, getbufinfo(s:pbuf)[0].linecount)
  for s:prop in prop_list(s:lnum, {'bufnr': s:pbuf})
    if s:prop.type ==# 'simplemarkdown:FocusBlock'
      call add(s:moved, s:lnum)
    endif
  endfor
endfor
call assert_true(!empty(s:moved), 'the heading block is washed')
call assert_equal([], filter(copy(s:moved), {_, v -> index(s:focus, v) >= 0}),
      \ 'the previous block''s wash was removed')

" ------------------------------------------------------- optional decoration ---

" The line-number gutter and the zebra stripe are both off by default and both
" change the layout, so each is checked for the thing it draws and for leaving
" the box the same width.

call win_gotoid(s:src_win)
let s:plain_widths = map(copy(s:PreviewLines()), {_, v -> strdisplaywidth(v)})

let g:simplemarkdown_code_numbers = 1
call simplemarkdown#Refresh()
call assert_true(s:Wait('join(s:PreviewLines(), "\n") =~# "│ 1 fn main"', 5000),
      \ 'code lines are numbered: ' .. string(s:PreviewLines()))
call assert_equal(s:plain_widths, map(copy(s:PreviewLines()), {_, v -> strdisplaywidth(v)}),
      \ 'the gutter comes out of the code, not out of the window')

let s:pbuf = winbufnr(s:PreviewWin())
let s:numbered = 0
for s:lnum in range(1, getbufinfo(s:pbuf)[0].linecount)
  for s:prop in prop_list(s:lnum, {'bufnr': s:pbuf})
    if s:prop.type ==# 'simplemarkdown:CodeNumber'
      let s:numbered += 1
    endif
  endfor
endfor
call assert_true(s:numbered > 0, 'the numbers carry the CodeNumber property')
let g:simplemarkdown_code_numbers = 0

let g:simplemarkdown_table_zebra = 1
call simplemarkdown#Refresh()
call s:Wait('!simplemarkdown#DebugStatus().in_flight', 5000)
sleep 50m
let s:pbuf = winbufnr(s:PreviewWin())
let s:striped = 0
for s:lnum in range(1, getbufinfo(s:pbuf)[0].linecount)
  for s:prop in prop_list(s:lnum, {'bufnr': s:pbuf})
    if s:prop.type ==# 'simplemarkdown:TableRowAlt'
      let s:striped += 1
    endif
  endfor
endfor
" The fixture's table has two body rows, so exactly one of them is tinted.
call assert_equal(1, s:striped, 'one table body row is striped')
let g:simplemarkdown_table_zebra = 0
call simplemarkdown#Refresh()
call s:Wait('!simplemarkdown#DebugStatus().in_flight', 5000)

" ------------------------------------------------------ a document of nothing ---

" A buffer cannot hold zero lines, so a document that renders to no rows is one
" blank line in the preview while the daemon says it sent none.  Getting that
" disagreement wrong is not a wrong pixel: the row-count check fires, asks for a
" full render, gets the same answer, and asks again for ever.

call win_gotoid(s:src_win)
let s:saved = getline(1, '$')

silent %delete _
call setline(1, ['', '   ', ''])

" Both routes to an empty document have to settle: patched down to nothing from
" a document that had rows, and rendered whole from a session that has none.
for s:mode in [1, 0]
  let g:simplemarkdown_incremental = s:mode
  let s:before = simplemarkdown#DebugStatus().full_renders
        \ + simplemarkdown#DebugStatus().patched_renders
  call simplemarkdown#Refresh()
  call s:Wait('!simplemarkdown#DebugStatus().in_flight', 5000)
  sleep 300m

  call assert_equal([''], s:PreviewLines(),
        \ printf('a blank document previews as one blank row (incremental=%d)', s:mode))
  let s:after = simplemarkdown#DebugStatus().full_renders
        \ + simplemarkdown#DebugStatus().patched_renders
  call assert_true(s:after - s:before < 8,
        \ printf('a blank document settles instead of resynchronising for ever '
        \ .. '(incremental=%d, %d renders)', s:mode, s:after - s:before))
endfor
let g:simplemarkdown_incremental = 1

" And it must come back from empty.
silent %delete _
call setline(1, s:saved)
call simplemarkdown#Refresh()
call assert_true(s:Wait('index(s:PreviewLines(), "▌ Retitled") >= 0', 5000),
      \ 'the document renders again after being emptied: ' .. string(s:PreviewLines()))

" ----------------------------------------------------------------- teardown ---

SimpleMarkdownClose
call assert_equal(0, s:PreviewWin(), 'closing removes the preview window')

" Reopening after a close must work: the session bookkeeping has to be clean.
SimpleMarkdownOpen
call assert_true(s:PreviewWin() > 0, 'the preview reopens')
" The heading is '# Retitled' by now — the incremental section rewrote row 1.
call assert_true(s:Wait('index(s:PreviewLines(), "▌ Retitled") >= 0', 5000),
      \ 'and renders again: ' .. string(s:PreviewLines()))

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
