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

" Run a python program and return what it wrote to stdout.
"
" Through a file rather than `python3 -c`, and through one string rather than
" an argv list, because of two separate traps.  Vim's system() takes a String
" command; a List first argument is Neovim's spelling and Vim does not accept
" it — it runs nothing, sets v:shell_error to 2 and hands back an empty string,
" which every assertion below then reads as "the server did not answer".  That
" is what this file did when it was written, so none of its HTTP assertions had
" ever run.  And once the command has to be one string for the shell, a
" multi-line python program inside it is a quoting problem with no good answer;
" a file has none.
function! s:Python(code) abort
  let l:script = tempname() .. '.py'
  call writefile(split(a:code, "\n", 1), l:script)
  let l:out = system('python3 ' .. shellescape(l:script))
  call delete(l:script)
  return l:out
endfunction

" One HTTP GET.  Spoken by python3 rather than by Vim's raw channel: a client
" that has to decide for itself when the response has ended is a second thing
" the test can hang on, and the thing under test is the server.
"
" The proxy handlers are stripped: urlopen() honours $http_proxy, and a machine
" that has one set would send a request for 127.0.0.1 to it and report the
" server unreachable.
function! s:Get(port, path) abort
  return s:Python('import sys,urllib.request,urllib.error' ..
        \ "\nurl='http://127.0.0.1:" .. a:port .. a:path .. "'" ..
        \ "\nopener=urllib.request.build_opener(urllib.request.ProxyHandler({}))" ..
        \ "\ntry:" ..
        \ "\n r=opener.open(url,timeout=5)" ..
        \ "\n sys.stdout.write(str(r.status)+chr(10)+r.read().decode('utf-8','replace'))" ..
        \ "\nexcept urllib.error.HTTPError as e:" ..
        \ "\n sys.stdout.write(str(e.code)+chr(10))" ..
        \ "\nexcept Exception:" ..
        \ "\n sys.stdout.write('0'+chr(10))")
endfunction

" Nothing is listening on this port any more.
function! s:Refused(port) abort
  return s:Python('import socket,sys' ..
        \ "\ns=socket.socket()" ..
        \ "\ns.settimeout(1)" ..
        \ "\nsys.stdout.write('1' if s.connect_ex(('127.0.0.1'," .. a:port .. ")) else '0')") ==# '1'
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
" What the tab is called when the document has no heading of its own, and what
" the page reports itself as.  The editor sends it; for a local document it is
" the file name, which is what the daemon would have worked out for itself.
call s:Ok(s:page =~# '"name":"note\.md"', 'the page is told what the document is called')

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

" ── what a document says it draws ───────────────────────────────────────────

" The list the staging below works from.  Every shape a picture can be written
" in, each href once, in document order, and nothing from inside a fence — a
" `![](x.png)` in a Markdown tutorial's code sample draws nothing.
new
call setline(1, [
      \ '![inline](img/one.png)',
      \ '![titled](img/two.png "A title")',
      \ '![spaced](<img/three four.png>)',
      \ '![byref][logo]',
      \ '![collapsed][]',
      \ '<p><img alt="raw" src="img/raw.png" width="20"></p>',
      \ "<IMG SRC='img/upper.png'>",
      \ '<img src=img/bare.png>',
      \ '<img alt=x src = img/spaced.png width=3>',
      \ '<img data-src="img/lazy.png" src="img/real.png">',
      \ '![again](img/one.png)',
      \ '[not an image](img/link.png)',
      \ '```',
      \ '![fenced](img/never.png)',
      \ '```',
      \ '~~~',
      \ '![tilde](img/never2.png)',
      \ '~~~',
      \ '',
      \ '[logo]: img/logo.png',
      \ '[collapsed]: img/collapsed.png',
      \ ])
call s:Ok(simplemarkdown#ImageHrefs(bufnr('%')) == [
      \ 'img/one.png', 'img/two.png', 'img/three four.png', 'img/logo.png',
      \ 'img/collapsed.png', 'img/raw.png', 'img/upper.png', 'img/bare.png',
      \ 'img/spaced.png', 'img/real.png'],
      \ 'every image the document draws, once: ' .. string(simplemarkdown#ImageHrefs(bufnr('%'))))
bwipeout!

" ── a remote document ───────────────────────────────────────────────────────

" A document open through SimpleRemote's virtual workspace is a `remote://`
" buffer whose directory — and pictures — are on another host.  The plugin
" stages the pictures the document names into a temporary directory with
" g:SimpleRemoteDownload() and has the daemon serve *that*, laid out as the
" URLs the browser will ask for.  SimpleRemote is not on the runtimepath: the
" download is a stub that copies out of a local tree standing in for the host,
" asynchronously, as the real one does.
let s:host = s:tmp .. '/host'
call mkdir(s:host .. '/srv/docs/img', 'p')
call mkdir(s:host .. '/srv/shared', 'p')
call writefile(['PNG-ONE'], s:host .. '/srv/docs/img/one.png')
call writefile(['PNG-LOGO'], s:host .. '/srv/shared/logo.png')
call writefile(['PNG-SPACE'], s:host .. '/srv/docs/x y.png')
let g:simplemarkdown_test_downloads = []
let g:simplemarkdown_test_download_delay = 30
function! g:SimpleRemoteDownload(remote, local, opts, Cb) abort
  call add(g:simplemarkdown_test_downloads, {'remote': a:remote, 'local': a:local,
        \ 'force': get(a:opts, 'force', v:false)})
  call timer_start(g:simplemarkdown_test_download_delay,
        \ {-> s:FinishDownload(a:remote, a:local, a:Cb)})
  return v:true
endfunction
function! s:FinishDownload(remote, local, Cb) abort
  let l:src = s:host .. a:remote
  if filereadable(l:src) && isdirectory(fnamemodify(a:local, ':h'))
    call writefile(readfile(l:src, 'b'), a:local, 'b')
    call call(a:Cb, [v:true, {'remote': a:remote, 'local': a:local, 'error': ''}])
  else
    call call(a:Cb, [v:false, {'remote': a:remote, 'local': a:local, 'error': 'no such file'}])
  endif
endfunction
function! g:SimpleRemoteStatusline() abort
  return 'ssh:box:srv@9ms'
endfunction

new
file remote:///srv/docs/main.md
setlocal buftype=acwrite bufhidden=hide
call setline(1, [
      \ '# Remote pictures',
      \ '',
      \ '![one](img/one.png)',
      \ '![logo](../shared/logo.png)',
      \ '![space](x%20y.png)',
      \ '![gone](missing.png)',
      \ '![web](https://example.com/x.png)',
      \ '',
      \ '```',
      \ '![sample](fenced.png)',
      \ '```',
      \ ])
let b:vimrc_remote = {'path': '/srv/docs/main.md',
      \ 'uri': 'remote:///srv/docs/main.md', 'generation': 1}
setlocal nomodified
setfiletype markdown
let s:remote_buf = bufnr('%')

SimpleMarkdownExternalOpen
call s:Ok(s:Wait('len(s:Status()) == 1', 8000), 'a remote document is served')
let s:entry = s:Status()[0]
let s:port = str2nr(matchstr(s:entry.url, ':\zs\d\+'))
call s:Ok(s:entry.remote ==# '/srv/docs/main.md', 'the entry knows the remote path: ' .. string(s:entry))
call s:Ok(s:entry.path =~# '/simplemarkdown-remote-' .. s:remote_buf .. '/main\.md$',
      \ 'the daemon was pointed at a staging directory named for the buffer: ' .. s:entry.path)
call s:Ok(s:entry.name ==# 'main.md @ssh:box:srv@9ms', 'the name says which workspace: ' .. s:entry.name)
let s:stage = fnamemodify(s:entry.path, ':h')

" What was fetched, where from, and where to.  Every relative href is resolved
" against the remote directory; the copy lands where the URL the browser will
" ask for says: `../shared/logo.png` is `/shared/logo.png` once the browser
" has clamped it at the root.  Nothing with a scheme, and nothing in a fence.
call s:Ok(len(g:simplemarkdown_test_downloads) == 4,
      \ 'four transfers, one per fetchable picture: ' .. string(g:simplemarkdown_test_downloads))
let s:fetched = {}
for s:d in g:simplemarkdown_test_downloads
  let s:fetched[s:d.remote] = s:d.local
  call s:Ok(s:d.force, 'each transfer replaces a stale copy: ' .. string(s:d))
endfor
call s:Ok(get(s:fetched, '/srv/docs/img/one.png', '') ==# s:stage .. '/img/one.png',
      \ 'a relative picture is staged under its own path: ' .. string(s:fetched))
call s:Ok(get(s:fetched, '/srv/shared/logo.png', '') ==# s:stage .. '/shared/logo.png',
      \ 'a `../` picture is fetched from the parent and staged where the clamped URL lands')
call s:Ok(get(s:fetched, '/srv/docs/x y.png', '') ==# s:stage .. '/x y.png',
      \ 'a percent-encoded href names the decoded file on the host')
call s:Ok(has_key(s:fetched, '/srv/docs/missing.png'), 'a picture that turns out missing was asked for')
call s:Ok(s:entry.staged == 3 && s:entry.assets == 4,
      \ 'three of the four are on this machine: ' .. string(s:entry))

" And the server hands them out.
let s:remote_page = s:Get(s:port, '/')
call s:Ok(s:remote_page =~# 'Remote pictures', 'the page is served')
" The name the page carries is the editor's, not the staging directory's: the
" copy the daemon was pointed at is called `main.md` whichever host it came
" from, and the tab of a remote README.md must not read like the local one's.
call s:Ok(s:remote_page =~# '"name":"main\.md @ssh:box:srv@9ms"',
      \ 'the page says which workspace the document is in')
call s:Ok(s:Get(s:port, '/img/one.png') =~# '^200\nPNG-ONE', 'a relative picture is served from the staging directory')
call s:Ok(s:Get(s:port, '/shared/logo.png') =~# '^200\nPNG-LOGO', 'so is the one above the document')
call s:Ok(s:Get(s:port, '/x%20y.png') =~# '^200\nPNG-SPACE', 'and the one with a space in its name')
call s:Ok(s:Get(s:port, '/missing.png') =~# '^404', 'a picture the host does not have is a clean 404')
call s:Ok(join(simplemarkdown#external#HealthLines(), "\n") =~# 'remote /srv/docs/main.md, 3/4 images staged',
      \ 'health says what was staged: ' .. string(simplemarkdown#external#HealthLines()))

" A picture the document starts naming later is fetched before the update
" that shows it is pushed, so the page never asks for it too early.
call writefile(['PNG-TWO'], s:host .. '/srv/docs/two.png')
call setline(2, '![two](two.png)')
call simplemarkdown#OnTextChanged(s:remote_buf)
call s:Ok(s:Wait('s:Status()[0].staged == 4', 4000), 'the new picture is staged: ' .. string(s:Status()))
call s:Ok(s:Wait('s:Get(' .. s:port .. ', "/") =~# "alt=\"two\""', 4000), 'and the update reaches the page')
call s:Ok(s:Get(s:port, '/two.png') =~# '^200\nPNG-TWO', 'served')
call s:Ok(len(g:simplemarkdown_test_downloads) == 5, 'the pictures already staged were not fetched again')

" The static page inlines them from the same directory.
let g:simplemarkdown_static_opened = ''
SimpleMarkdownExternalStatic
call s:Ok(s:Wait('g:simplemarkdown_static_opened !=# ""', 8000), 'the static page of a remote document is written')
let s:static = join(readfile(substitute(g:simplemarkdown_static_opened, '^file://', '', '')), "\n")
call s:Ok(s:static =~# 'alt="one"[^>]*' || s:static =~# 'data:image/png;base64,UE5HLU9ORQo=',
      \ 'a staged picture travels inside the page as a data: URI')
call s:Ok(s:static =~# 'data:image/png;base64,UE5HLU9ORQo=', 'img/one.png is inlined')
call s:Ok(s:static =~# 'data:image/png;base64,UE5HLVNQQUNFCg==', 'x y.png is inlined')
call s:Ok(s:static =~# 'src="missing.png"', 'a picture that could not be staged stays a link')
call s:Ok(s:static =~# '"name":"main\.md @ssh:box:srv@9ms"',
      \ 'and the one-shot page says which workspace it came from too')

SimpleMarkdownExternalClose
call s:Ok(s:Wait('empty(s:Status())', 4000), 'closing stops the remote preview')
call s:Ok(!isdirectory(s:stage), 'and removes the staging directory')

" Closed while the pictures are still coming: the serve must not happen.
let g:simplemarkdown_test_download_delay = 400
let g:simplemarkdown_test_downloads = []
SimpleMarkdownExternalOpen
call s:Ok(!empty(g:simplemarkdown_test_downloads), 'transfers start at once')
call s:Ok(empty(s:Status()), 'but nothing is served yet')
SimpleMarkdownExternalClose
sleep 700m
call s:Ok(empty(s:Status()), 'a preview closed while staging never opens')
call s:Ok(!isdirectory(s:stage), 'and its staging directory is gone')

" ...and reopened straight away, which is what an impatient close is followed
" by.  The withdrawn round's transfers are still in flight — a close does not
" cancel them — and they land while the new round's are still coming.  They
" must not be read as answers to the new round: crediting them would settle it
" with none of its own pictures here and open the tab on a page full of broken
" ones, which is the exact thing staging exists to prevent.
let g:simplemarkdown_test_download_delay = 300
let g:simplemarkdown_test_downloads = []
SimpleMarkdownExternalOpen
call s:Ok(len(g:simplemarkdown_test_downloads) == 5, 'the first round starts its transfers')
sleep 50m
SimpleMarkdownExternalClose
" Slower than the round it replaces, so the withdrawn callbacks land first.
let g:simplemarkdown_test_download_delay = 1200
let g:simplemarkdown_test_downloads = []
SimpleMarkdownExternalOpen
call s:Ok(len(g:simplemarkdown_test_downloads) == 5, 'and the second round starts its own')
" Past the first round's landing time and well short of the second's.
sleep 700m
call s:Ok(empty(s:Status()),
      \ 'a withdrawn round of transfers does not open the preview that replaced it')
call s:Ok(s:Wait('len(s:Status()) == 1', 8000), 'which opens once its own pictures are here')
call s:Ok(s:Status()[0].staged == 4 && s:Status()[0].assets == 5,
      \ 'with every picture accounted for: ' .. string(s:Status()))
SimpleMarkdownExternalClose
call s:Ok(s:Wait('empty(s:Status())', 4000), 'closed')
let g:simplemarkdown_test_download_delay = 30

" Without a SimpleRemote that can download, the document is still served — from
" an empty staging directory, so a picture is a clean 404 rather than a path on
" the wrong machine.
delfunction g:SimpleRemoteDownload
SimpleMarkdownExternalOpen
call s:Ok(s:Wait('len(s:Status()) == 1', 8000), 'a remote document is served without g:SimpleRemoteDownload')
let s:entry = s:Status()[0]
let s:port = str2nr(matchstr(s:entry.url, ':\zs\d\+'))
call s:Ok(s:entry.staged == 0 && s:entry.assets == 5, 'nothing could be staged: ' .. string(s:entry))
call s:Ok(s:Get(s:port, '/img/one.png') =~# '^404', 'and a picture is a clean 404')
SimpleMarkdownExternalClose
call s:Ok(s:Wait('empty(s:Status())', 4000), 'closed')

" A SimpleRemote that is not ready refuses a transfer from inside the call —
" the callback runs before g:SimpleRemoteDownload() has returned false — and
" every picture refused that way must still add up to a preview that opens.
function! g:SimpleRemoteDownload(remote, local, opts, Cb) abort
  call call(a:Cb, [v:false, {'error': 'remote workspace is not ready'}])
  return v:false
endfunction
SimpleMarkdownExternalOpen
call s:Ok(s:Wait('len(s:Status()) == 1', 8000), 'a document whose pictures are all refused is still served')
let s:entry = s:Status()[0]
call s:Ok(s:entry.staged == 0 && s:entry.assets == 5, 'with nothing staged: ' .. string(s:entry))
SimpleMarkdownExternalClose
call s:Ok(s:Wait('empty(s:Status())', 4000), 'closed')
delfunction g:SimpleRemoteDownload
delfunction g:SimpleRemoteStatusline
bwipeout!

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
