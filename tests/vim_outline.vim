" The outline: headings and where each section ends, asked of the backend
" without laying anything out.  Three things depend on it and none of them may
" open a preview window — a table of contents in a plain buffer, `]]`/`[[` in
" the source, and folding, which Vim asks about once per line per redraw.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_outline.vim

set nocompatible
set nomore
set shortmess+=I

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
let s:debug = s:root .. '/target/debug/simplemarkdown-daemon'
let s:release = s:root .. '/target/release/simplemarkdown-daemon'
let g:simplemarkdown_daemon_path =
      \ getftime(s:debug) > getftime(s:release) ? s:debug : s:release
let g:simplemarkdown_debounce = 0
let g:simplemarkdown_auto_open = 0
" Folding is asked for before the plugin loads, the way a vimrc would.
let g:simplemarkdown_folding = 1
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

function! s:PreviewWindows() abort
  return len(filter(getwininfo(), 'getbufvar(v:val.bufnr, "&filetype") ==# "simplemarkdown"'))
endfunction

call assert_true(executable(g:simplemarkdown_daemon_path),
      \ 'the daemon is built: run `cargo build` first')

" ------------------------------------------------------------------ fixture ---

let s:doc = tempname() .. '.md'
" The fenced `# not a heading` is the whole argument for parsing rather than
" matching `^#`: every markdown foldexpr in the wild folds it.
call writefile([
      \ 'preamble, before any heading',
      \ '',
      \ '# Top',
      \ '',
      \ 'intro',
      \ '',
      \ '## One',
      \ '',
      \ '```sh',
      \ '# not a heading',
      \ '```',
      \ '',
      \ '### Deep',
      \ '',
      \ 'body',
      \ '',
      \ '## Two',
      \ '',
      \ 'tail',
      \ ], s:doc)

execute 'edit ' .. fnameescape(s:doc)
setlocal filetype=markdown
let s:src_win = win_getid()

call assert_true(s:Wait('!empty(get(b:, "simplemarkdown_outline", []))', 5000),
      \ 'the outline arrives without anything being asked of the screen')
call assert_equal(0, s:PreviewWindows(), 'and without opening a preview window')

let s:outline = b:simplemarkdown_outline
call assert_equal(['Top', 'One', 'Deep', 'Two'],
      \ map(copy(s:outline), 'v:val.text'),
      \ 'a heading inside a fence is not one: ' .. string(s:outline))
call assert_equal([3, 7, 13, 17], map(copy(s:outline), 'v:val.src'))
call assert_equal([19, 16, 16, 19], map(copy(s:outline), 'v:val.end_src'),
      \ 'a section runs to the line before the next one of its level')

" -------------------------------------------------------------------- folds ---

call assert_equal('expr', &l:foldmethod, 'folding is set up for a Markdown buffer')
call assert_equal('simplemarkdown#FoldLevel(v:lnum)', &l:foldexpr)

" Everything above the first heading belongs to no section; `>N` opens one.
call assert_equal(['0', '0', '>1', '1', '1'],
      \ map(range(1, 5), 'simplemarkdown#FoldLevel(v:val)'),
      \ 'the preamble is outside every fold and the H1 opens one')
call assert_equal('>2', simplemarkdown#FoldLevel(7), 'the H2 opens a deeper fold')
call assert_equal('>3', simplemarkdown#FoldLevel(13), 'and the H3 a deeper one still')
call assert_equal('2', simplemarkdown#FoldLevel(10),
      \ 'a `#` inside a fenced block does not open a fold')
call assert_equal('3', simplemarkdown#FoldLevel(15), 'the H3 section continues')
call assert_equal('2', simplemarkdown#FoldLevel(19), 'and the last H2 runs to the end')

" Folds that actually exist in the window, which is the only proof the
" foldexpr answers are coherent — an incoherent set silently produces none.
normal! zM
call assert_equal(3, foldclosed(4), 'the H1 fold closes over its section')
call assert_equal(19, foldclosedend(4), 'to the end of the document')
call assert_equal(-1, foldclosed(1), 'the preamble is not swallowed by it')
call assert_true(foldtextresult(3) =~# 'Top', 'the fold text names the heading: ' .. foldtextresult(3))
call assert_true(foldtextresult(3) =~# '17 lines', 'and says how much it hides')
normal! zR

" A fold the reader closed is the reader's.  The refresh below lands behind
" them, with no keystroke of their own, and the obvious way to make Vim ask
" foldexpr again — `zx` — is *defined* as "undo manually opened and closed
" folds": with it here, every section closed by hand sprang open one keystroke
" after it was closed, which is the opposite of what the help promises.
call cursor(7, 1)
normal! zc
call assert_equal(7, foldclosed(8), 'a section closes when it is asked to')
call assert_equal(16, foldclosedend(8), 'over the lines the outline gave it')

" A heading appended below everything: the refresh has landed when the new
" section has a level, which is a fact about the outline rather than about the
" bookkeeping around it.  `-es` never redraws, so asking is also what makes
" Vim put the question a redraw would.
call append(19, ['', '## Three'])
call assert_true(s:Wait('simplemarkdown#FoldLevel(21) ==# ">2"', 5000),
      \ 'the refresh lands: ' .. string(map(range(17, 21), 'simplemarkdown#FoldLevel(v:val)')))
call assert_equal(7, foldclosed(8),
      \ 'and the fold closed before it is still closed after it')
call assert_equal(16, foldclosedend(8), 'over the same lines')
normal! zR
undo

" An edit moves the sections, and the cached levels have to follow.
call append(0, ['inserted', ''])
call assert_true(s:Wait('simplemarkdown#FoldLevel(5) ==# ">1"', 5000),
      \ 'the outline is refreshed after an edit: '
      \ .. string(map(range(1, 9), 'simplemarkdown#FoldLevel(v:val)')))
undo

" ------------------------------------------------------------------ motions ---

call assert_true(s:Wait('simplemarkdown#FoldLevel(3) ==# ">1"', 5000),
      \ 'the outline settles again after the undo')
call cursor(1, 1)
call simplemarkdown#NextHeading(1)
call assert_equal(3, line('.'), ']] moves this cursor to the next heading')
call simplemarkdown#NextHeading(1)
call assert_equal(7, line('.'), 'and on to the next')
call simplemarkdown#NextHeading(-1)
call assert_equal(3, line('.'), '[[ moves back')
call assert_equal(0, s:PreviewWindows(), 'none of which opens a preview')

" ---------------------------------------------------------------- contents ---

" :SimpleMarkdownToc used to answer "what is in this document" by splitting the
" window and starting a render.  The question was about the document.
call cursor(1, 1)
SimpleMarkdownToc
call assert_true(s:Wait('!empty(popup_list())', 5000), 'the contents popup opens')
call assert_equal(0, s:PreviewWindows(), 'and no preview window is opened for it')

let s:popup = popup_list()[0]
call assert_equal(['Top', '  One', '    Deep', '  Two'],
      \ getbufline(winbufnr(s:popup), 1, '$'), 'the outline is indented by level')

" Choosing the third entry moves this cursor to that heading.
call popup_close(s:popup, 3)
call assert_equal(13, line('.'), 'choosing a heading jumps to it in the source')
call assert_equal(s:src_win, win_getid(), 'in the window the command was run from')

" ---------------------------------------------------- one request per pause ---

" What folding costs.  EnsureOutline() answers foldexpr from a buffer variable,
" but the refresh behind it sends the whole document and buys a whole parse, and
" it used to send one per changedtick — one full copy of the file per keystroke
" while typing, with as many parses in flight as the typing outran the daemon.
" It is debounced like a render now.
"
" Asserted from the wire, because nothing on the Vim side can be asked this: the
" plugin's counters say how many replies came back, not how many requests it
" decided to send.
let s:wire = tempname()
call writefile([], s:wire)
let $SIMPLEMARKDOWN_WIRE_LOG = s:wire
let $SIMPLEMARKDOWN_REAL_DAEMON = g:simplemarkdown_daemon_path
let s:shim = s:root .. '/tests/wire_shim.py'
call assert_true(executable(s:shim),
      \ 'the wire shim is executable: chmod +x tests/wire_shim.py')

function! s:Outlines() abort
  return len(filter(readfile($SIMPLEMARKDOWN_WIRE_LOG), 'v:val =~# ''"type":"outline"'''))
endfunction

" Stopped and waited out before the path is moved, not restarted over the top
" of a running daemon: :SimpleMarkdownRestart hands the old job a SIGTERM and
" starts the new one from a timer that does nothing while the old one is still
" reaping, so it can leave the daemon this is replacing in place.
call simplemarkdown#Stop()
call assert_true(s:Wait('!simplemarkdown#core#IsRunning()', 5000),
      \ 'the daemon this test is replacing has exited')
let g:simplemarkdown_daemon_path = s:shim
" Long enough that the edits below cannot straddle it, short enough that this
" waits out one of them rather than a person's patience.
let g:simplemarkdown_debounce = 300
SimpleMarkdownRestart
call assert_true(s:Wait('simplemarkdown#core#Ready()'
      \ .. ' && simplemarkdown#core#Health().exe_path ==# s:shim', 5000),
      \ 'the daemon comes back up behind the shim: '
      \ .. simplemarkdown#core#Health().exe_path)
call assert_true(s:Wait('!empty(filter(readfile(s:wire), ''v:val =~# "ping"''))', 5000),
      \ 'and the shim copies what the plugin sends: ' .. string(readfile(s:wire)))

call win_gotoid(s:src_win)
let s:sent_before = s:Outlines()
" Twenty edits, each followed by a foldexpr sweep of the whole buffer: what
" typing a word into a folded document looks like.
for s:i in range(20)
  call append(line('$'), 'edit ' .. s:i)
  for s:lnum in range(1, line('$'))
    call simplemarkdown#FoldLevel(s:lnum)
  endfor
endfor
call assert_equal(s:sent_before, s:Outlines(),
      \ 'no outline goes out while the edits are still arriving, however many'
      \ .. ' times foldexpr asks')
call assert_true(s:Wait('s:Outlines() > ' .. s:sent_before, 5000),
      \ 'and the pause after them sends one')
call assert_equal(s:sent_before + 1, s:Outlines(),
      \ 'exactly one, not one per edit: ' .. (s:Outlines() - s:sent_before)
      \ .. ' requests for 20 edits')
call assert_true(s:Wait('getbufvar(bufnr("%"), "simplemarkdown_outline_tick", -1)'
      \ .. ' == getbufvar(bufnr("%"), "changedtick")', 5000),
      \ 'and that one describes the document as it now stands')
call assert_equal(['Top', 'One', 'Deep', 'Two'],
      \ map(copy(b:simplemarkdown_outline), 'v:val.text'),
      \ 'which still has its four headings: ' .. string(b:simplemarkdown_outline))

let g:simplemarkdown_debounce = 0
let g:simplemarkdown_daemon_path = $SIMPLEMARKDOWN_REAL_DAEMON

" ----------------------------------------------------------------- teardown ---

call simplemarkdown#Stop()
call delete(s:doc)
call delete(s:wire)

if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  call writefile(v:errors, s:root .. '/tests/outline-errors.log')
  cquit
endif
qall!
