vim9script

if exists('g:loaded_simplemarkdown')
  finish
endif
g:loaded_simplemarkdown = 1

if !has('job') || !has('channel')
  echohl WarningMsg
  echom '[SimpleMarkdown] Vim must be compiled with +job and +channel.'
  echohl None
  finish
endif

# The whole preview is drawn with text properties; without them there is no
# degraded mode worth offering.
if !has('textprop')
  echohl WarningMsg
  echom '[SimpleMarkdown] Vim must be compiled with +textprop.'
  echohl None
  finish
endif

# Every documented option, given its default where it is unset and brought back
# inside its documented type and range where it is not — so that the code, the
# tests and a user's `:echo g:simplemarkdown_style` all see the value actually
# in force.  The table that says what each option may hold lives beside the
# code that reads them, in autoload/simplemarkdown.vim, so there is one answer
# rather than one here and a different one at render time; and what had to be
# corrected is remembered rather than silently applied, because a `g:` rewritten
# in place is a mistake with nothing left to find it by.
simplemarkdown#NormalizeConfig()

command! SimpleMarkdown simplemarkdown#Toggle()
command! SimpleMarkdownOpen simplemarkdown#Open()
command! -bang SimpleMarkdownClose simplemarkdown#Close(<bang>0 ? true : false)
command! -bang SimpleMarkdownRefresh simplemarkdown#Refresh(<bang>0 ? true : false)
command! SimpleMarkdownFocus simplemarkdown#Focus()
command! SimpleMarkdownToc simplemarkdown#Toc()
command! SimpleMarkdownToggleTask simplemarkdown#ToggleTask()
command! SimpleMarkdownFollow simplemarkdown#FollowUnderCursor()
command! SimpleMarkdownFormatTable simplemarkdown#FormatTable()
# The structural edits take a range.  Without one they act on the section the
# cursor is in — heading and subsections together — rather than on its line
# alone, because a heading shifted out from under its subsections describes a
# document that is not there.
command! -range SimpleMarkdownPromote simplemarkdown#Promote(<line1>, <line2>)
command! -range SimpleMarkdownDemote simplemarkdown#Demote(<line1>, <line2>)
command! -range SimpleMarkdownRenumber simplemarkdown#Renumber(<line1>, <line2>)
command! SimpleMarkdownLint simplemarkdown#Lint()
command! SimpleMarkdownRestart simplemarkdown#Restart()
command! SimpleMarkdownHealth simplemarkdown#Health()
command! SimpleMarkdownLog simplemarkdown#ShowLog()
command! SimpleMarkdownDebug echo simplemarkdown#DebugStatus()
command! -nargs=? SimpleMarkdownResize simplemarkdown#Resize(<q-args>)
command! -nargs=? -complete=customlist,simplemarkdown#CompleteStyle
  \ SimpleMarkdownStyle simplemarkdown#SetStyle(<q-args>)

# The browser preview.  A bang on :SimpleMarkdownExternalClose stops every
# server, not just this buffer's.
command! SimpleMarkdownExternal simplemarkdown#external#Toggle()
command! SimpleMarkdownExternalOpen simplemarkdown#external#Open()
command! -bang SimpleMarkdownExternalClose simplemarkdown#external#Close(<bang>0 ? true : false)
command! SimpleMarkdownExternalStatic simplemarkdown#external#Static()

nnoremap <silent> <Plug>(simplemarkdown-toggle) <Cmd>SimpleMarkdown<CR>
nnoremap <silent> <Plug>(simplemarkdown-focus) <Cmd>SimpleMarkdownFocus<CR>
nnoremap <silent> <Plug>(simplemarkdown-toc) <Cmd>SimpleMarkdownToc<CR>
nnoremap <silent> <Plug>(simplemarkdown-toggle-task) <Cmd>SimpleMarkdownToggleTask<CR>
nnoremap <silent> <Plug>(simplemarkdown-follow) <Cmd>SimpleMarkdownFollow<CR>
nnoremap <silent> <Plug>(simplemarkdown-format-table) <Cmd>SimpleMarkdownFormatTable<CR>
nnoremap <silent> <Plug>(simplemarkdown-promote) <Cmd>SimpleMarkdownPromote<CR>
nnoremap <silent> <Plug>(simplemarkdown-demote) <Cmd>SimpleMarkdownDemote<CR>
nnoremap <silent> <Plug>(simplemarkdown-renumber) <Cmd>SimpleMarkdownRenumber<CR>
# Visual mode goes through `:`, which is what fills the `'<,'>` in — a <Cmd>
# mapping stays in Visual mode and the marks are not set yet when it runs.
xnoremap <silent> <Plug>(simplemarkdown-promote) :SimpleMarkdownPromote<CR>
xnoremap <silent> <Plug>(simplemarkdown-demote) :SimpleMarkdownDemote<CR>
xnoremap <silent> <Plug>(simplemarkdown-renumber) :SimpleMarkdownRenumber<CR>
nnoremap <silent> <Plug>(simplemarkdown-lint) <Cmd>SimpleMarkdownLint<CR>
nnoremap <silent> <Plug>(simplemarkdown-next-heading) <Cmd>call simplemarkdown#NextHeading(1)<CR>
nnoremap <silent> <Plug>(simplemarkdown-prev-heading) <Cmd>call simplemarkdown#NextHeading(-1)<CR>

# What the preview window binds by default.  They are <Plug>s so that a user
# who wants `q` somewhere else, or wants the preview's `x` on a different key,
# can say so without reaching into the plugin — see
# g:simplemarkdown_preview_mappings.
nnoremap <silent> <Plug>(simplemarkdown-preview-close) <Cmd>call simplemarkdown#Close()<CR>
nnoremap <silent> <Plug>(simplemarkdown-preview-refresh) <Cmd>call simplemarkdown#Refresh()<CR>
nnoremap <silent> <Plug>(simplemarkdown-preview-activate) <Cmd>call simplemarkdown#Activate()<CR>
nnoremap <silent> <Plug>(simplemarkdown-preview-help) <Cmd>call simplemarkdown#PreviewHelp()<CR>
nnoremap <silent> <Plug>(simplemarkdown-external) <Cmd>SimpleMarkdownExternal<CR>
var default_mapping: number = simplemarkdown#Setting('simplemarkdown_set_default_mapping')
if default_mapping && maparg('<leader>md', 'n') ==# ''
  nmap <silent> <leader>md <Plug>(simplemarkdown-toggle)
endif

simplemarkdown#SetupHighlights()

augroup SimpleMarkdown
  autocmd!
  autocmd TextChanged,TextChangedI,BufWritePost *
    \ try | call simplemarkdown#OnTextChanged(str2nr(expand('<abuf>'))) | catch | endtry
  autocmd BufWritePost * try | call simplemarkdown#OnWritten(str2nr(expand('<abuf>'))) | catch | endtry
  autocmd CursorMoved,CursorMovedI *
    \ try | call simplemarkdown#OnCursorMoved(win_getid()) | catch | endtry
  autocmd BufEnter,WinEnter * try | call simplemarkdown#OnContextChanged() | catch | endtry
  autocmd WinClosed * try | call simplemarkdown#OnWinClosed(str2nr(expand('<amatch>'))) | catch | endtry
  autocmd BufWipeout * try | call simplemarkdown#OnBufferWipeout(str2nr(expand('<abuf>'))) | catch | endtry
  autocmd ColorScheme * try | call simplemarkdown#SetupHighlights() | catch | endtry
  autocmd VimLeavePre * try | call simplemarkdown#Stop() | catch | endtry
  autocmd FileType * try | call simplemarkdown#MaybeAutoOpen() | catch | endtry
  autocmd FileType * try | call simplemarkdown#SetupFolding() | catch | endtry
  autocmd VimEnter * try | call simplemarkdown#MaybeAutoOpen() | catch | endtry
  if exists('##WinResized')
    autocmd WinResized * try | call simplemarkdown#OnResized() | catch | endtry
  endif
  if exists('##OptionSet')
    autocmd OptionSet filetype,buftype try | call simplemarkdown#OnContextChanged() | catch | endtry
  endif
  # SimpleRemote fills a remote:// buffer from a channel callback and says so
  # with this event; it is not a TextChanged, and FileType does not fire again
  # for a re-read.  Registered whether or not SimpleRemote is installed: an
  # event nothing fires costs nothing.
  autocmd User SimpleRemoteBufferRead
    \ try | call simplemarkdown#OnRemoteBufferRead(get(get(g:, 'simpleremote_event', {}), 'bufnr', 0)) | catch | endtry
augroup END
