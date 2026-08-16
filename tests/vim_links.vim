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

" An anchor that names nothing says so, and does nothing else.
"
" What "does nothing else" is measured against matters.  Asking whether the
" current buffer is still main.md cannot fail: following a link from the
" preview legitimately leaves the cursor in the preview window, so the check
" was true whatever Follow() did.  A wrong jump disturbs two things instead —
" it opens a buffer, or it moves the source cursor — and both are recorded
" here immediately before the attempt.
call assert_true(s:PreviewSearch('nowhere') > 0, 'the broken link renders')
let s:before_buffers = len(getbufinfo())
let s:before_line = line('.', s:src_win)
call simplemarkdown#Activate()
call assert_true(execute('messages') =~# 'no heading matching #no-such-heading',
      \ 'an unresolvable anchor is reported')
call assert_equal(s:before_buffers, len(getbufinfo()),
      \ 'an unresolvable anchor opens no buffer')
call assert_equal(0, bufexists(s:dir .. '/#no-such-heading'),
      \ 'and no file called #no-such-heading was opened')
call assert_equal(s:before_line, line('.', s:src_win),
      \ 'and the source cursor stays where it was')

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
SimpleMarkdownFollow
call assert_true(execute('messages') =~# 'no link under the cursor',
      \ 'a line with no link says so')
call assert_equal(11, line('.'), 'and the cursor does not move')

" ------------------------------------------------------ a remote document ---

" A document open through SimpleRemote's virtual workspace is a
" `remote:///abs/path` buffer with 'buftype' acwrite and b:vimrc_remote; the
" files it links to are on the remote host, so a link is resolved against the
" remote path and opened as another remote:// buffer for SimpleRemote's
" BufReadCmd to fill.  SimpleRemote is not on the runtimepath here: what is
" tested is the name the plugin asks :edit for, and that the anchor jump waits
" for the fill it announces.
new
file remote:///srv/docs/main.md
setlocal buftype=acwrite
call setline(1, [
      \ '# Remote main',
      \ '',
      \ 'Open [the other file](./sub/../other.md#target-heading) too.',
      \ '',
      \ 'Or [the top one](/srv/top.md).',
      \ '',
      \ 'And [this one](#remote-main).',
      \ '',
      \ 'Or [itself](./main.md#remote-main).',
      \ ])
let b:vimrc_remote = {'path': '/srv/docs/main.md',
      \ 'uri': 'remote:///srv/docs/main.md', 'generation': 1}
" As SimpleRemote leaves a buffer it has just filled.  Kept loaded when
" hidden: without SimpleRemote's BufReadCmd there is nothing to reload it from.
setlocal nomodified bufhidden=hide
setlocal filetype=markdown
let s:remote_win = win_getid()
let s:remote_buf = bufnr('%')

" From the source buffer.  Column 1 is on no link: the leftmost one is meant.
call cursor(3, 1)
let s:mark = len(split(execute('messages'), "\n"))
SimpleMarkdownFollow
call assert_equal('remote:///srv/docs/other.md', bufname('%'),
      \ 'a relative link is resolved against the remote path, `..` collapsed, '
      \ .. 'and opened as a remote:// buffer: ' .. bufname('%'))
call assert_equal(s:remote_win, win_getid(), 'in the same window')
call assert_true(join(split(execute('messages'), "\n")[s:mark :], "\n") !~# 'cannot open',
      \ 'and is not tested for local readability, which it has none of')
let s:other_remote = bufnr('%')

" Nothing has filled the buffer yet — SimpleRemote does that asynchronously —
" so the `#target-heading` jump is owed, not made.
call assert_equal([''], getline(1, '$'), 'the buffer is empty until SimpleRemote fills it')
call setline(1, ['# Other', '', '```sh', '# target heading', '```', '', '## Target heading', '', 'Landed.'])
let b:vimrc_remote = {'path': '/srv/docs/other.md',
      \ 'uri': 'remote:///srv/docs/other.md', 'generation': 1}
setlocal nomodified bufhidden=hide
let g:simpleremote_event = {'event': 'SimpleRemoteBufferRead', 'type': 'buffer-read',
      \ 'bufnr': s:other_remote, 'path': '/srv/docs/other.md', 'workspace': {},
      \ 'status': 'ssh:box', 'time': 0}
doautocmd <nomodeline> User SimpleRemoteBufferRead
unlet g:simpleremote_event
call assert_equal(7, line('.'),
      \ 'the anchor is jumped to once SimpleRemote says the text is there, '
      \ .. 'and the fenced bait is skipped')

" A second read of the same buffer owes nothing: the anchor was consumed.
call cursor(1, 1)
let g:simpleremote_event = {'event': 'SimpleRemoteBufferRead', 'bufnr': s:other_remote}
doautocmd <nomodeline> User SimpleRemoteBufferRead
unlet g:simpleremote_event
call assert_equal(1, line('.'), 'a later fill does not jump again')

" An absolute href names the remote filesystem, not this machine's.
execute 'buffer ' .. s:remote_buf
call cursor(5, 1)
SimpleMarkdownFollow
call assert_equal('remote:///srv/top.md', bufname('%'),
      \ 'an absolute link opens that path on the remote host: ' .. bufname('%'))

" A bare #anchor in a remote document is the same as in a local one.
execute 'buffer ' .. s:remote_buf
call cursor(7, 6)
SimpleMarkdownFollow
call assert_equal(s:remote_buf, bufnr('%'), 'a bare #anchor stays in the remote buffer')
call assert_equal(1, line('.'), 'and moves to its heading')

" A link to the document itself is a jump, not a reload: with unwritten
" changes an :edit would be refused, and without them it would throw the text
" away for SimpleRemote to fetch again.
call cursor(9, 6)
setlocal modified
SimpleMarkdownFollow
call assert_equal(s:remote_buf, bufnr('%'), 'a link to the document itself stays in it')
call assert_equal(1, line('.'), 'and jumps to the anchor')
call assert_true(&modified, 'without touching the buffer')
setlocal nomodified

" From the preview: the same link, followed with the daemon's link spans.  The
" target buffer already exists and is filled, so the jump is immediate.
call win_gotoid(s:remote_win)
execute 'buffer ' .. s:remote_buf
SimpleMarkdownOpen
call assert_true(s:Wait('join(s:PreviewLines(), "\n") =~# "Remote main"', 5000),
      \ 'the remote document renders: ' .. string(s:PreviewLines()))
call assert_true(s:PreviewSearch('the other file') > 0, 'the cross-file link renders')
call simplemarkdown#Activate()
call assert_equal(s:remote_win, win_getid(), 'following from the preview lands in the source window')
call assert_equal('remote:///srv/docs/other.md', bufname('%'),
      \ 'on the remote:// buffer the link names')
call assert_equal(7, line('.'), 'at the anchored heading')
SimpleMarkdownClose
execute 'bwipeout! ' .. s:other_remote
execute 'bwipeout! ' .. bufnr('remote:///srv/top.md')
call win_gotoid(s:remote_win)
bwipeout!

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
