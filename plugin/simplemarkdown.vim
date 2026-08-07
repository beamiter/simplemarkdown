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

def ClampNumber(value: any, fallback: number, minimum: number, maximum: number): number
  if type(value) != v:t_number
    return fallback
  endif
  return min([maximum, max([minimum, value])])
enddef


def Flag(value: any, fallback: number): number
  if type(value) == v:t_bool
    return value ? 1 : 0
  endif
  if type(value) == v:t_number
    return value == 0 ? 0 : 1
  endif
  return fallback
enddef


def Choice(value: any, fallback: string, allowed: list<string>): string
  if type(value) == v:t_string && index(allowed, value) >= 0
    return value
  endif
  return fallback
enddef


def Strings(value: any, fallback: list<string>): list<string>
  if type(value) != v:t_list
    return fallback
  endif
  return filter(copy(value), (_, item) => type(item) == v:t_string)
enddef


# 0 means "half the window"; the preview is more useful side by side than
# squeezed into a fixed column count that does not suit every terminal.
g:simplemarkdown_width = ClampNumber(get(g:, 'simplemarkdown_width', 0), 0, 0, 400)
g:simplemarkdown_min_width = ClampNumber(get(g:, 'simplemarkdown_min_width', 30), 30, 12, 400)
# Caps the text column inside the preview, independent of the window: prose is
# hard to read at 200 columns even when the window offers them.
g:simplemarkdown_max_text_width = ClampNumber(get(g:, 'simplemarkdown_max_text_width', 0), 0, 0, 400)
g:simplemarkdown_debounce = ClampNumber(get(g:, 'simplemarkdown_debounce', 120), 120, 0, 5000)
g:simplemarkdown_tab_width = ClampNumber(get(g:, 'simplemarkdown_tab_width', 4), 4, 1, 16)
g:simplemarkdown_side = Choice(get(g:, 'simplemarkdown_side', 'right'), 'right', ['left', 'right'])
g:simplemarkdown_style = Choice(get(g:, 'simplemarkdown_style', 'unicode'), 'unicode', ['unicode', 'ascii'])

g:simplemarkdown_syntax = Flag(get(g:, 'simplemarkdown_syntax', 1), 1)
g:simplemarkdown_wrap = Flag(get(g:, 'simplemarkdown_wrap', 1), 1)
g:simplemarkdown_code_wrap = Flag(get(g:, 'simplemarkdown_code_wrap', 1), 1)
g:simplemarkdown_show_urls = Flag(get(g:, 'simplemarkdown_show_urls', 0), 0)
# Number the lines inside fenced code blocks.  Off by default: the gutter comes
# out of the code's own columns, and next to the source they are already there.
g:simplemarkdown_code_numbers = Flag(get(g:, 'simplemarkdown_code_numbers', 0), 0)
# Tint alternate table body rows.  Off by default because it depends on having
# a CursorLine your colour scheme makes visible but not loud.
g:simplemarkdown_table_zebra = Flag(get(g:, 'simplemarkdown_table_zebra', 0), 0)
# Close a task list of two or more checkboxes with `2/5 done`.
g:simplemarkdown_task_progress = Flag(get(g:, 'simplemarkdown_task_progress', 1), 1)
# Echo the target of the link under the cursor while moving through the preview.
g:simplemarkdown_link_hint = Flag(get(g:, 'simplemarkdown_link_hint', 1), 1)
g:simplemarkdown_frontmatter = Flag(get(g:, 'simplemarkdown_frontmatter', 1), 1)
# Answer a render with just the rows that moved.  On by default; turning it off
# makes every render a whole document, which is only worth doing to rule the
# patch path out while diagnosing something.
g:simplemarkdown_incremental = Flag(get(g:, 'simplemarkdown_incremental', 1), 1)
# Wash the whole block the source cursor is in, not just one preview row.
g:simplemarkdown_focus_block = Flag(get(g:, 'simplemarkdown_focus_block', 1), 1)
g:simplemarkdown_sync_scroll = Flag(get(g:, 'simplemarkdown_sync_scroll', 1), 1)
g:simplemarkdown_sync_back = Flag(get(g:, 'simplemarkdown_sync_back', 0), 0)
g:simplemarkdown_auto_open = Flag(get(g:, 'simplemarkdown_auto_open', 0), 0)
g:simplemarkdown_auto_close = Flag(get(g:, 'simplemarkdown_auto_close', 1), 1)
g:simplemarkdown_auto_restart = Flag(get(g:, 'simplemarkdown_auto_restart', 1), 1)
g:simplemarkdown_set_default_mapping = Flag(get(g:, 'simplemarkdown_set_default_mapping', 1), 1)
g:simplemarkdown_default_mappings = Flag(get(g:, 'simplemarkdown_default_mappings', 1), 1)
g:simplemarkdown_debug = Flag(get(g:, 'simplemarkdown_debug', 0), 0)

const DEFAULT_FILETYPES = ['markdown', 'markdown.pandoc', 'pandoc', 'rmd', 'vimwiki', 'ghmarkdown']
# exists(), not get() with a [] fallback: an unset variable and a variable the
# user set to [] are indistinguishable through get(), and defaulting the unset
# case to [] leaves the plugin recognising no filetype at all.
g:simplemarkdown_filetypes = exists('g:simplemarkdown_filetypes')
  ? Strings(g:simplemarkdown_filetypes, DEFAULT_FILETYPES)
  : DEFAULT_FILETYPES

var configured_daemon_path = get(g:, 'simplemarkdown_daemon_path', '')
g:simplemarkdown_daemon_path = type(configured_daemon_path) == v:t_string ? configured_daemon_path : ''

# ─── the external (browser) preview, served by `omd` ───
# Off the daemon's path entirely: omd is a separate binary the user installs,
# and nothing here runs unless a :SimpleMarkdownExternal command is invoked.
var configured_omd_path = get(g:, 'simplemarkdown_omd_path', '')
g:simplemarkdown_omd_path = type(configured_omd_path) == v:t_string ? configured_omd_path : ''
g:simplemarkdown_omd_host = Choice(get(g:, 'simplemarkdown_omd_host', '127.0.0.1'),
  '127.0.0.1', ['127.0.0.1', 'localhost', '0.0.0.0', '::'])
# The first port tried; a busy one moves the search up, it does not fail.
g:simplemarkdown_omd_port = ClampNumber(get(g:, 'simplemarkdown_omd_port', 3030), 3030, 1024, 65500)
g:simplemarkdown_omd_args = Strings(get(g:, 'simplemarkdown_omd_args', []), [])
g:simplemarkdown_omd_browser = Flag(get(g:, 'simplemarkdown_omd_browser', 1), 1)
g:simplemarkdown_omd_browser_delay = ClampNumber(
  get(g:, 'simplemarkdown_omd_browser_delay', 250), 250, 0, 5000)

command! SimpleMarkdown simplemarkdown#Toggle()
command! SimpleMarkdownOpen simplemarkdown#Open()
command! -bang SimpleMarkdownClose simplemarkdown#Close(<bang>0 ? true : false)
command! -bang SimpleMarkdownRefresh simplemarkdown#Refresh(<bang>0 ? true : false)
command! SimpleMarkdownFocus simplemarkdown#Focus()
command! SimpleMarkdownToc simplemarkdown#Toc()
command! SimpleMarkdownToggleTask simplemarkdown#ToggleTask()
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
nnoremap <silent> <Plug>(simplemarkdown-external) <Cmd>SimpleMarkdownExternal<CR>
if g:simplemarkdown_set_default_mapping && maparg('<leader>md', 'n') ==# ''
  nmap <silent> <leader>md <Plug>(simplemarkdown-toggle)
endif

simplemarkdown#SetupHighlights()

augroup SimpleMarkdown
  autocmd!
  autocmd TextChanged,TextChangedI,BufWritePost *
    \ try | call simplemarkdown#OnTextChanged(str2nr(expand('<abuf>'))) | catch | endtry
  autocmd CursorMoved,CursorMovedI *
    \ try | call simplemarkdown#OnCursorMoved(win_getid()) | catch | endtry
  autocmd BufEnter,WinEnter * try | call simplemarkdown#OnContextChanged() | catch | endtry
  autocmd WinClosed * try | call simplemarkdown#OnWinClosed(str2nr(expand('<amatch>'))) | catch | endtry
  autocmd BufWipeout * try | call simplemarkdown#OnBufferWipeout(str2nr(expand('<abuf>'))) | catch | endtry
  autocmd ColorScheme * try | call simplemarkdown#SetupHighlights() | catch | endtry
  autocmd VimLeavePre * try | call simplemarkdown#Stop() | catch | endtry
  autocmd FileType * try | call simplemarkdown#MaybeAutoOpen() | catch | endtry
  autocmd VimEnter * try | call simplemarkdown#MaybeAutoOpen() | catch | endtry
  if exists('##WinResized')
    autocmd WinResized * try | call simplemarkdown#OnResized() | catch | endtry
  endif
  if exists('##OptionSet')
    autocmd OptionSet filetype,buftype try | call simplemarkdown#OnContextChanged() | catch | endtry
  endif
augroup END
