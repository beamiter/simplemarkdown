" The structural edits — promote, demote, renumber — end to end: a real daemon
" parses and Vim applies.  What matters here is not the shifted `#` but the
" three things around it: that a bare command takes the whole section so the
" tree still says what it said, that a range takes exactly what it names, and
" that the whole edit is one undo step even when it is several splices.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_authoring.vim

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

function! s:Mark() abort
  return len(execute('messages'))
endfunction

function! s:Since(mark) abort
  return strpart(execute('messages'), a:mark)
endfunction

" Every command below is asynchronous: the request goes out, the reply comes
" back on the channel.  Waiting on the pending count rather than on the text
" means a command that changes nothing is still waited for.
function! s:Settle() abort
  call assert_true(s:Wait('simplemarkdown#core#PendingCount() == 0', 5000),
        \ 'the request was answered')
endfunction

call assert_true(executable(g:simplemarkdown_daemon_path),
      \ 'the daemon is built: run `cargo build` first')
for s:name in ['Promote', 'Demote', 'Renumber']
  call assert_equal(2, exists(':SimpleMarkdown' .. s:name),
        \ 'SimpleMarkdown' .. s:name .. ' is defined')
endfor
call assert_notequal('', maparg('<Plug>(simplemarkdown-demote)', 'n'),
      \ 'the demote Plug mapping exists')
call assert_notequal('', maparg('<Plug>(simplemarkdown-renumber)', 'x'),
      \ 'and a Visual-mode one, so a selection can be shifted')

" ------------------------------------------------------------------ fixture ---

" Lines 11-14 are the trap every `^#` pattern falls into, and lines 16-19 the
" one every `^\d\+\.` pattern does.
let s:doc = tempname() .. '.md'
let s:source = [
      \ '# Title',
      \ '',
      \ 'Intro.',
      \ '',
      \ '## Chapter',
      \ '',
      \ 'Body.',
      \ '',
      \ '### Section',
      \ '',
      \ '```sh',
      \ '# not a heading',
      \ 'echo hi',
      \ '```',
      \ '',
      \ '1. one',
      \ '1. two',
      \ '1. three',
      \ '',
      \ '## Appendix',
      \ ]
call writefile(s:source, s:doc)

execute 'edit ' .. fnameescape(s:doc)
setlocal filetype=markdown

" ---------------------------------------------------- a section moves whole ---

" The cursor is in the chapter's prose, not on its heading: the section is what
" a bare command means, and it is found from the document rather than from the
" line under the cursor.
call cursor(7, 1)
SimpleMarkdownDemote
call assert_true(s:Wait('getline(5) ==# "### Chapter"', 5000),
      \ 'the chapter heading went one level deeper: ' .. getline(5))
call assert_equal('#### Section', getline(9),
      \ 'and its subsection went with it, so the tree still says what it said')
call assert_equal('# Title', getline(1), 'the heading above it did not move')
call assert_equal('## Appendix', getline(20), 'nor the sibling below it')
call assert_equal('# not a heading', getline(12),
      \ 'and a `#` inside a fenced block is still a comment')

" Two lines changed in two splices, and one `u` puts both back.
undo
call assert_equal(s:source, getline(1, '$'),
      \ 'the whole edit is one undo step, however many lines it touched')

" ------------------------------------------------------ a range means itself ---

" Drawn over the chapter heading and its prose but stopping short of the
" subsection: only the headings inside it move, because that is what a
" selection is.  (A one-line range is the cursor's line and cannot be told
" apart from no range at all, so it keeps the section meaning.)
5,8SimpleMarkdownDemote
call assert_true(s:Wait('getline(5) ==# "### Chapter"', 5000),
      \ 'the heading in the range moved: ' .. getline(5))
call assert_equal('### Section', getline(9),
      \ 'and the subsection outside it did not')
undo
call assert_equal(s:source, getline(1, '$'), 'restored')

" ------------------------------------------------------------- the two ends ---

" H1 cannot promote.  The refusal names the heading and the document is left
" exactly as it was — a partial shift would leave it half-restructured with no
" way to tell which half.
let s:tick = b:changedtick
let s:mark = s:Mark()
call cursor(1, 1)
SimpleMarkdownPromote
call assert_true(s:Wait('s:Since(s:mark) =~# "past H1"', 5000),
      \ 'promoting an H1 is refused: ' .. s:Since(s:mark))
call assert_equal(s:tick, b:changedtick, 'and nothing at all was written')
call assert_equal(s:source, getline(1, '$'), 'including the sections below it')

" A line with no heading at or above it is an ordinary answer, not an error.
let s:mark = s:Mark()
new
setlocal filetype=markdown
call setline(1, ['just prose', 'and more'])
call cursor(2, 1)
SimpleMarkdownDemote
call assert_true(s:Wait('s:Since(s:mark) =~# "no heading here"', 5000),
      \ 'a document with no headings says so: ' .. s:Since(s:mark))
call assert_equal(['just prose', 'and more'], getline(1, '$'), 'and is untouched')
bwipeout!

" -------------------------------------------------------------- renumbering ---

execute 'buffer ' .. bufnr(s:doc)
call cursor(17, 1)
SimpleMarkdownRenumber
call assert_true(s:Wait('getline(17) ==# "2. two"', 5000),
      \ 'the lazy list is numbered in order: ' .. string(getline(16, 18)))
call assert_equal(['1. one', '2. two', '3. three'], getline(16, 18))
call assert_equal(s:source[10 : 13], getline(11, 14),
      \ 'and the `1.` lines inside the fence are not a list')

" Idempotent, and an already-numbered list is not an edit — nothing lands on
" the undo stack for a command that changed nothing.
let s:tick = b:changedtick
let s:mark = s:Mark()
SimpleMarkdownRenumber
call s:Settle()
call assert_equal(s:tick, b:changedtick,
      \ 'a numbered list is left alone: ' .. s:Since(s:mark))
call assert_true(s:Since(s:mark) =~# 'already numbered',
      \ 'and says so: ' .. s:Since(s:mark))
undo
call assert_equal(s:source, getline(1, '$'), 'the renumbering was one undo step')

" ----------------------------------------------------------------- refusals ---

let s:mark = s:Mark()
setlocal nomodifiable
call cursor(5, 1)
SimpleMarkdownDemote
call assert_true(s:Since(s:mark) =~# 'not modifiable',
      \ 'a read-only buffer is refused before anything is sent')
setlocal modifiable

let s:mark = s:Mark()
new
setlocal filetype=text
SimpleMarkdownPromote
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
  call writefile(v:errors, s:root .. '/tests/authoring-errors.log')
  cquit
endif
qall!
