set nocompatible nomore encoding=utf-8
let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:repo)
let s:temp = tempname()
call mkdir(s:temp, 'p')
let $MARKDOWN_DELTA_LOG = s:temp .. '/wire.jsonl'
let $MARKDOWN_DELTA_MISS = s:temp .. '/miss'
let $MARKDOWN_DELTA_CAP = '1'
let g:simplemarkdown_daemon_path = s:repo .. '/tests/fake_source_delta.py'
let g:simplemarkdown_auto_open = 0
let g:simplemarkdown_debounce = 0
let g:simplemarkdown_sync_scroll = 0
runtime plugin/simplemarkdown.vim

function! s:Preview() abort
  for l:win in getwininfo()
    if getbufvar(l:win.bufnr, '&filetype') ==# 'simplemarkdown'
      return getbufline(l:win.bufnr, 1, '$')
    endif
  endfor
  return []
endfunction

function! s:Data() abort
  let l:rows = filereadable($MARKDOWN_DELTA_LOG) ? readfile($MARKDOWN_DELTA_LOG) : []
  return filter(map(l:rows, 'json_decode(v:val)'), 'index(["render", "render_delta"], v:val.type) >= 0')
endfunction

function! s:Wait(callback, label) abort
  for l:_ in range(200)
    if call(a:callback, [])
      return 1
    endif
    sleep 10m
  endfor
  call assert_report('timeout: ' .. a:label)
  return 0
endfunction

execute 'edit ' .. fnameescape(s:temp .. '/source.md')
setlocal filetype=markdown
call setline(1, ['# exact header'] + repeat([repeat('source unchanged ', 8)], 2399))
let s:buf = bufnr()
SimpleMarkdownOpen
call s:Wait({-> s:Preview() ==# ['# exact header', repeat('source unchanged ', 8)]
      \ && simplemarkdown#core#Negotiated()}, 'initial large preview')
let s:full = s:Data()[-1]
call assert_equal('render', s:full.type)

call setbufline(s:buf, 1500, 'local change 界')
SimpleMarkdownRefresh
call s:Wait({-> s:Preview() ==# ['# exact header', 'local change 界']}, 'line edit')
let s:delta = s:Data()[-1]
call assert_equal('render_delta', s:delta.type, 'a one-line edit should use negotiated input splice')
call assert_equal(s:full.id, get(s:delta, 'base', 0))
call assert_equal(1499, get(s:delta, 'from', -1))
call assert_equal(1, get(s:delta, 'del', -1))
call assert_true(s:delta.wire_bytes < 1024 && s:delta.wire_bytes * 100 < s:full.wire_bytes,
      \ 'the splice must not send the untouched document too')

if exists('$MARKDOWN_DELTA_PROOF')
  call writefile([printf('full=%d delta=%d', s:full.wire_bytes, s:delta.wire_bytes)],
        \ $MARKDOWN_DELTA_PROOF)
endif

call writefile([], $MARKDOWN_DELTA_MISS)
call setbufline(s:buf, 1500, 'edited after eviction')
SimpleMarkdownRefresh
call s:Wait({-> s:Preview() ==# ['# exact header', 'edited after eviction']}, 'full fallback after miss')
call assert_equal(['render_delta', 'render'], map(s:Data()[-2:], 'v:val.type'),
      \ 'a missing source base falls back once, without a stale preview')
call assert_equal(v:false, get(s:Data()[-1], 'incremental', v:false))
call delete($MARKDOWN_DELTA_MISS)

call setbufline(s:buf, 1300, repeat(['large replacement'], 280))
SimpleMarkdownRefresh
call s:Wait({-> s:Preview() ==# ['# exact header', 'large replacement']}, 'large change preview')
call assert_equal('render', s:Data()[-1].type, 'oversized splice uses the full source')

let s:old = s:Data()[-1].pid
SimpleMarkdownRestart
call s:Wait({-> s:Data()[-1].pid != s:old
      \ && s:Preview() ==# ['# exact header', 'large replacement']}, 'capable daemon restart')
call assert_equal('render', s:Data()[-1].type, 'new capable peer receives a full snapshot first')
call assert_true(get(s:Data()[-1], 'remember_source', v:false))
call setbufline(s:buf, 1500, 'after capable restart')
SimpleMarkdownRefresh
call s:Wait({-> s:Preview() ==# ['# exact header', 'after capable restart']}, 'resume delta')
call assert_equal('render_delta', s:Data()[-1].type, 'new acknowledgement re-enables splices')

let s:old = s:Data()[-1].pid
let $MARKDOWN_DELTA_CAP = '0'
SimpleMarkdownRestart
call s:Wait({-> s:Data()[-1].pid != s:old
      \ && s:Preview() ==# ['# exact header', 'after capable restart']}, 'old-compatible process restart')
call assert_equal('render', s:Data()[-1].type, 'restart may not reuse an old input revision')
call assert_false(has_key(s:Data()[-1], 'remember_source'), 'legacy peer gets unchanged v4 request')
call setbufline(s:buf, 1500, 'legacy changed')
SimpleMarkdownRefresh
call s:Wait({-> s:Preview() ==# ['# exact header', 'legacy changed']}, 'legacy edit')
call assert_equal('render', s:Data()[-1].type)

call simplemarkdown#Stop()
call delete(s:temp, 'rf')
if !empty(v:errors)
  call writefile(v:errors, s:repo .. '/tests/source-delta-errors.log')
  cquit
endif
qall!
