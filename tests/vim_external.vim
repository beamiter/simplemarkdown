" The external (browser) preview, against the real daemon: serving a buffer,
" following it as it changes, one server per buffer, and teardown.
"
" It talks HTTP to the port the plugin was handed rather than believing the
" plugin's own table.  The table is what the plugin thinks it did; the socket is
" what it did — and every bug this preview has ever had lived in the gap.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_external.vim

set nocompatible
set nomore
set shortmess+=I
" One preview per buffer is the thing being tested, and a buffer with unwritten
" changes cannot be left behind without this.
set hidden

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)

" The browser is the one part that cannot be asserted on; opening a real one
" from a test would be a nuisance rather than a check.
let g:simplemarkdown_browser = 0
let g:simplemarkdown_browser_port = 34117
let g:simplemarkdown_browser_math = 'off'
let g:simplemarkdown_debounce = 20
let g:simplemarkdown_auto_open = 0
let s:debug = s:root .. '/target/debug/simplemarkdown-daemon'
let s:release = s:root .. '/target/release/simplemarkdown-daemon'
let g:simplemarkdown_daemon_path =
      \ getftime(s:debug) > getftime(s:release) ? s:debug : s:release
runtime plugin/simplemarkdown.vim

let s:tmp = tempname()
call mkdir(s:tmp, 'p')

function! s:Ok(condition, what) abort
  call assert_true(a:condition, a:what)
endfunction

function! s:Wait(expr, ms) abort
  let l:waited = 0
  while l:waited < a:ms
    if eval(a:expr)
      return 1
    endif
    sleep 20m
    let l:waited += 20
  endwhile
  return eval(a:expr)
endfunction

" One HTTP GET.  Spoken by python3 rather than by Vim's raw channel: a client
" that has to decide for itself when the response has ended is a second thing
" the test can hang on, and the thing under test is the server.
function! s:Get(port, path) abort
  let l:code = 'import sys,urllib.request,urllib.error' ..
        \ "\nurl='http://127.0.0.1:" .. a:port .. a:path .. "'" ..
        \ "\ntry:" ..
        \ "\n r=urllib.request.urlopen(url,timeout=5)" ..
        \ "\n sys.stdout.write(str(r.status)+chr(10)+r.read().decode('utf-8','replace'))" ..
        \ "\nexcept urllib.error.HTTPError as e:" ..
        \ "\n sys.stdout.write(str(e.code)+chr(10))" ..
        \ "\nexcept Exception:" ..
        \ "\n sys.stdout.write('0'+chr(10))"
  return system(['python3', '-c', l:code])
endfunction

" Nothing is listening on this port any more.
function! s:Refused(port) abort
  let l:code = 'import socket,sys' ..
        \ "\ns=socket.socket()" ..
        \ "\ns.settimeout(1)" ..
        \ "\nsys.stdout.write('1' if s.connect_ex(('127.0.0.1'," .. a:port .. ")) else '0')"
  return system(['python3', '-c', l:code]) ==# '1'
endfunction

function! s:Status() abort
  return simplemarkdown#external#Status()
endfunction

" ── one buffer, served ──────────────────────────────────────────────────────

let s:doc = s:tmp .. '/note.md'
call writefile(['# Kettle', '', 'A paragraph about kettles.'], s:doc)
execute 'edit ' .. fnameescape(s:doc)
setfiletype markdown

SimpleMarkdownExternalOpen
call s:Ok(s:Wait('len(s:Status()) == 1', 8000), 'a preview is registered for the buffer')

let s:entry = s:Status()[0]
let s:port = str2nr(matchstr(s:entry.url, ':\zs\d\+'))
call s:Ok(s:port >= 34117, 'the URL carries the port that was asked for: ' .. s:entry.url)

let s:page = s:Get(s:port, '/')
call s:Ok(s:page =~# '^200\n', 'GET / is answered 200')
call s:Ok(s:page =~# 'Kettle', 'the page carries the heading')
call s:Ok(s:page =~# 'data-line=', 'blocks carry their source line, for scroll sync')
call s:Ok(s:page =~# '<style>', 'the page carries its own stylesheet')
call s:Ok(s:page !~# 'cdn\.jsdelivr', 'with maths off the page reaches nowhere')

" ── following the buffer, not the file ──────────────────────────────────────

call setline(3, 'A paragraph about teapots.')
" What the autocommand does, called the way the rest of the suite calls it.
call simplemarkdown#OnTextChanged(bufnr('%'))
" Written nowhere: the point is that the served page has moved even though the
" file on disk still says kettles.
call s:Ok(s:Wait('s:Get(' .. s:port .. ', "/") =~# "teapots"', 4000),
      \ 'an unwritten change reaches the page')
call s:Ok(readfile(s:doc)[2] =~# 'kettles', 'and the file on disk was not touched')

" ── one server per buffer ───────────────────────────────────────────────────

let s:other = s:tmp .. '/other.md'
call writefile(['# Other', '', 'Second document.'], s:other)
execute 'edit ' .. fnameescape(s:other)
setfiletype markdown
SimpleMarkdownExternalOpen
call s:Ok(s:Wait('len(s:Status()) == 2', 8000), 'a second buffer gets a second server')

let s:ports = map(copy(s:Status()), {_, e -> matchstr(e.url, ':\zs\d\+')})
call s:Ok(len(uniq(sort(copy(s:ports)))) == 2, 'the two servers are on different ports')

" ── teardown ────────────────────────────────────────────────────────────────

SimpleMarkdownExternalClose
call s:Ok(s:Wait('len(s:Status()) == 1', 4000), 'closing this buffer leaves the other alone')

SimpleMarkdownExternalClose!
call s:Ok(s:Wait('empty(s:Status())', 4000), 'the bang stops every server')
call s:Ok(s:Wait('s:Refused(' .. s:port .. ')', 4000), 'and the port is free again')

" ── the static page ─────────────────────────────────────────────────────────

execute 'edit ' .. fnameescape(s:doc)
setfiletype markdown
let g:simplemarkdown_static_opened = ''
" Browse() is the last thing Static() does and the only thing that would open a
" window; overriding it is how the file it wrote becomes readable from here.
function! simplemarkdown#external#Browse(url) abort
  let g:simplemarkdown_static_opened = a:url
  return 1
endfunction

SimpleMarkdownExternalStatic
call s:Ok(s:Wait('g:simplemarkdown_static_opened !=# ""', 8000), 'the static page is written and opened')
let s:file = substitute(g:simplemarkdown_static_opened, '^file://', '', '')
call s:Ok(filereadable(s:file), 'it is a file on disk: ' .. s:file)
let s:static = join(readfile(s:file), "\n")
call s:Ok(s:static =~# '<style>' && s:static =~# 'Kettle',
      \ 'self-contained: its own stylesheet and its own content')
call s:Ok(s:static =~# '"live":false', 'and its config says nothing is listening')

" ── a buffer with no name ───────────────────────────────────────────────────

enew
setfiletype markdown
call setline(1, '# Nameless')
SimpleMarkdownExternalOpen
call s:Ok(empty(s:Status()), 'a buffer with no name starts no server')

call simplemarkdown#Stop()

if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  call writefile(v:errors, s:root .. '/tests/external-errors.log')
  cquit
endif
qall!
