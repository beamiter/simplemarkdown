vim9script

# =============================================================================
# simplemarkdown — Markdown preview rendered by a Rust daemon, drawn with Vim
# text properties.
#
# One preview window per tab page.  A session ties a preview window to the
# source window it is previewing and owns everything derived from the last
# render: the rows, the two-way source ⇄ row maps that drive scroll sync, the
# table of contents and the link spans.
#
# The daemon returns rows with byte-column property spans, so applying a render
# is a buffer replace plus one prop_add_list() per property class.  Grouping by
# class matters: a long document carries tens of thousands of spans, and
# prop_add() one at a time is the difference between a redraw you notice and
# one you do not.
# =============================================================================

const PROTOCOL_VERSION = 1
const RENDER_TIMEOUT_MS = 10000
# Rendering the whole buffer on every keystroke burst is cheap in Rust but not
# free in JSON; past this the preview only refreshes on write and on demand.
const HUGE_BUFFER_LINES = 20000

# Every text-property class the daemon may emit, paired with the highlight
# group it links to and the priority it draws at.  This list must match
# `simplemarkdown-daemon --classes` exactly — an unregistered property type is
# a hard prop_add() error inside a channel callback.  `make check-classes`
# proves the two agree.
const CLASSES: list<list<any>> = [
  ['H1', 'Title', 8],
  ['H2', 'Function', 8],
  ['H3', 'Identifier', 8],
  ['H4', 'Type', 8],
  ['H5', 'Constant', 8],
  ['H6', 'Comment', 8],
  ['HeadMark', 'Special', 8],
  ['HeadRule', 'Comment', 8],

  ['Bold', '', 16],
  ['Italic', '', 16],
  ['BoldItalic', '', 16],
  ['Strike', '', 16],

  ['Code', 'String', 16],
  ['CodeBlock', 'CursorLine', 1],
  ['CodeBorder', 'Comment', 8],
  ['CodeLang', 'Type', 9],
  ['CodeCont', 'NonText', 9],

  ['Link', 'Underlined', 16],
  ['LinkUrl', 'Comment', 15],
  ['Image', 'Special', 16],
  ['Footnote', 'Special', 15],

  ['Quote', 'Comment', 5],
  ['QuoteBar', 'Special', 9],
  ['AlertNote', 'MoreMsg', 12],
  ['AlertTip', 'String', 12],
  ['AlertImportant', 'Special', 12],
  ['AlertWarning', 'WarningMsg', 12],
  ['AlertCaution', 'ErrorMsg', 12],
  ['Bullet', 'Special', 9],
  ['Number', 'Number', 9],
  ['Task', 'Comment', 9],
  ['TaskDone', 'String', 9],
  ['Rule', 'Comment', 8],
  ['Term', 'Identifier', 9],

  ['TableBorder', 'Comment', 8],
  ['TableHead', 'Title', 12],

  ['Html', 'Comment', 5],

  ['SynKeyword', 'Keyword', 12],
  ['SynString', 'String', 12],
  ['SynComment', 'Comment', 12],
  ['SynNumber', 'Number', 12],
  ['SynBoolean', 'Boolean', 12],
  ['SynType', 'Type', 12],
  ['SynFunction', 'Function', 12],
  ['SynConstant', 'Constant', 12],
  ['SynOperator', 'Operator', 12],
  ['SynPunct', 'Delimiter', 12],
  ['SynVariable', 'Identifier', 12],
  ['SynProperty', 'Identifier', 12],
  ['SynPreProc', 'PreProc', 12],
  ['SynTag', 'Tag', 12],
  ['SynEscape', 'SpecialChar', 12],
  ['SynInvalid', 'Error', 12],
]

# Bold, italic, strikethrough and combinations have no conventional group to
# link to, so they are defined outright.  `highlight default` still lets a
# colour scheme or the user override them.
const ATTRIBUTES: list<list<string>> = [
  ['Bold', 'term=bold cterm=bold gui=bold'],
  ['Italic', 'term=italic cterm=italic gui=italic'],
  ['BoldItalic', 'term=bold,italic cterm=bold,italic gui=bold,italic'],
  ['Strike', 'term=strikethrough cterm=strikethrough gui=strikethrough'],
]

# preview window id (as a string) -> session
var sessions: dict<any> = {}
# in-flight render id (as a string) -> session key
var requests: dict<string> = {}
var prop_types_ready = false
var core_ready = false
var next_request_id = 0
var last_elapsed_ms = -1

# ─────────────────────────── logging ───────────────────────────

def Log(message: string)
  simplemarkdown#core#Log(message)
enddef

export def ShowLog()
  simplemarkdown#core#ShowLog()
enddef

# ─────────────────────────── backend ───────────────────────────

def SetupCore()
  if core_ready
    return
  endif
  core_ready = true
  simplemarkdown#core#Setup({
    name: 'SimpleMarkdown',
    exe: 'simplemarkdown-daemon',
    path_var: 'simplemarkdown_daemon_path',
    debug_var: 'simplemarkdown_debug',
    auto_restart: get(g:, 'simplemarkdown_auto_restart', 1) ? true : false,
    request_timeout_ms: RENDER_TIMEOUT_MS,
    handshake: {request: {type: 'ping'}, reply_type: 'pong'},
    OnReady: OnDaemonReady,
    OnExit: OnDaemonExit,
  })
enddef


def EnsureBackend(): bool
  SetupCore()
  return simplemarkdown#core#Ensure()
enddef


def OnDaemonReady(protocol: number, caps: dict<any>)
  if protocol != PROTOCOL_VERSION
    # A protocol we do not know is worse than no preview: the row and property
    # layout is exactly what changes when it is bumped.
    echohl WarningMsg
    echom printf('[SimpleMarkdown] daemon speaks protocol v%d, this plugin speaks v%d. Reinstall with ./install.sh.',
      protocol, PROTOCOL_VERSION)
    echohl None
    return
  endif
  Log(printf('daemon ready, %d capabilities', len(caps)))
  # Anything opened while the daemon was starting is still showing its
  # placeholder; now that it can answer, ask.
  for key in keys(sessions)
    Schedule(key, 0)
  endfor
enddef


def OnDaemonExit(code: number, restarting: bool)
  for key in keys(sessions)
    var session = sessions[key]
    session.pending = false
    if !restarting
      Placeholder(key, printf('Backend exited unexpectedly (code %d).', code))
    endif
  endfor
enddef


def NextId(): number
  next_request_id += 1
  return next_request_id
enddef

# ─────────────────────────── highlights ───────────────────────────

export def SetupHighlights()
  for entry in CLASSES
    var group = 'SimpleMarkdown' .. entry[0]
    if entry[1] !=# ''
      execute printf('highlight default link %s %s', group, entry[1])
    endif
  endfor
  for entry in ATTRIBUTES
    execute printf('highlight default SimpleMarkdown%s %s', entry[0], entry[1])
  endfor
  highlight default link SimpleMarkdownStatus Comment
  highlight default link SimpleMarkdownTocLevel Comment
enddef


def PropType(class: string): string
  return 'simplemarkdown:' .. class
enddef


# Property types are global and outlive every buffer, so registering them once
# is enough; a re-run after a colour scheme change would be a no-op anyway,
# because a type resolves its highlight group by name at draw time.
def EnsurePropTypes()
  if prop_types_ready
    return
  endif
  prop_types_ready = true
  for entry in CLASSES
    var name = PropType(entry[0])
    if !empty(prop_type_get(name))
      continue
    endif
    prop_type_add(name, {
      highlight: 'SimpleMarkdown' .. entry[0],
      combine: true,
      priority: entry[2],
    })
  endfor
enddef


# Exposed for the test suite, which checks the Vim and Rust class lists agree.
export def Classes(): list<string>
  return mapnew(CLASSES, (_, entry) => entry[0])
enddef

# ─────────────────────────── window helpers ───────────────────────────

def WindowInfo(winid: number): dict<any>
  if winid <= 0
    return {}
  endif
  var found = getwininfo(winid)
  return empty(found) ? {} : found[0]
enddef


def WindowExists(winid: number): bool
  var tabwin = win_id2tabwin(winid)
  return len(tabwin) >= 2 && tabwin[0] > 0 && tabwin[1] > 0
enddef


def IsPreviewBuffer(bufnr: number): bool
  return bufnr > 0 && getbufvar(bufnr, '&filetype') ==# 'simplemarkdown'
enddef


def IsMarkdownBuffer(bufnr: number): bool
  if bufnr <= 0 || IsPreviewBuffer(bufnr)
    return false
  endif
  var buftype = getbufvar(bufnr, '&buftype')
  if type(buftype) != v:t_string || buftype !=# ''
    return false
  endif
  var filetype = getbufvar(bufnr, '&filetype')
  if type(filetype) != v:t_string
    return false
  endif
  if index(get(g:, 'simplemarkdown_filetypes', []), filetype) >= 0
    return true
  endif
  # A file that has not been given a filetype yet — a fresh :edit on a machine
  # with filetype detection off — is still worth previewing.
  return filetype ==# '' && bufname(bufnr) =~? '\.\(md\|markdown\|mdown\|mkd\|mkdn\|rmd\|qmd\)$'
enddef


def FindSourceWindow(tabnr: number, preferred: number = 0): number
  if preferred > 0
    var info = WindowInfo(preferred)
    if !empty(info) && get(info, 'tabnr', 0) == tabnr && IsMarkdownBuffer(info.bufnr)
      return preferred
    endif
  endif
  for info in getwininfo()
    if get(info, 'tabnr', 0) == tabnr && IsMarkdownBuffer(info.bufnr)
      return info.winid
    endif
  endfor
  return 0
enddef

# ─────────────────────────── sessions ───────────────────────────

def PruneSessions()
  for key in keys(sessions)
    var session = sessions[key]
    if !WindowExists(session.winid) || !bufexists(session.bufnr)
      DropSession(key)
    endif
  endfor
enddef


def DropSession(key: string): dict<any>
  if !has_key(sessions, key)
    return {}
  endif
  var session = sessions[key]
  if get(session, 'timer', 0) > 0
    timer_stop(session.timer)
  endif
  for [id, owner] in items(requests)
    if owner ==# key
      simplemarkdown#core#Cancel(str2nr(id))
      simplemarkdown#core#Send({type: 'cancel', id: str2nr(id)})
      requests->remove(id)
    endif
  endfor
  sessions->remove(key)
  return session
enddef


def SessionKeyForTab(tabnr: number): string
  PruneSessions()
  for [key, session] in items(sessions)
    var info = WindowInfo(session.winid)
    if !empty(info) && get(info, 'tabnr', 0) == tabnr
      return key
    endif
  endfor
  return ''
enddef


def CurrentSessionKey(): string
  return SessionKeyForTab(tabpagenr())
enddef


def SessionForSourceBuffer(bufnr: number): string
  PruneSessions()
  for [key, session] in items(sessions)
    if session.src_bufnr == bufnr
      return key
    endif
  endfor
  return ''
enddef


def SessionForPreviewWindow(winid: number): string
  var key = string(winid)
  return has_key(sessions, key) ? key : ''
enddef

# ─────────────────────────── opening and closing ───────────────────────────

def ComputeWidth(): number
  var configured = get(g:, 'simplemarkdown_width', 0)
  var minimum = get(g:, 'simplemarkdown_min_width', 30)
  if configured > 0
    return max([minimum, min([configured, &columns - 10])])
  endif
  return max([minimum, min([&columns / 2, &columns - 10])])
enddef


def OpenForCurrentTab(): string
  var existing = CurrentSessionKey()
  if existing !=# ''
    return existing
  endif

  var src_winid = FindSourceWindow(tabpagenr(), win_getid())
  if src_winid == 0
    echohl WarningMsg
    echom '[SimpleMarkdown] no Markdown buffer in this tab page.'
    echohl None
    return ''
  endif
  var src_info = WindowInfo(src_winid)
  if empty(src_info)
    return ''
  endif
  var src_bufnr = src_info.bufnr

  var origin = win_getid()
  var side = get(g:, 'simplemarkdown_side', 'right') ==# 'left' ? 'topleft' : 'botright'
  var width = ComputeWidth()

  # `:40vnew` is a range, and Vim9 wants a colon before one inside :execute;
  # splitting then resizing sidesteps the whole question.
  noautocmd execute printf('silent %s vnew', side)
  noautocmd execute printf('vertical resize %d', width)
  var winid = win_getid()
  var bufnr = bufnr('%')

  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal nowrap nonumber norelativenumber nolist nospell
  setlocal foldcolumn=0 signcolumn=no colorcolumn=
  setlocal cursorline winfixwidth nomodeline
  setlocal filetype=simplemarkdown
  var title = printf('[SimpleMarkdown] %s',
    fnamemodify(bufname(src_bufnr), ':t') ?? '[No Name]')
  if bufexists(title)
    # A second tab page previewing the same file: :file would fail with E95
    # and leave the buffer unnamed.
    title ..= printf(' (%d)', bufnr)
  endif
  silent! execute 'file ' .. fnameescape(title)
  b:simplemarkdown_preview = 1

  if get(g:, 'simplemarkdown_default_mappings', 1)
    SetupBufferMappings()
  endif

  var key = string(winid)
  sessions[key] = {
    winid: winid,
    bufnr: bufnr,
    src_winid: src_winid,
    src_bufnr: src_bufnr,
    timer: 0,
    pending: false,
    width: 0,
    lines: [],
    src_map: [],
    row_for_src: [],
    toc: [],
    links: [],
    last_row: 0,
    syncing: false,
  }

  Placeholder(key, 'Rendering…')
  win_gotoid(origin)

  EnsurePropTypes()
  if !EnsureBackend()
    Placeholder(key, 'Backend not available. Run ./install.sh, then :SimpleMarkdownRestart.')
    return key
  endif
  Schedule(key, 0)
  return key
enddef


def SetupBufferMappings()
  nnoremap <buffer> <silent> q <Cmd>call simplemarkdown#Close()<CR>
  nnoremap <buffer> <silent> r <Cmd>call simplemarkdown#Refresh()<CR>
  nnoremap <buffer> <silent> <CR> <Cmd>call simplemarkdown#Activate()<CR>
  nnoremap <buffer> <silent> gx <Cmd>call simplemarkdown#OpenLink()<CR>
  nnoremap <buffer> <silent> gO <Cmd>call simplemarkdown#Toc()<CR>
  nnoremap <buffer> <silent> ]] <Cmd>call simplemarkdown#NextHeading(1)<CR>
  nnoremap <buffer> <silent> [[ <Cmd>call simplemarkdown#NextHeading(-1)<CR>
enddef


def CloseSession(key: string)
  var session = DropSession(key)
  if empty(session)
    return
  endif
  if WindowExists(session.winid)
    var origin = win_getid()
    if origin == session.winid
      origin = session.src_winid
    endif
    win_execute(session.winid, 'noautocmd close')
    if WindowExists(origin)
      win_gotoid(origin)
    endif
  endif
enddef

# ─────────────────────────── rendering ───────────────────────────

def Placeholder(key: string, message: string)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  if !bufexists(session.bufnr)
    return
  endif
  Replace(session.bufnr, ['', '  ' .. message])
  session.lines = []
  session.src_map = []
  session.row_for_src = []
  session.toc = []
  session.links = []
enddef


def Replace(bufnr: number, lines: list<string>)
  var info = getbufinfo(bufnr)
  if empty(info)
    return
  endif
  setbufvar(bufnr, '&modifiable', 1)
  try
    prop_clear(1, max([1, info[0].linecount]), {bufnr: bufnr})
  catch
  endtry
  # Overwrite in place and trim the tail, rather than emptying the buffer
  # first: a wipe-then-fill scrolls the preview back to the top on every
  # keystroke, which is exactly what a live preview must not do.
  silent! setbufline(bufnr, 1, lines)
  var total = getbufinfo(bufnr)[0].linecount
  if total > len(lines)
    silent! deletebufline(bufnr, len(lines) + 1, total)
  endif
  setbufvar(bufnr, '&modifiable', 0)
  setbufvar(bufnr, '&modified', 0)
enddef


def Schedule(key: string, delay: number = -1)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  if get(session, 'timer', 0) > 0
    timer_stop(session.timer)
    session.timer = 0
  endif
  var wait = delay >= 0 ? delay : get(g:, 'simplemarkdown_debounce', 120)
  if wait <= 0
    Render(key)
    return
  endif
  session.timer = timer_start(wait, (_) => {
    if has_key(sessions, key)
      sessions[key].timer = 0
      Render(key)
    endif
  })
enddef


def Options(): dict<any>
  return {
    unicode: get(g:, 'simplemarkdown_style', 'unicode') ==# 'unicode' ? true : false,
    syntax: get(g:, 'simplemarkdown_syntax', 1) ? true : false,
    wrap: get(g:, 'simplemarkdown_wrap', 1) ? true : false,
    code_wrap: get(g:, 'simplemarkdown_code_wrap', 1) ? true : false,
    show_urls: get(g:, 'simplemarkdown_show_urls', 0) ? true : false,
    frontmatter: get(g:, 'simplemarkdown_frontmatter', 1) ? true : false,
    max_width: get(g:, 'simplemarkdown_max_text_width', 0),
    tab_width: get(g:, 'simplemarkdown_tab_width', 4),
  }
enddef


def Render(key: string)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  if !WindowExists(session.winid) || !bufexists(session.src_bufnr)
    DropSession(key)
    return
  endif
  if !EnsureBackend()
    return
  endif

  var width = winwidth(session.winid)
  if width <= 0
    return
  endif
  session.width = width

  var lines = getbufline(session.src_bufnr, 1, '$')
  var id = NextId()

  # A previous render for this session is now moot; tell the daemon so it does
  # not spend a core laying out a document nobody will look at.
  for [pending, owner] in items(requests)
    if owner ==# key
      simplemarkdown#core#Cancel(str2nr(pending))
      simplemarkdown#core#Send({type: 'cancel', id: str2nr(pending)})
      requests->remove(pending)
    endif
  endfor

  requests[string(id)] = key
  session.pending = true

  var sent = simplemarkdown#core#Request({
    type: 'render',
    id: id,
    lines: lines,
    width: width,
    opts: Options(),
  }, (reply) => {
    OnRenderReply(key, reply)
  }, RENDER_TIMEOUT_MS)

  if sent == 0
    session.pending = false
    requests->remove(string(id))
  endif
enddef


def OnRenderReply(key: string, reply: dict<any>)
  var id = string(get(reply, 'id', 0))
  if has_key(requests, id)
    requests->remove(id)
  endif
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  session.pending = false

  if get(reply, 'type', '') ==# 'error' || get(reply, '_failed', false)
    var message = get(reply, 'message', 'render failed')
    Log('render error: ' .. message)
    Placeholder(key, message)
    return
  endif
  if get(reply, 'type', '') !=# 'render_result'
    return
  endif
  # The window may have been resized while this render was in flight; a render
  # laid out for the old width would show a ragged right edge until the next
  # keystroke, so drop it and let the resize handler's render land instead.
  if get(reply, 'width', 0) != winwidth(session.winid)
    Log(printf('discarding a render for width %d, the window is %d',
      get(reply, 'width', 0), winwidth(session.winid)))
    return
  endif

  last_elapsed_ms = get(reply, 'elapsed_ms', -1)
  Apply(key, reply)
enddef


def Apply(key: string, reply: dict<any>)
  var session = sessions[key]
  var rows = get(reply, 'lines', [])
  if type(rows) != v:t_list
    return
  endif

  var text: list<string> = []
  var src_map: list<number> = []
  for row in rows
    text->add(get(row, 't', ''))
    src_map->add(get(row, 's', 0))
  endfor
  if empty(text)
    text = ['']
    src_map = [0]
  endif

  Replace(session.bufnr, text)
  ApplyProps(session.bufnr, rows)

  session.lines = text
  session.src_map = src_map
  session.row_for_src = BuildSourceIndex(src_map)
  session.toc = get(reply, 'toc', [])
  session.links = get(reply, 'links', [])

  # Re-anchor on the source cursor: after an edit the row a given source line
  # maps to has usually moved.
  if get(g:, 'simplemarkdown_sync_scroll', 1)
    SyncToSource(key, true)
  endif
enddef


def ApplyProps(bufnr: number, rows: list<any>)
  EnsurePropTypes()
  # One prop_add_list() per class instead of one prop_add() per span: on a
  # 2000-row document that is thousands of calls saved per render.
  var grouped: dict<list<list<number>>> = {}
  var lnum = 0
  for row in rows
    lnum += 1
    for prop in get(row, 'p', [])
      if type(prop) != v:t_list || len(prop) < 3
        continue
      endif
      var class = prop[2]
      if !has_key(grouped, class)
        grouped[class] = []
      endif
      grouped[class]->add([lnum, prop[0], lnum, prop[0] + prop[1]])
    endfor
  endfor

  for [class, spans] in items(grouped)
    var name = PropType(class)
    if empty(prop_type_get(name))
      # A daemon newer than the plugin: skip the class rather than abort the
      # whole render on it.
      Log('unknown property class from the daemon: ' .. class)
      continue
    endif
    try
      prop_add_list({type: name, bufnr: bufnr}, spans)
    catch
      Log(printf('prop_add_list(%s) failed: %s', class, v:exception))
    endtry
  endfor
enddef


# For every source line, the preview row that best represents it.  Lines with
# no row of their own (the middle of a wrapped paragraph, a fence marker)
# inherit the row of the nearest earlier line that has one, so a cursor
# anywhere in a block lands on that block.
def BuildSourceIndex(src_map: list<number>): list<number>
  var highest = 0
  for src in src_map
    if src > highest
      highest = src
    endif
  endfor
  var index = repeat([0], highest + 1)
  var row = 0
  for src in src_map
    row += 1
    if src > 0 && index[src] == 0
      index[src] = row
    endif
  endfor
  var carried = 0
  for src in range(1, highest)
    if index[src] == 0
      index[src] = carried
    else
      carried = index[src]
    endif
  endfor
  return index
enddef

# ─────────────────────────── scroll sync ───────────────────────────

def SyncToSource(key: string, force: bool = false)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  if session.syncing || !WindowExists(session.winid) || empty(session.row_for_src)
    return
  endif
  if !WindowExists(session.src_winid)
    return
  endif

  var src_line = line('.', session.src_winid)
  var row = 0
  if src_line >= 1 && src_line < len(session.row_for_src)
    row = session.row_for_src[src_line]
  elseif src_line >= len(session.row_for_src)
    row = len(session.lines)
  endif
  if row <= 0
    return
  endif
  if !force && row == session.last_row
    return
  endif
  session.last_row = row

  session.syncing = true
  try
    win_execute(session.winid, printf('call cursor(%d, 1)', row))
    EnsureVisible(session.winid, row)
  finally
    session.syncing = false
  endtry
enddef


def SyncToPreview(key: string)
  if !get(g:, 'simplemarkdown_sync_back', 0)
    return
  endif
  var session = sessions[key]
  if session.syncing || !WindowExists(session.src_winid)
    return
  endif
  # The cursor is exactly where the last source→preview sync put it, so this
  # move is that sync's echo, not the user.  The `syncing` flag cannot catch
  # it: CursorMoved fires after win_execute() has returned and cleared it.
  if line('.') == session.last_row
    return
  endif
  var src = SourceLineForRow(session, line('.'))
  if src <= 0
    return
  endif
  session.syncing = true
  try
    win_execute(session.src_winid, printf('call cursor(%d, 1)', src))
  finally
    session.syncing = false
  endtry
enddef


def SourceLineForRow(session: dict<any>, row: number): number
  var index = row - 1
  while index >= 0
    if index < len(session.src_map) && session.src_map[index] > 0
      return session.src_map[index]
    endif
    index -= 1
  endwhile
  return 0
enddef


# Scroll only when the row has left the window, and then place it a third of
# the way down rather than centring: a preview that jumps on every cursor move
# is unreadable.
def EnsureVisible(winid: number, row: number)
  var info = WindowInfo(winid)
  if empty(info)
    return
  endif
  var top = get(info, 'topline', 1)
  var height = get(info, 'height', 0)
  if height <= 0
    return
  endif
  var bottom = top + height - 1
  if row >= top && row <= bottom
    return
  endif
  var wanted = max([1, row - height / 3])
  win_execute(winid, printf('call winrestview({"topline": %d, "lnum": %d})', wanted, row))
enddef

# ─────────────────────────── events ───────────────────────────

export def OnTextChanged(bufnr: number)
  var key = SessionForSourceBuffer(bufnr)
  if key ==# ''
    return
  endif
  if getbufinfo(bufnr)[0].linecount > HUGE_BUFFER_LINES && mode() =~# '^[iR]'
    # Live rendering a novel on every keystroke is not a service to anybody;
    # the write and :SimpleMarkdownRefresh paths still work.
    return
  endif
  Schedule(key)
enddef


export def OnCursorMoved(winid: number)
  PruneSessions()
  var preview = SessionForPreviewWindow(winid)
  if preview !=# ''
    SyncToPreview(preview)
    return
  endif
  if !get(g:, 'simplemarkdown_sync_scroll', 1)
    return
  endif
  for [key, session] in items(sessions)
    if session.src_winid == winid
      SyncToSource(key)
      return
    endif
  endfor
enddef


export def OnContextChanged()
  PruneSessions()
  var key = CurrentSessionKey()
  if key ==# ''
    return
  endif
  var session = sessions[key]
  var winid = win_getid()
  if winid == session.winid
    return
  endif
  # Following the user to another Markdown buffer in the same tab is what makes
  # the preview feel like part of the editor rather than a pinned snapshot.
  if !IsMarkdownBuffer(bufnr('%'))
    return
  endif
  if session.src_bufnr == bufnr('%') && session.src_winid == winid
    return
  endif
  if IsPreviewBuffer(bufnr('%'))
    return
  endif
  session.src_winid = winid
  session.src_bufnr = bufnr('%')
  session.last_row = 0
  Schedule(key, 0)
enddef


export def OnResized()
  PruneSessions()
  for [key, session] in items(sessions)
    if winwidth(session.winid) != session.width
      Schedule(key, 30)
    endif
  endfor
enddef


export def OnWinClosed(winid: number)
  var key = string(winid)
  if has_key(sessions, key)
    DropSession(key)
    return
  endif
  # The source window went away: without one there is nothing to preview.
  if !get(g:, 'simplemarkdown_auto_close', 1)
    return
  endif
  for [session_key, session] in items(sessions)
    if session.src_winid == winid
      var replacement = FindSourceWindow(get(WindowInfo(session.winid), 'tabnr', tabpagenr()))
      var info = WindowInfo(replacement)
      if replacement > 0 && replacement != session.winid && !empty(info)
        session.src_winid = replacement
        session.src_bufnr = info.bufnr
        Schedule(session_key, 0)
      else
        CloseSession(session_key)
      endif
    endif
  endfor
enddef


export def OnBufferWipeout(bufnr: number)
  for [key, session] in items(sessions)
    if session.bufnr == bufnr
      DropSession(key)
    elseif session.src_bufnr == bufnr && get(g:, 'simplemarkdown_auto_close', 1)
      CloseSession(key)
    endif
  endfor
enddef


export def MaybeAutoOpen()
  if !get(g:, 'simplemarkdown_auto_open', 0)
    return
  endif
  if !IsMarkdownBuffer(bufnr('%'))
    return
  endif
  if CurrentSessionKey() !=# ''
    return
  endif
  OpenForCurrentTab()
enddef


export def Stop()
  for key in keys(sessions)
    DropSession(key)
  endfor
  if core_ready
    simplemarkdown#core#Stop()
  endif
enddef

# ─────────────────────────── commands ───────────────────────────

export def Open()
  OpenForCurrentTab()
enddef


export def Close()
  var key = CurrentSessionKey()
  if key !=# ''
    CloseSession(key)
  endif
enddef


export def Toggle()
  var key = CurrentSessionKey()
  if key ==# ''
    OpenForCurrentTab()
  else
    CloseSession(key)
  endif
enddef


export def Refresh()
  var key = CurrentSessionKey()
  if key ==# ''
    return
  endif
  Schedule(key, 0)
enddef


export def Focus()
  var key = CurrentSessionKey()
  if key ==# ''
    key = OpenForCurrentTab()
  endif
  if key !=# '' && has_key(sessions, key)
    win_gotoid(sessions[key].winid)
  endif
enddef


export def Resize(argument: string)
  var key = CurrentSessionKey()
  var wanted = str2nr(trim(argument))
  if wanted > 0
    g:simplemarkdown_width = max([get(g:, 'simplemarkdown_min_width', 30), wanted])
  endif
  if key ==# ''
    return
  endif
  var session = sessions[key]
  win_execute(session.winid, printf('vertical resize %d', ComputeWidth()))
  Schedule(key, 0)
enddef


export def CompleteStyle(lead: string, _line: string, _pos: number): list<string>
  return filter(['unicode', 'ascii'], (_, style) => style =~# '^' .. lead)
enddef


export def SetStyle(argument: string)
  var wanted = trim(argument)
  if wanted ==# ''
    echo printf('SimpleMarkdown style: %s', get(g:, 'simplemarkdown_style', 'unicode'))
    return
  endif
  if index(['unicode', 'ascii'], wanted) < 0
    echohl ErrorMsg
    echom '[SimpleMarkdown] style must be "unicode" or "ascii".'
    echohl None
    return
  endif
  g:simplemarkdown_style = wanted
  for key in keys(sessions)
    Schedule(key, 0)
  endfor
enddef


export def Restart()
  SetupCore()
  simplemarkdown#core#Restart()
  for key in keys(sessions)
    Placeholder(key, 'Restarting the backend…')
  endfor
enddef


export def Health()
  SetupCore()
  var lines = simplemarkdown#core#HealthLines()
  add(lines, printf('[%s] protocol: plugin speaks v%d',
    simplemarkdown#core#Protocol() == PROTOCOL_VERSION || !simplemarkdown#core#Ready() ? 'OK' : 'ERROR',
    PROTOCOL_VERSION))
  add(lines, printf('[INFO] preview sessions: %d', len(sessions)))
  if last_elapsed_ms >= 0
    add(lines, printf('[INFO] last render: %dms', last_elapsed_ms))
  endif
  add(lines, printf('[%s] text properties: %s',
    has('textprop') ? 'OK' : 'ERROR', has('textprop') ? 'available' : 'missing'))
  for line in lines
    echo line
  endfor
enddef


export def DebugStatus(): dict<any>
  var health = simplemarkdown#core#Health()
  return {
    daemon: health,
    protocol_expected: PROTOCOL_VERSION,
    sessions: len(sessions),
    in_flight: len(requests),
    last_render_ms: last_elapsed_ms,
    style: get(g:, 'simplemarkdown_style', 'unicode'),
  }
enddef

# ─────────────────────────── preview-buffer actions ───────────────────────────

def CurrentPreviewSession(): string
  var key = SessionForPreviewWindow(win_getid())
  if key !=# ''
    return key
  endif
  return CurrentSessionKey()
enddef


def LinkAtCursor(session: dict<any>, row: number, col: number): dict<any>
  for link in session.links
    if get(link, 'row', 0) != row
      continue
    endif
    var start = get(link, 'col', 0)
    if col >= start && col < start + get(link, 'len', 0)
      return link
    endif
  endfor
  # Nothing under the cursor exactly: take the first link on the row, which is
  # what a user pressing <CR> on a line with one link means.
  for link in session.links
    if get(link, 'row', 0) == row
      return link
    endif
  endfor
  return {}
enddef


export def OpenLink()
  var key = CurrentPreviewSession()
  if key ==# ''
    return
  endif
  var session = sessions[key]
  var link = LinkAtCursor(session, line('.'), col('.'))
  if empty(link)
    echohl WarningMsg
    echom '[SimpleMarkdown] no link on this line.'
    echohl None
    return
  endif
  Follow(session, link.href)
enddef


def Follow(session: dict<any>, href: string)
  if href =~? '^\(https\?\|ftp\|mailto\):'
    if exists('*netrw#BrowseX')
      call netrw#BrowseX(href, 0)
    elseif executable('xdg-open')
      call job_start(['xdg-open', href])
    elseif executable('open')
      call job_start(['open', href])
    else
      echo href
    endif
    return
  endif

  # A relative link is a file in the source document's directory; opening it in
  # the source window keeps the preview where it is.
  var base = fnamemodify(bufname(session.src_bufnr), ':p:h')
  var target = href
  var anchor = ''
  var hash = stridx(target, '#')
  if hash >= 0
    anchor = target[hash + 1 : ]
    target = target[0 : hash - 1]
  endif
  if target ==# ''
    JumpToHeading(session, anchor)
    return
  endif
  var path = target =~# '^/' ? target : base .. '/' .. target
  if !filereadable(path)
    echohl WarningMsg
    echom printf('[SimpleMarkdown] cannot open %s', path)
    echohl None
    return
  endif
  if WindowExists(session.src_winid)
    win_gotoid(session.src_winid)
  endif
  execute 'edit ' .. fnameescape(path)
enddef


def JumpToHeading(session: dict<any>, anchor: string)
  var wanted = tolower(substitute(anchor, '-', ' ', 'g'))
  for entry in session.toc
    if tolower(get(entry, 'text', '')) ==# wanted
      GoToRow(session, get(entry, 'row', 0), get(entry, 'src', 0))
      return
    endif
  endfor
enddef


def GoToRow(session: dict<any>, row: number, src: number)
  if row > 0 && WindowExists(session.winid)
    win_execute(session.winid, printf('call cursor(%d, 1)', row))
    EnsureVisible(session.winid, row)
  endif
  if src > 0 && WindowExists(session.src_winid)
    win_execute(session.src_winid, printf('call cursor(%d, 1)', src))
  endif
enddef


# <CR>: follow a link if the cursor is on one, otherwise put the source cursor
# on the line that produced this row and go there.
export def Activate()
  var key = CurrentPreviewSession()
  if key ==# ''
    return
  endif
  var session = sessions[key]
  var row = line('.')
  var column = col('.')
  var link = LinkAtCursor(session, row, column)
  var start = get(link, 'col', 0)
  var on_link = !empty(link) && column >= start && column < start + get(link, 'len', 0)
  if on_link
    Follow(session, link.href)
    return
  endif

  var src = SourceLineForRow(session, row)
  if src <= 0
    return
  endif
  if !WindowExists(session.src_winid)
    return
  endif
  win_gotoid(session.src_winid)
  cursor(src, 1)
  normal! zz
enddef


export def NextHeading(direction: number)
  var key = CurrentPreviewSession()
  if key ==# ''
    return
  endif
  var session = sessions[key]
  if empty(session.toc)
    return
  endif
  var row = line('.')
  if direction > 0
    for entry in session.toc
      if get(entry, 'row', 0) > row
        GoToRow(session, entry.row, 0)
        return
      endif
    endfor
  else
    for entry in reverse(copy(session.toc))
      if get(entry, 'row', 0) < row
        GoToRow(session, entry.row, 0)
        return
      endif
    endfor
  endif
enddef


export def Toc()
  var key = CurrentPreviewSession()
  if key ==# ''
    key = OpenForCurrentTab()
  endif
  if key ==# '' || !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  if empty(session.toc)
    echohl WarningMsg
    echom '[SimpleMarkdown] no headings in this document.'
    echohl None
    return
  endif

  var items: list<string> = []
  for entry in session.toc
    items->add(printf('%s%s', repeat('  ', get(entry, 'level', 1) - 1), get(entry, 'text', '')))
  endfor

  if !has('popupwin')
    # No popups: the location list is the honest fallback, not an error.
    var entries: list<dict<any>> = []
    for entry in session.toc
      entries->add({bufnr: session.src_bufnr, lnum: get(entry, 'src', 1), text: get(entry, 'text', '')})
    endfor
    setloclist(win_id2win(session.src_winid), entries, ' ')
    lopen
    return
  endif

  popup_menu(items, {
    title: ' Contents ',
    padding: [0, 1, 0, 1],
    border: [],
    maxheight: max([5, &lines - 8]),
    callback: (_, index) => {
      TocChosen(key, index)
    },
  })
enddef


def TocChosen(key: string, index: number)
  if index <= 0 || !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  var entry = get(session.toc, index - 1, {})
  if empty(entry)
    return
  endif
  GoToRow(session, get(entry, 'row', 0), get(entry, 'src', 0))
  if WindowExists(session.src_winid)
    win_gotoid(session.src_winid)
    normal! zz
  endif
enddef
