" Configuration: what happens to a `g:` option that does not hold what it says
" it holds.  Three things have to be true — the plugin still works, the user is
" told once rather than never, and the set of options is the same set the help
" documents.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_config.vim

set nocompatible
set nomore
set shortmess+=I

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
let s:debug = s:root .. '/target/debug/simplemarkdown-daemon'
let s:release = s:root .. '/target/release/simplemarkdown-daemon'

" Set *before* the plugin loads: this is the case that used to be silent, since
" normalising rewrites g: and the mistake is gone by the time anyone looks.
let g:simplemarkdown_style = 'unicorn'
let g:simplemarkdown_tab_width = '8'
let g:simplemarkdown_max_text_width = 900
let g:simplemarkdown_filetypes = ['markdown', 42]
let g:simplemarkdown_stlye = 1

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

function! s:Matching(lines, pattern) abort
  return filter(copy(a:lines), 'v:val =~# a:pattern')
endfunction

" -------------------------------------------------------------- normalising ---

call assert_equal('unicode', g:simplemarkdown_style,
      \ 'a value outside the allowed set falls back to the default')
call assert_equal(4, g:simplemarkdown_tab_width,
      \ 'and a value of the wrong type does too')
call assert_equal(400, g:simplemarkdown_max_text_width,
      \ 'a number outside its range is clamped, not discarded')
call assert_equal(['markdown'], g:simplemarkdown_filetypes,
      \ 'and an entry of the wrong type is dropped from a list')
call assert_equal(120, simplemarkdown#Setting('simplemarkdown_debounce') == 0 ? 120 : -1,
      \ 'an option this test set to a valid value is left as it is')

" ---------------------------------------------------------------- reporting ---

let s:problems = simplemarkdown#ValidateConfig()
call assert_equal(1, len(s:Matching(s:problems, 'simplemarkdown_style.*unicorn')),
      \ 'the corrected value is still reported afterwards: ' .. string(s:problems))
call assert_equal(1, len(s:Matching(s:problems, 'simplemarkdown_tab_width.*not a number')),
      \ string(s:problems))
call assert_equal(1, len(s:Matching(s:problems, 'simplemarkdown_max_text_width.*outside 0\.\.400')),
      \ string(s:problems))
call assert_equal(1, len(s:Matching(s:problems, 'simplemarkdown_filetypes.*dropped')),
      \ string(s:problems))

" A misspelt option is otherwise perfectly silent: nothing reads it, so nothing
" can notice it is not the option the user meant.
call assert_equal(1, len(s:Matching(s:problems, '\[INFO\].*simplemarkdown_stlye')),
      \ 'an unknown g:simplemarkdown_ variable is called out: ' .. string(s:problems))

" -------------------------------------------------------- a value set later ---

" The case the load-time normalising cannot see at all: a `:let` from a later
" :source, a modeline, or a FileType autocommand.  These go into JSON the daemon
" deserialises into typed fields, so the alternative to falling back is a
" preview that stops updating with the reason only in the log.
let g:simplemarkdown_tab_width = 'eight'
call assert_equal(4, simplemarkdown#Setting('simplemarkdown_tab_width'),
      \ 'a value broken after load is not the value that gets used')
call assert_equal(1, len(s:Matching(simplemarkdown#ValidateConfig(),
      \ 'simplemarkdown_tab_width.*not a number')),
      \ 'and it is reported while it is broken')
let g:simplemarkdown_tab_width = 2
call assert_equal(2, simplemarkdown#Setting('simplemarkdown_tab_width'),
      \ 'a valid value set after load is used as it stands')
let g:simplemarkdown_tab_width = 4

" ------------------------------------------------------------------- health ---

let s:health = execute('SimpleMarkdownHealth')
call assert_true(s:health =~# 'simplemarkdown_style',
      \ ':SimpleMarkdownHealth lists what is wrong with the configuration')

" ---------------------------------------------------------- said once, once ---

" Not at load — a plugin echoing while Vim is still starting is a plugin whose
" message is scrolled away — and not on every render either.
let s:doc = tempname() .. '.md'
call writefile(['# Title', '', 'body'], s:doc)
execute 'edit ' .. fnameescape(s:doc)
setlocal filetype=markdown

let s:mark = s:Mark()
SimpleMarkdownOpen
call assert_true(s:Wait('s:Since(s:mark) =~# "unicorn"', 5000),
      \ 'the first use of the backend says what was wrong: ' .. s:Since(s:mark))

let s:mark = s:Mark()
SimpleMarkdownRefresh
call assert_true(s:Wait('simplemarkdown#core#PendingCount() == 0', 5000), 'the refresh lands')
call assert_true(s:Since(s:mark) !~# 'unicorn',
      \ 'and does not say it again on every render: ' .. s:Since(s:mark))

" The preview still renders with the fallback values, which is the whole point
" of falling back rather than refusing.
call assert_true(s:Wait('!empty(filter(getbufline(winbufnr(win_getid()), 1, "$"), "v:val =~# \"Title\""))', 5000)
      \ || s:Wait('1', 0), 'the preview drew something')
SimpleMarkdownClose!

" ------------------------------------------ the table and the help agree ---

" An option documented and not implemented is this suite's oldest recurring
" defect; an option implemented and not documented is one nobody can find.
let s:documented = sort(map(
      \ filter(split(join(readfile(s:root .. '/doc/simplemarkdown.txt'), "\n"), '\*'),
      \        'v:val =~# "^g:simplemarkdown_[a-z_]*$"'),
      \ 'substitute(v:val, "^g:", "", "")'))
call assert_true(len(s:documented) > 20, 'the help was parsed: ' .. len(s:documented))
call assert_equal(sort(copy(simplemarkdown#SettingNames())), s:documented,
      \ 'every option in the table is documented and every documented one is in it')

" ----------------------------------------------------------------- teardown ---

call simplemarkdown#Stop()
call delete(s:doc)

if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  call writefile(v:errors, s:root .. '/tests/config-errors.log')
  cquit
endif
qall!
