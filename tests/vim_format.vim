" Table formatting in the source buffer, end to end: a real daemon measures and
" Vim applies.  The two halves that matter are that the widths are display
" columns rather than bytes — the reason this is not a Vimscript function — and
" that the document is only ever touched over the range the daemon named.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_format.vim

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

" Messages accumulate for the life of the session, so every check is against
" what arrived after a mark rather than against the whole log.
function! s:Mark() abort
  return len(execute('messages'))
endfunction

function! s:Since(mark) abort
  return strpart(execute('messages'), a:mark)
endfunction

call assert_true(executable(g:simplemarkdown_daemon_path),
      \ 'the daemon is built: run `cargo build` first')
call assert_equal(2, exists(':SimpleMarkdownFormatTable'),
      \ 'SimpleMarkdownFormatTable is defined')
call assert_notequal('', maparg('<Plug>(simplemarkdown-format-table)', 'n'),
      \ 'the format-table Plug mapping exists')

" ------------------------------------------------------------------ fixture ---

let s:doc = tempname() .. '.md'
" The CJK cell is four display columns and six bytes; the ragged row is one
" cell short; the fenced block is bait for anything matching `|` by pattern.
call writefile([
      \ '# Title',
      \ '',
      \ 'Intro paragraph.',
      \ '',
      \ '| name | qty |',
      \ '|:--|--:|',
      \ '| 名前 | 1 |',
      \ '| a very long cell | 22 |',
      \ '| short |',
      \ '',
      \ '```',
      \ '| not | a table |',
      \ '|---|---|',
      \ '```',
      \ ], s:doc)

execute 'edit ' .. fnameescape(s:doc)
setlocal filetype=markdown
let s:original = getline(1, '$')

" ------------------------------------------------------------------ aligning ---

call cursor(7, 1)
SimpleMarkdownFormatTable
call assert_true(s:Wait('getline(5) =~# "name  "', 5000),
      \ 'the table is realigned: ' .. string(getline(5, 9)))

call assert_equal([
      \ '| name             | qty |',
      \ '| :--------------- | --: |',
      \ '| 名前             |   1 |',
      \ '| a very long cell |  22 |',
      \ '| short            |     |',
      \ ], getline(5, 9), 'every column is padded to its widest cell')

" The point of measuring in the daemon: `strlen()` would make the CJK row six
" bytes wider than the rest, and `strchars()` two narrower.
for s:row in getline(5, 9)
  call assert_equal(strdisplaywidth(getline(5)), strdisplaywidth(s:row),
        \ 'every row is the same width on screen: ' .. s:row)
endfor

call assert_equal(s:original[0 : 3], getline(1, 4), 'nothing above the table moved')
call assert_equal(s:original[9 : ], getline(10, '$'), 'and nothing below it')

" One `u` puts the table back: a formatter whose edit takes several undo steps
" is one people stop trusting.
undo
call assert_equal(s:original, getline(1, '$'), 'the whole edit is one undo step')
redo
call assert_equal('| name             | qty |', getline(5), 'and it redoes')

" ---------------------------------------------------------------- idempotent ---

let s:tick = b:changedtick
call cursor(5, 1)
SimpleMarkdownFormatTable
call assert_true(s:Wait('simplemarkdown#core#PendingCount() == 0', 5000),
      \ 'the second request is answered')
call assert_equal(s:tick, b:changedtick,
      \ 'an aligned table is left alone, so nothing lands on the undo stack')

" ------------------------------------------------------- what is not a table ---

let s:mark = s:Mark()
call cursor(3, 1)
SimpleMarkdownFormatTable
call assert_true(s:Wait('s:Since(s:mark) =~# "no table under the cursor"', 5000),
      \ 'a paragraph is not a table: ' .. s:Since(s:mark))
call assert_equal(s:tick, b:changedtick, 'and the buffer is untouched')

" A pattern-matching formatter finds a table inside the fence; a parser does
" not, and this is the whole reason the daemon is asked rather than a regexp.
let s:mark = s:Mark()
call cursor(12, 1)
SimpleMarkdownFormatTable
call assert_true(s:Wait('s:Since(s:mark) =~# "no table under the cursor"', 5000),
      \ 'a fenced code block is not a table: ' .. s:Since(s:mark))
call assert_equal(s:tick, b:changedtick, 'and the buffer is untouched')

" ----------------------------------------------------------------- refusals ---

let s:mark = s:Mark()
setlocal nomodifiable
call cursor(7, 1)
SimpleMarkdownFormatTable
call assert_true(s:Since(s:mark) =~# 'not modifiable',
      \ 'a read-only buffer is refused before anything is sent')
setlocal modifiable

let s:mark = s:Mark()
new
setlocal filetype=text
SimpleMarkdownFormatTable
call assert_true(s:Since(s:mark) =~# 'not a Markdown buffer',
      \ 'and so is a buffer that holds no Markdown')
bwipeout!

" ----------------------------------------------------------------- teardown ---

call simplemarkdown#Stop()
call delete(s:doc)

if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  call writefile(v:errors, s:root .. '/tests/format-errors.log')
  cquit
endif
qall!
