" The external (browser) preview: process supervision, port allocation and
" teardown, against a stand-in for omd.
"
" Nothing here touches the daemon or the preview window — the two previews are
" independent by construction, and this test is what keeps them that way.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_external.vim

set nocompatible
set nomore
set shortmess+=I

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)

let g:simplemarkdown_omd_path = s:root .. '/tests/fake_omd.py'
" The browser is the one part that cannot be asserted on; opening a real one
" from a test would be a nuisance rather than a check.
let g:simplemarkdown_omd_browser = 0
let g:simplemarkdown_omd_port = 34117
let g:simplemarkdown_auto_open = 0
let $FAKE_OMD_LOG = tempname()
runtime plugin/simplemarkdown.vim

function! s:Wait(expr, ms) abort
  let l:i = 0
  while l:i < a:ms / 10
    if eval(a:expr)
      return 1
    endif
    sleep 10m
    let l:i += 1
  endwhile
  return eval(a:expr)
endfunction

function! s:Calls() abort
  return filereadable($FAKE_OMD_LOG) ? readfile($FAKE_OMD_LOG) : []
endfunction

" ------------------------------------------------------------------ setup ---

call assert_true(executable(g:simplemarkdown_omd_path),
      \ 'the fake omd is executable: chmod +x tests/fake_omd.py')

for s:name in ['SimpleMarkdownExternal', 'SimpleMarkdownExternalOpen',
      \ 'SimpleMarkdownExternalClose', 'SimpleMarkdownExternalStatic']
  call assert_equal(2, exists(':' .. s:name), s:name .. ' is defined')
endfor

call assert_equal(g:simplemarkdown_omd_path, simplemarkdown#external#Executable(),
      \ 'an explicit path wins over $PATH')

" ------------------------------------------------- an unwritten buffer ---

" omd watches a file on disk.  A buffer that has never been written has no
" path to watch, and starting a server for it would serve nothing.
enew
setlocal filetype=markdown
call simplemarkdown#external#Open()
call assert_equal([], simplemarkdown#external#Status(),
      \ 'a nameless buffer starts no server')

" --------------------------------------------------------------- serving ---

let s:first = tempname() .. '.md'
call writefile(['# first'], s:first)
execute 'edit ' .. fnameescape(s:first)
setlocal filetype=markdown
let s:first_buf = bufnr('%')

SimpleMarkdownExternalOpen
call assert_true(s:Wait('len(simplemarkdown#external#Status()) == 1', 3000),
      \ 'a server is registered for the buffer')

let s:status = simplemarkdown#external#Status()[0]
call assert_equal(s:first_buf, s:status.bufnr, 'the server is tied to the source buffer')
call assert_equal(s:first, s:status.path, 'omd is pointed at the file on disk')
call assert_equal(printf('http://127.0.0.1:%d', g:simplemarkdown_omd_port), s:status.url,
      \ 'the first server takes the configured port')

" The port must actually be listening — the whole point of the supervisor is
" that the URL it hands out works.
call assert_true(s:Wait('ch_status(ch_open("127.0.0.1:' .. g:simplemarkdown_omd_port
      \ .. '", {"waittime": 200})) ==# "open"', 3000),
      \ 'the advertised port accepts connections')

" Asking again is a request to look at it, not to start a second one.
SimpleMarkdownExternalOpen
call assert_equal(1, len(simplemarkdown#external#Status()),
      \ 'reopening does not start a second server')

" ------------------------------------------------------ a second document ---

" Two buffers previewed at once must not collide: the second has to find the
" next free port on its own.
let s:second = tempname() .. '.md'
call writefile(['# second'], s:second)
execute 'edit ' .. fnameescape(s:second)
setlocal filetype=markdown

SimpleMarkdownExternalOpen
call assert_true(s:Wait('len(simplemarkdown#external#Status()) == 2', 3000),
      \ 'the second buffer gets its own server')
let s:ports = map(copy(simplemarkdown#external#Status()), {_, v -> v.url})
call assert_equal(2, len(uniq(sort(copy(s:ports)))), 'the two servers are on different ports: '
      \ .. string(s:ports))

" ---------------------------------------------------------------- health ---

let s:health = join(simplemarkdown#external#HealthLines(), "\n")
call assert_true(s:health =~# '\[OK\] omd:', 'health reports the omd binary')
call assert_true(s:health =~# 'external preview:', 'health lists the live servers')
call assert_true(has_key(simplemarkdown#DebugStatus(), 'external'),
      \ 'the debug dump carries the external state')

" ----------------------------------------------------------- static mode ---

SimpleMarkdownExternalStatic
call assert_true(s:Wait('!empty(filter(copy(s:Calls()), {_, v -> v =~# "^static "}))', 3000),
      \ 'static mode invokes omd --static-mode: ' .. string(s:Calls()))
call assert_equal(2, len(simplemarkdown#external#Status()),
      \ 'static mode leaves no server behind')

" -------------------------------------------------------------- teardown ---

" Closing the current buffer's server must leave the other one alone.
SimpleMarkdownExternalClose
call assert_true(s:Wait('len(simplemarkdown#external#Status()) == 1', 3000),
      \ 'closing stops only this buffer''s server')
call assert_equal(s:first_buf, simplemarkdown#external#Status()[0].bufnr,
      \ 'the other buffer keeps its server')

" Wiping the source buffer takes its server with it: a preview of a document
" that is gone is just a held port.
execute 'bwipeout ' .. s:first_buf
call assert_true(s:Wait('empty(simplemarkdown#external#Status())', 3000),
      \ 'wiping the buffer stops its server')
call assert_true(s:Wait('ch_status(ch_open("127.0.0.1:' .. g:simplemarkdown_omd_port
      \ .. '", {"waittime": 100})) !=# "open"', 3000),
      \ 'and releases its port')

" -------------------------------------------------------- a failing start ---

" omd exiting straight away must not leave an entry that looks live.
let $FAKE_OMD_FAIL = '3'
execute 'edit ' .. fnameescape(s:second)
call simplemarkdown#external#Open()
call assert_true(s:Wait('empty(simplemarkdown#external#Status())', 3000),
      \ 'a server that dies at startup is not left registered')
unlet $FAKE_OMD_FAIL

" ------------------------------------------------------ a missing binary ---

let g:simplemarkdown_omd_path = '/nonexistent/omd'
call assert_equal('', simplemarkdown#external#Executable(),
      \ 'a bad configured path resolves to nothing')
call simplemarkdown#external#Open()
call assert_equal([], simplemarkdown#external#Status(),
      \ 'nothing is started without a binary')

" ----------------------------------------------------------------- close ---

call simplemarkdown#external#StopAll()
call assert_equal([], simplemarkdown#external#Status(), 'StopAll clears everything')
call delete(s:first)
call delete(s:second)
call delete($FAKE_OMD_LOG)

if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  call writefile(v:errors, s:root .. '/tests/external-errors.log')
  cquit
endif
qall!
