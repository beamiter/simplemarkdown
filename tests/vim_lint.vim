" Document diagnostics, end to end: a real daemon answers and the location list
" is what a user reads the answer in.  What is checked here is the seam — the
" codes, lines and severities that survive the trip into `setloclist()` — and
" the two things that make a linter usable rather than merely present: it
" clears itself when the document is clean, and the on-write pass stays quiet.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_lint.vim

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

function! s:Codes() abort
  return map(getloclist(0), 'matchstr(v:val.text, "^[a-z-]\\+")')
endfunction

function! s:LocationWindows() abort
  return len(filter(getwininfo(), 'v:val.loclist'))
endfunction

call assert_true(executable(g:simplemarkdown_daemon_path),
      \ 'the daemon is built: run `cargo build` first')
call assert_equal(2, exists(':SimpleMarkdownLint'), 'SimpleMarkdownLint is defined')
call assert_notequal('', maparg('<Plug>(simplemarkdown-lint)', 'n'),
      \ 'the lint Plug mapping exists')
call assert_equal(0, g:simplemarkdown_lint_on_write, 'checking on write is off by default')

" Every code the daemon can emit must be documented, and the help is what a
" reader of the location list reaches for next.
let s:doc_text = join(readfile(s:root .. '/doc/simplemarkdown.txt'), "\n")
for s:line in systemlist(g:simplemarkdown_daemon_path .. ' --codes')
  let s:code = split(s:line, "\t")[0]
  call assert_true(s:doc_text =~# '\V\n    ' .. escape(s:code, '\') .. ' ',
        \ 'the help documents the ' .. s:code .. ' diagnostic')
endfor

" ------------------------------------------------------------------ fixture ---

let s:doc = tempname() .. '.md'
call writefile([
      \ '# Title',
      \ '',
      \ 'Jump to [nowhere](#no-such-heading) and read the note[^missing].',
      \ '',
      \ '### Skipped a level',
      \ '',
      \ '| a | b |',
      \ '|---|---|',
      \ '| 1 |',
      \ '',
      \ '```sh',
      \ '# not a heading',
      \ '[x](#also-nowhere)',
      \ '```',
      \ ], s:doc)

execute 'edit ' .. fnameescape(s:doc)
setlocal filetype=markdown
let s:src_buf = bufnr('%')

" ---------------------------------------------------------------- a document ---

SimpleMarkdownLint
call assert_true(s:Wait('!empty(getloclist(0))', 5000),
      \ 'the diagnostics arrive in the location list')

let s:items = getloclist(0)
call assert_equal(
      \ ['broken-anchor', 'undefined-footnote', 'heading-skip', 'ragged-table-row'],
      \ s:Codes(), 'every check reports, in source order: ' .. string(s:Codes()))
call assert_equal([3, 3, 5, 9], map(copy(s:items), 'v:val.lnum'),
      \ 'each one is on the line it is about')
call assert_equal(9, s:items[0].col,
      \ 'and at the column of the link, not of the line')
call assert_equal(['W', 'W', 'I', 'W'], map(copy(s:items), 'v:val.type'),
      \ 'advice is separated from what a reader will notice')
call assert_true(s:items[0].text =~# '#no-such-heading',
      \ 'the message names the thing that is wrong: ' .. s:items[0].text)
call assert_equal(s:src_buf, s:items[0].bufnr, 'entries point back at the document')

" Nothing inside the fence is reported, which is the whole reason the daemon is
" asked rather than a pattern: `# not a heading` and `[x](#also-nowhere)` are a
" shell comment and a code sample.
call assert_equal(0, len(filter(copy(s:items), 'v:val.lnum >= 11')),
      \ 'a fenced block is not linted: ' .. string(s:items))

call assert_equal(1, s:LocationWindows(), 'the location window is opened')
call assert_equal('SimpleMarkdown diagnostics', getloclist(0, {'title': 1}).title,
      \ 'and says where the list came from')

" ------------------------------------------------------------- a clean sweep ---

" Fixing everything must also close the window: a list still showing the last
" run is worse than none, because every problem in it has just been fixed.
lclose
%delete _
call setline(1, ['# Title', '', 'All well.', ''])
SimpleMarkdownLint
call assert_true(s:Wait('empty(getloclist(0))', 5000),
      \ 'a clean document empties the list: ' .. string(getloclist(0)))
call assert_equal(0, s:LocationWindows(), 'and closes the location window')

" ------------------------------------------------------------ on every write ---

let g:simplemarkdown_lint_on_write = 1
call setline(1, ['# Title', '', 'Broken [link](#nope).', ''])
write
call assert_true(s:Wait('!empty(getloclist(0))', 5000),
      \ 'a write checks the document when asked to')
call assert_equal(['broken-anchor'], s:Codes(), 'and reports what it found')
call assert_equal(0, s:LocationWindows(),
      \ 'silently: a save that opens a window is a save people stop making')

let g:simplemarkdown_lint_on_write = 0
call setloclist(0, [], ' ')
call setline(3, 'Still broken [link](#nope).')
write
sleep 300m
call assert_equal([], getloclist(0), 'and does nothing at all when switched off')

" ----------------------------------------------------------------- teardown ---

call simplemarkdown#Stop()
call delete(s:doc)

if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  call writefile(v:errors, s:root .. '/tests/lint-errors.log')
  cquit
endif
qall!
