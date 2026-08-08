" Link following, end to end: a real daemon, a real preview, real files on
" disk.  The three href shapes a Markdown document actually contains — a bare
" `#anchor`, `other.md#section`, and a plain relative path — are each followed
" twice: from the preview window, where the daemon's link spans say what is
" under the cursor, and from the source buffer, where a pattern does.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_links.vim

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

" Put the preview cursor on the first row whose text matches, and return it.
function! s:PreviewSearch(pattern) abort
  call win_gotoid(s:PreviewWin())
  call cursor(1, 1)
  return search(a:pattern, 'cW')
endfunction

call assert_true(executable(g:simplemarkdown_daemon_path),
      \ 'the daemon is built: run `cargo build` first')

" ------------------------------------------------------------------ fixture ---

" A two-file docs tree, because half of what is being tested is a link that
" crosses from one file to another.
let s:dir = tempname()
call mkdir(s:dir, 'p')
let s:main = s:dir .. '/main.md'
let s:other = s:dir .. '/other.md'

call writefile([
      \ '# Main title',
      \ '',
      \ 'Jump to [the notes](#notes-part-one) from here.',
      \ '',
      \ 'Open [the other file](./other.md#target-heading) too.',
      \ '',
      \ 'Read [the reference][ref] as well.',
      \ '',
      \ '## Notes: part one!',
      \ '',
      \ 'Body.',
      \ '',
      \ '## Notes',
      \ '',
      \ 'First duplicate.',
      \ '',
      \ '## Notes',
      \ '',
      \ 'Also [the second](#notes-1) here.',
      \ '',
      \ 'Nothing at [nowhere](#no-such-heading).',
      \ '',
      \ '[ref]: ./other.md',
      \ ], s:main)

" The fenced `# target heading` is bait: a heading scan that does not skip code
" would answer `#target-heading` with line 4 instead of line 7.
call writefile([
      \ '# Other document',
      \ '',
      \ '```sh',
      \ '# target heading',
      \ '```',
      \ '',
      \ '## Target heading',
      \ '',
      \ 'Landed on the target.',
      \ ], s:other)

call assert_equal(2, exists(':SimpleMarkdownFollow'), 'SimpleMarkdownFollow is defined')
call assert_notequal('', maparg('<Plug>(simplemarkdown-follow)', 'n'),
      \ 'the follow Plug mapping exists')

execute 'edit ' .. fnameescape(s:main)
setlocal filetype=markdown
let s:src_win = win_getid()
let s:src_buf = bufnr('%')

SimpleMarkdownOpen
call assert_true(s:Wait('simplemarkdown#core#Ready()', 5000),
      \ 'the daemon completes its handshake')
call assert_true(s:Wait('join(s:PreviewLines(), "\n") =~# "Main title"', 5000),
      \ 'the document renders: ' .. string(s:PreviewLines()))

" ------------------------------------------------- a bare #anchor, from the preview ---

" `[the notes](#notes-part-one)`: the anchor is GitHub's slug of a heading with
" punctuation in it, which the pre-slug prose match could never have resolved.
call assert_true(s:PreviewSearch('the notes') > 0, 'the intra-document link renders')
call simplemarkdown#Activate()
call assert_equal(9, line('.', s:src_win),
      \ 'a bare #anchor moves the source cursor onto its heading')
call assert_true(getbufline(winbufnr(s:PreviewWin()), line('.', s:PreviewWin()))[0]
      \ =~# 'Notes: part one',
      \ 'and the preview cursor onto the rendered heading')

" A repeated heading is reachable by its de-duplicated anchor, which is the one
" thing a slug computed per-heading cannot get right on its own.
call assert_true(s:PreviewSearch('the second') > 0, 'the duplicate-anchor link renders')
call simplemarkdown#Activate()
call assert_equal(17, line('.', s:src_win),
      \ '#notes-1 is the second heading of that name, not the first')

" An anchor that names nothing says so rather than trying to open a file.
let s:before = len(split(execute('messages'), "\n"))
call assert_true(s:PreviewSearch('nowhere') > 0, 'the broken link renders')
call simplemarkdown#Activate()
call assert_true(execute('messages') =~# 'no heading matching #no-such-heading',
      \ 'an unresolvable anchor is reported')
call assert_true(bufnr('%') != s:src_buf || expand('%:p') ==# s:main,
      \ 'and no file called #no-such-heading was opened')

" --------------------------------------------- a cross-file anchor, from the preview ---

call assert_true(s:PreviewSearch('the other file') > 0, 'the cross-file link renders')
call simplemarkdown#Activate()
call assert_equal(s:src_win, win_getid(), 'following a file link lands in the source window')
call assert_equal(fnamemodify(s:other, ':p'), expand('%:p'), 'the linked file is opened')
call assert_equal(7, line('.'),
      \ 'the #section of a cross-file link is honoured, and the fenced bait is not')

execute 'edit ' .. fnameescape(s:main)
call assert_true(s:Wait('join(s:PreviewLines(), "\n") =~# "Main title"', 5000),
      \ 'the preview follows back to the first document')

" ------------------------------------------------------ from the source buffer ---

" No preview involvement at all: the link is found by pattern in the buffer.
call win_gotoid(s:src_win)
" Column 1 is on no link: the line's leftmost link is what a user means.
call cursor(5, 1)
SimpleMarkdownFollow
call assert_equal(fnamemodify(s:other, ':p'), expand('%:p'),
      \ 'the source buffer follows a relative link')
call assert_equal(7, line('.'), 'and lands on the anchored heading')

execute 'edit ' .. fnameescape(s:main)
call cursor(7, 8)
SimpleMarkdownFollow
call assert_equal(fnamemodify(s:other, ':p'), expand('%:p'),
      \ 'a reference link resolves through its [ref]: definition')

execute 'edit ' .. fnameescape(s:main)
SimpleMarkdownClose
call assert_equal(0, s:PreviewWin(), 'the preview is closed for the source-only checks')

call cursor(3, 12)
SimpleMarkdownFollow
call assert_equal(fnamemodify(s:main, ':p'), expand('%:p'),
      \ 'a bare #anchor stays in the same file')
call assert_equal(9, line('.'),
      \ 'and moves the cursor to its heading with no preview open')

call cursor(11, 1)
let s:messages_before = execute('messages')
SimpleMarkdownFollow
call assert_true(execute('messages') =~# 'no link under the cursor',
      \ 'a line with no link says so')
call assert_equal(11, line('.'), 'and the cursor does not move')

" ----------------------------------------------------------------- teardown ---

call simplemarkdown#Stop()
call delete(s:main)
call delete(s:other)
call delete(s:dir, 'd')

if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  call writefile(v:errors, s:root .. '/tests/links-errors.log')
  cquit
endif
qall!
