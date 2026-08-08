" Version skew: a plugin updated without its backend being rebuilt.
"
" This is the commonest failure mode of a Vim plugin with a compiled daemon —
" a plugin manager pulls new Vim files and never runs install.sh — and the one
" branch that has to explain itself, because the symptom is a preview window
" that simply never draws.  The stand-in daemon from the simplecore bundle
" answers the handshake with whatever FAKE_PROTOCOL says, which is exactly the
" skew a stale lib/ produces.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_protocol.vim

set nocompatible
set nomore
set shortmess+=I

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)

" One less than whatever this plugin speaks, so the test does not have to be
" edited on the next protocol bump.
let s:expected = str2nr(matchstr(
      \ join(readfile(s:root .. '/autoload/simplemarkdown.vim'), "\n"),
      \ 'const PROTOCOL_VERSION = \zs\d\+'))
call assert_true(s:expected > 1, 'the plugin declares a protocol version')
let $FAKE_PROTOCOL = string(s:expected - 1)

let g:simplemarkdown_daemon_path = s:root .. '/tests/fake_daemon.py'
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

function! s:PreviewText() abort
  let l:winid = s:PreviewWin()
  return l:winid ? join(getbufline(winbufnr(l:winid), 1, '$'), "\n") : ''
endfunction

call assert_true(executable(g:simplemarkdown_daemon_path), 'the stand-in daemon is executable')

let s:doc = tempname() .. '.md'
call writefile(['# Title', '', 'Body.'], s:doc)
execute 'edit ' .. fnameescape(s:doc)
setlocal filetype=markdown

SimpleMarkdownOpen
call assert_true(s:PreviewWin() > 0, 'the preview window opens')
call assert_true(s:Wait('simplemarkdown#core#Ready()', 5000),
      \ 'the handshake completes even though the versions disagree')
call assert_equal(s:expected - 1, simplemarkdown#core#Protocol(),
      \ 'the daemon reports the older protocol')
call assert_equal(s:expected, simplemarkdown#DebugStatus().protocol_expected,
      \ 'and the plugin still expects its own')

" The explanation has to be in the window the user is looking at.  An echom
" alone is gone by the next redraw, and what is left is a blank preview.
call assert_true(s:Wait('s:PreviewText() =~# "protocol v"', 2000),
      \ 'the preview explains the mismatch, got: ' .. string(s:PreviewText()))
call assert_true(s:PreviewText() =~# printf('v%d', s:expected - 1),
      \ 'it names the version the daemon speaks')
call assert_true(s:PreviewText() =~# printf('v%d', s:expected),
      \ 'and the version the plugin speaks')
call assert_true(s:PreviewText() =~# 'install\.sh',
      \ 'and says what to do about it')
call assert_true(execute('messages') =~# 'protocol v',
      \ 'the mismatch is in :messages too')

" The health report is where a user is told to look, so it has to name both
" versions and the remedy rather than only what the plugin speaks.
let s:health = execute('SimpleMarkdownHealth')
call assert_true(s:health =~# '\[ERROR\] protocol',
      \ 'health reports the protocol mismatch as an error, got: ' .. s:health)
call assert_true(s:health =~# printf('v%d', s:expected)
      \ && s:health =~# printf('v%d', s:expected - 1),
      \ 'and names both versions')
call assert_true(s:health =~# 'install\.sh', 'and the remedy')

" And it says whether the binary in place is older than the sources beside it,
" which is the same failure one step earlier.
let s:built = getftime(g:simplemarkdown_daemon_path)
let s:newest = 0
for s:source in glob(s:root .. '/src/**/*.rs', 0, 1)
  let s:newest = max([s:newest, getftime(s:source)])
endfor
call assert_true(s:health =~# (s:built >= s:newest ? '\[OK\] backend' : '\[WARN\] backend'),
      \ 'health compares the backend against its sources, got: ' .. s:health)

" Nothing may be rendered against a protocol this plugin cannot read: the row
" and property layout is precisely what a version bump changes.
SimpleMarkdownRefresh
sleep 200m
call assert_true(s:PreviewText() =~# 'install\.sh',
      \ 'a refresh does not paint rows from an unknown protocol')

call simplemarkdown#Stop()
call delete(s:doc)

if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  call writefile(v:errors, s:root .. '/tests/protocol-errors.log')
  cquit
endif
qall!
