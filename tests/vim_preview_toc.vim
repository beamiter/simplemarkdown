" A real Vim popup and renderer: an outline menu belongs to the render it
" displayed, not the latest contents of its preview session.
set nocompatible
set nomore
set hidden

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
let s:debug = s:root .. '/target/debug/simplemarkdown-daemon'
let s:release = s:root .. '/target/release/simplemarkdown-daemon'
let g:simplemarkdown_daemon_path =
      \ getftime(s:debug) > getftime(s:release) ? s:debug : s:release
let g:simplemarkdown_auto_open = 0
let g:simplemarkdown_debounce = 0
let g:simplemarkdown_sync_scroll = 0
runtime plugin/simplemarkdown.vim

function! s:WaitForPreview(heading) abort
  for l:attempt in range(500)
    if index(getbufline(winbufnr(s:preview), 1, '$'), '▌ ' .. a:heading) >= 0
      return 1
    endif
    sleep 10m
  endfor
  return 0
endfunction

function! s:Menu(labels) abort
  call win_gotoid(s:preview)
  SimpleMarkdownToc
  let l:popups = popup_list()
  call assert_equal(1, len(l:popups), 'exactly one preview contents popup')
  if len(l:popups) != 1
    return -1
  endif
  call assert_equal(a:labels, getbufline(winbufnr(l:popups[0]), 1, '$'))
  return l:popups[0]
endfunction

function! s:ChooseWithoutJump(menu, context) abort
  call win_execute(s:source, 'call cursor(2, 1)')
  call win_execute(s:preview, 'call cursor(1, 1)')
  if a:menu > 0
    call popup_close(a:menu, 2)
  endif
  call assert_equal(2, getcurpos(s:source)[1], a:context .. ': source cursor')
  call assert_equal(1, getcurpos(s:preview)[1], a:context .. ': preview cursor')
endfunction

call assert_true(executable(g:simplemarkdown_daemon_path), 'build the real daemon first')
call assert_true(has('popupwin'), 'the test needs real Vim popups')
let s:first = tempname() .. '.md'
let s:second = tempname() .. '.md'
call writefile(['preamble', '', '# Alpha', '', '# Beta', '', 'body'], s:first)
call writefile(['preamble', '', '# Gamma', '', 'body', '', '# Delta'], s:second)
execute 'edit ' .. fnameescape(s:first)
setlocal filetype=markdown
let s:source = win_getid()
SimpleMarkdownOpen
SimpleMarkdownFocus
let s:preview = win_getid()
call assert_notequal(s:source, s:preview)
call assert_true(s:WaitForPreview('Beta'), 'first real render has both headings')

let s:old = s:Menu(['Alpha', 'Beta'])
call appendbufline(winbufnr(s:source), 2, ['# Inserted', ''])
call win_execute(s:source, 'SimpleMarkdownRefresh')
call assert_true(s:WaitForPreview('Inserted'), 'updated render landed before selecting the old item')
call s:ChooseWithoutJump(s:old, 'stale menu after repaint')
let s:new = s:Menu(['Inserted', 'Alpha', 'Beta'])
if s:new > 0
  call popup_close(s:new, 3)
endif
call assert_equal(7, getcurpos(s:source)[1], 'fresh menu selects Beta')

let s:old = s:Menu(['Inserted', 'Alpha', 'Beta'])
call win_gotoid(s:source)
execute 'hide edit ' .. fnameescape(s:second)
setlocal filetype=markdown
call assert_true(s:WaitForPreview('Delta'), 'the same preview now renders another document')
call s:ChooseWithoutJump(s:old, 'stale menu after switching source buffers')
let s:new = s:Menu(['Gamma', 'Delta'])
if s:new > 0
  call popup_close(s:new, 2)
endif
call assert_equal(7, getcurpos(s:source)[1], 'fresh menu selects Delta')
call assert_equal(bufnr(s:second), winbufnr(s:source))

call simplemarkdown#Stop()
call delete(s:first)
call delete(s:second)
if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qa!
