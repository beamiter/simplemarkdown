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
#
# Since protocol v2 most renders do not arrive as a whole document at all.  The
# daemon remembers the rows it last sent for a session and answers with the
# splice that turns them into the new ones, so a keystroke that reflows one
# paragraph replaces two rows and repaints two rows' worth of properties rather
# than four thousand.  The session keeps its own copy of the row → source map
# and splices it the same way; `total` is the checksum that catches the two
# copies drifting apart, and a mismatch asks for a whole document back rather
# than redrawing something that is already wrong.
# =============================================================================

const PROTOCOL_VERSION = 2
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
  ['CodeNumber', 'LineNr', 9],

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
  # Behind the row, like CodeBlock: priority 1 so the borders and cell content
  # both draw over it.
  ['TableRowAlt', 'CursorLine', 1],

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
# How the last renders were applied.  Worth counting: a patch path that has
# quietly stopped patching is invisible otherwise — the preview stays correct,
# it just gets slow again.
var patched_renders = 0
var full_renders = 0
var last_patch_rows = -1

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
  # The wash behind the block the source cursor is in.  Linked rather than
  # defined so it follows whatever the colour scheme already uses to say
  # "here"; it is applied at priority 0, under everything else.
  highlight default link SimpleMarkdownFocusBlock CursorLine
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
  # The daemon is holding this session's last rows so it could patch them; the
  # window is gone, so nothing will.
  if core_ready
    simplemarkdown#core#Send({type: 'forget', session: key})
  endif
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


def SessionKeysForSourceBuffer(bufnr: number): list<string>
  PruneSessions()
  var result: list<string> = []
  for [key, session] in items(sessions)
    if session.src_bufnr == bufnr
      add(result, key)
    endif
  endfor
  return result
enddef


def SessionForPreviewWindow(winid: number): string
  var key = string(winid)
  return has_key(sessions, key) ? key : ''
enddef


# The document a window is about, which for a preview window is the buffer it
# is previewing rather than the buffer it holds.  The external preview asks so
# that `:SimpleMarkdownExternal` does the same thing from either side of the
# split.
export def SourceBufferFor(winid: number): number
  var key = SessionForPreviewWindow(winid)
  return key ==# '' ? 0 : sessions[key].src_bufnr
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
    # A row map is safe for source-editing actions only while it still belongs
    # to this exact source state and the newest render requested by the session.
    src_map_bufnr: 0,
    src_map_changedtick: -1,
    src_map_generation: 0,
    render_generation: 0,
    row_for_src: [],
    toc: [],
    links: [],
    blocks: [],
    last_row: 0,
    last_block: [],
    syncing: false,
    # False whenever this session's copy of the last render is not something a
    # patch can be applied to.  The daemon resynchronises on the next render.
    rendered: false,
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
  nnoremap <buffer> <silent> x <Cmd>call simplemarkdown#ToggleTask()<CR>
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
  session.src_map_bufnr = 0
  session.src_map_changedtick = -1
  session.src_map_generation = 0
  session.row_for_src = []
  session.toc = []
  session.links = []
  session.blocks = []
  session.last_block = []
  # The buffer now holds a message, not a render; nothing can be spliced into
  # it, and the daemon has to be told to start the session over.
  session.rendered = false
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


def ScheduleSourceSessions(bufnr: number, delay: number = -1)
  for key in SessionKeysForSourceBuffer(bufnr)
    Schedule(key, delay)
  endfor
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
    code_numbers: get(g:, 'simplemarkdown_code_numbers', 0) ? true : false,
    table_zebra: get(g:, 'simplemarkdown_table_zebra', 0) ? true : false,
    task_progress: get(g:, 'simplemarkdown_task_progress', 1) ? true : false,
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

  var source_bufnr = session.src_bufnr
  var source_changedtick: number = getbufvar(source_bufnr, 'changedtick')
  var lines = getbufline(source_bufnr, 1, '$')
  var id = NextId()
  session.render_generation = get(session, 'render_generation', 0) + 1
  var generation: number = session.render_generation

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
    session: key,
    # Only claim a patch can be applied when this session is actually holding
    # the rows the daemon thinks it sent.
    incremental: session.rendered && get(g:, 'simplemarkdown_incremental', 1) ? true : false,
  }, (reply) => {
    OnRenderReply(key, generation, source_bufnr, source_changedtick, reply)
  }, RENDER_TIMEOUT_MS)

  if sent == 0
    session.pending = false
    requests->remove(string(id))
  endif
enddef


def OnRenderReply(
    key: string,
    generation: number,
    source_bufnr: number,
    source_changedtick: number,
    reply: dict<any>)
  var id = string(get(reply, 'id', 0))
  if has_key(requests, id)
    requests->remove(id)
  endif
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  if generation != get(session, 'render_generation', 0)
    Log(printf('discarding stale render generation %d for %s (current %d)',
      generation, key, get(session, 'render_generation', 0)))
    return
  endif
  session.pending = false

  # The source may change after getbufline() but before the worker replies.  A
  # row map from that snapshot must never be attached to the edited buffer: in
  # particular, preview `x` could otherwise toggle a different task line.
  if session.src_bufnr != source_bufnr
      || getbufvar(source_bufnr, 'changedtick') != source_changedtick
    Log(printf('discarding render generation %d for stale source tick %d',
      generation, source_changedtick))
    session.rendered = false
    Schedule(key, 0)
    return
  endif

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
  if Apply(key, reply)
    session.src_map_bufnr = source_bufnr
    session.src_map_changedtick = source_changedtick
    session.src_map_generation = generation
  endif
enddef


def Apply(key: string, reply: dict<any>): bool
  var session = sessions[key]
  var patch = get(reply, 'patch', {})
  var incremental = type(patch) == v:t_dict && !empty(patch)
  var applied = incremental ? ApplyPatch(session, patch) : ApplyFull(session, reply)
  if !applied
    if incremental
      # The patch did not fit what this session is holding.  Start over rather
      # than leave the buffer showing a document neither side agrees on.
      Log(printf('render %s: patch %s does not fit %d rows; resynchronising',
        key, string(patch), len(session.lines)))
      session.rendered = false
      Schedule(key, 0)
    endif
    return false
  endif
  if incremental
    patched_renders += 1
    last_patch_rows = len(get(patch, 'l', []))
  else
    full_renders += 1
    last_patch_rows = -1
  endif

  # `total` is the daemon's count of the rows this render produced.  If the
  # buffer disagrees the two copies have drifted, and the only honest fix is a
  # whole document — patching further would compound the error.
  var total = get(reply, 'total', -1)
  if total >= 0 && total != len(session.lines)
    Log(printf('render %s: %d rows applied, the daemon rendered %d; resynchronising',
      key, len(session.lines), total))
    session.rendered = false
    Schedule(key, 0)
    return false
  endif

  session.rendered = true
  session.toc = get(reply, 'toc', [])
  session.links = get(reply, 'links', [])
  session.blocks = get(reply, 'blocks', [])
  session.row_for_src = BuildSourceIndex(session.src_map)

  # Re-anchor on the source cursor: after an edit the row a given source line
  # maps to has usually moved.
  if get(g:, 'simplemarkdown_sync_scroll', 1)
    SyncToSource(key, true)
  endif
  HighlightBlock(key, true)
  return true
enddef


def ApplyFull(session: dict<any>, reply: dict<any>): bool
  var rows = get(reply, 'lines', [])
  if type(rows) != v:t_list
    return false
  endif

  var text: list<string> = []
  var src_map: list<number> = []
  for row in rows
    text->add(get(row, 't', ''))
    src_map->add(get(row, 's', 0))
  endfor

  # A buffer cannot hold nothing, so a document that rendered no rows at all —
  # an empty file, or one of only blank lines — is shown as a single blank one.
  # The session's copy stays empty regardless: it has to match what the daemon
  # says it sent, or the row-count check below it would fail for ever.
  Replace(session.bufnr, empty(text) ? [''] : text)
  ApplyProps(session.bufnr, rows, 1)

  session.lines = text
  session.src_map = src_map
  return true
enddef


# Replace `del` rows starting at `from` with the patch's rows, in the buffer
# and in the row → source map together.  Text properties move with the lines
# Vim shifts, so only the spliced-in rows need repainting — which is the whole
# reason this path exists.
def ApplyPatch(session: dict<any>, patch: dict<any>): bool
  var from = get(patch, 'from', 0)
  var del = get(patch, 'del', 0)
  var rows = get(patch, 'l', [])
  if from < 1 || del < 0 || type(rows) != v:t_list
    return false
  endif
  if del == 0 && empty(rows)
    # Nothing moved.  The daemon sends this when a keystroke did not change the
    # rendering at all — a space inside a fence, a character in a comment.
    return true
  endif
  # A patch that reaches past what this session is holding cannot be applied to
  # it; say so rather than splicing at the wrong place.
  if from - 1 + del > len(session.lines)
    return false
  endif
  # The buffer is showing the single blank line that stands in for a document
  # that rendered nothing, and its line count does not match the session's
  # empty row list.  Splicing into that would be off by one; a full render is
  # both correct and, for a document this size, free.
  if empty(session.lines)
    return false
  endif

  var text: list<string> = []
  var src_map: list<number> = []
  for row in rows
    text->add(get(row, 't', ''))
    src_map->add(get(row, 's', 0))
  endfor

  var bufnr = session.bufnr
  if !bufexists(bufnr)
    return false
  endif
  setbufvar(bufnr, '&modifiable', 1)
  try
    if del > 0
      try
        prop_clear(from, from + del - 1, {bufnr: bufnr})
      catch
      endtry
    endif

    # Overwrite what both sides have, then insert or delete the remainder.
    # Rewriting in place where possible is what keeps the window from
    # scrolling: appendbufline() and deletebufline() move the rows below.
    var overlap = min([del, len(text)])
    if overlap > 0
      silent! setbufline(bufnr, from, text[0 : overlap - 1])
    endif
    if len(text) > del
      silent! appendbufline(bufnr, from + del - 1, text[del : ])
    elseif del > len(text)
      silent! deletebufline(bufnr, from + len(text), from + del - 1)
    endif
  finally
    setbufvar(bufnr, '&modifiable', 0)
    setbufvar(bufnr, '&modified', 0)
  endtry

  ApplyProps(bufnr, rows, from)

  session.lines = Splice(session.lines, from, del, text)
  session.src_map = Splice(session.src_map, from, del, src_map)
  return true
enddef


# `list[from - 1 : from - 1 + del] = replacement`, spelled out because Vim's
# slice indices are end-relative when negative and `list[0 : -1]` is not the
# empty list.
def Splice(list_: list<any>, from: number, del: number, replacement: list<any>): list<any>
  var head = from > 1 ? list_[0 : from - 2] : []
  var rest = from - 1 + del
  var tail = rest < len(list_) ? list_[rest : ] : []
  return head + replacement + tail
enddef


def ApplyProps(bufnr: number, rows: list<any>, first_row: number)
  EnsurePropTypes()
  # One prop_add_list() per class instead of one prop_add() per span: on a
  # 2000-row document that is thousands of calls saved per render.
  var grouped: dict<list<list<number>>> = {}
  var lnum = first_row - 1
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

  # Sorted, not in whatever order the classes happened to appear: two properties
  # that start at the same column and share a priority are drawn in the order
  # they were added, so an unsorted pass would paint a full render and a patched
  # one differently for the same rows.
  for class in sort(keys(grouped))
    var spans = grouped[class]
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

# ─────────────────────────── the current block ───────────────────────────

# 'cursorline' marks one row, but a preview row is not a unit of anything: a
# paragraph is six rows, a fenced block is however many, and the row the cursor
# happens to sit on says nothing about which of them the user is editing.  The
# daemon indexes every top-level block by both its rendered extent and the
# source lines it came from, so the block containing the source cursor can be
# painted whole.
const FOCUS_TYPE = 'simplemarkdown:FocusBlock'

def EnsureFocusType()
  if empty(prop_type_get(FOCUS_TYPE))
    # Below every content class: this is a wash behind the text, not a mark on
    # it.  `combine` keeps the syntax colours showing through.
    prop_type_add(FOCUS_TYPE, {
      highlight: 'SimpleMarkdownFocusBlock',
      combine: true,
      priority: 0,
    })
  endif
enddef


# The block whose source range contains `src_line`, as `[row, rows]`.
def BlockForSource(session: dict<any>, src_line: number): list<number>
  var best: list<number> = []
  for block in session.blocks
    if type(block) != v:t_list || len(block) < 4
      continue
    endif
    if src_line >= block[2] && src_line <= block[3]
      # Blocks are emitted in document order and do not overlap, so the first
      # match is the answer; keep looking only to prefer a later, tighter one.
      best = [block[0], block[1]]
    elseif block[2] > src_line
      break
    endif
  endfor
  return best
enddef


def HighlightBlock(key: string, force: bool = false)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  if !get(g:, 'simplemarkdown_focus_block', 1) || !bufexists(session.bufnr)
    return
  endif
  if !WindowExists(session.src_winid)
    return
  endif

  var wanted = BlockForSource(session, line('.', session.src_winid))
  if !force && wanted == session.last_block
    return
  endif

  EnsureFocusType()
  if !empty(session.last_block)
    try
      prop_remove({type: FOCUS_TYPE, bufnr: session.bufnr, all: true})
    catch
    endtry
  endif
  session.last_block = wanted
  if empty(wanted)
    return
  endif

  var first = wanted[0]
  var last = min([wanted[0] + wanted[1] - 1, len(session.lines)])
  var spans: list<list<number>> = []
  for row in range(first, last)
    # +1 on the end column so the wash reaches the end of the row rather than
    # stopping one cell short of it.
    spans->add([row, 1, row, max([2, len(session.lines[row - 1]) + 1])])
  endfor
  if empty(spans)
    return
  endif
  try
    prop_add_list({type: FOCUS_TYPE, bufnr: session.bufnr}, spans)
  catch
    Log('focus block: ' .. v:exception)
  endtry
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


# A link in the preview shows its text, not its target — that is the whole
# point of rendering it — which leaves no way to tell `[docs](./a.md)` from
# `[docs](https://example.com/a.md)` short of pressing <CR> and finding out.
# Echoing the target of the link under the cursor answers that without
# spending a row on every URL in the document, which `show_urls` does.
var last_hint = ''

def HintLink(session: dict<any>)
  if !get(g:, 'simplemarkdown_link_hint', 1)
    return
  endif
  var link = LinkAtCursor(session, line('.'), col('.'), true)
  var href = get(link, 'href', '')
  if href ==# last_hint
    return
  endif
  last_hint = href
  if href ==# ''
    # Only clear a message this function put there; anything else on the line
    # belongs to whatever printed it.
    echo ''
    return
  endif
  # Truncated to the command line, which would otherwise turn a long URL into
  # a hit-enter prompt on every cursor move.
  var room = max([20, &columns - 12])
  echo '[link] ' .. (strdisplaywidth(href) > room
    ? strcharpart(href, 0, room - 1) .. '…'
    : href)
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
  var info = getbufinfo(bufnr)
  if empty(info) || empty(SessionKeysForSourceBuffer(bufnr))
    return
  endif
  if info[0].linecount > HUGE_BUFFER_LINES && mode() =~# '^[iR]'
    # Live rendering a novel on every keystroke is not a service to anybody;
    # the write and :SimpleMarkdownRefresh paths still work.
    return
  endif
  ScheduleSourceSessions(bufnr)
enddef


export def OnCursorMoved(winid: number)
  PruneSessions()
  var preview = SessionForPreviewWindow(winid)
  if preview !=# ''
    HintLink(sessions[preview])
    SyncToPreview(preview)
    return
  endif
  if !get(g:, 'simplemarkdown_sync_scroll', 1)
    return
  endif
  for [key, session] in items(sessions)
    if session.src_winid == winid
      SyncToSource(key)
      HighlightBlock(key)
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
  session.src_map_bufnr = 0
  session.src_map_changedtick = -1
  session.src_map_generation = 0
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
        session.src_map_bufnr = 0
        session.src_map_changedtick = -1
        session.src_map_generation = 0
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
  simplemarkdown#external#OnBufferWipeout(bufnr)
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
  # Servers started for this Vim must not outlive it holding their ports.
  simplemarkdown#external#StopAll()
  if core_ready
    simplemarkdown#core#Stop()
  endif
enddef

# ─────────────────────────── commands ───────────────────────────

export def Open()
  OpenForCurrentTab()
enddef


export def Close(all: bool = false)
  PruneSessions()
  if all
    # Work from identities captured before the first :close. WinClosed and
    # user autocommands may mutate the live dictionary; a newly-created
    # session that happens to reuse a window id must not be mistaken for one
    # that existed when :SimpleMarkdownClose! began.
    var snapshot: list<dict<any>> = []
    for key in keys(sessions)
      snapshot->add({key: key, bufnr: sessions[key].bufnr})
    endfor
    for item in snapshot
      if has_key(sessions, item.key)
            \ && get(sessions[item.key], 'bufnr', 0) == item.bufnr
        CloseSession(item.key)
      endif
    endfor
    return
  endif
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


export def Refresh(all: bool = false)
  PruneSessions()
  if all
    for session_key in keys(sessions)
      Schedule(session_key, 0)
    endfor
    return
  endif
  var key = CurrentSessionKey()
  if key ==# ''
    return
  endif
  # A manual refresh is about the document, not the tab that happened to issue
  # it. Keep every preview of that source revision in step; :...Refresh! is
  # available when a global option change should redraw unrelated documents.
  ScheduleSourceSessions(sessions[key].src_bufnr, 0)
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
  const styles = ['unicode', 'ascii']
  var wanted = trim(argument)
  if wanted ==# ''
    # No argument cycles rather than reporting, matching :SimpleMinimapStyle.
    # It is what makes a single key worth binding: printing the value you are
    # already looking at is not an action.
    var current = index(styles, get(g:, 'simplemarkdown_style', 'unicode'))
    wanted = styles[current < 0 ? 0 : (current + 1) % len(styles)]
  endif
  if index(styles, wanted) < 0
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
  add(lines, printf('[INFO] renders: %d incremental, %d full%s',
    patched_renders, full_renders,
    last_patch_rows >= 0 ? printf(' (last patch: %d rows)', last_patch_rows) : ''))
  add(lines, printf('[%s] text properties: %s',
    has('textprop') ? 'OK' : 'ERROR', has('textprop') ? 'available' : 'missing'))
  lines += simplemarkdown#external#HealthLines()
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
    patched_renders: patched_renders,
    full_renders: full_renders,
    last_patch_rows: last_patch_rows,
    external: simplemarkdown#external#Status(),
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


# Byte offset of the `[ ]` / `[x]` marker in a task-list source line. The
# prefix accepts nested bullets, ordered items, and block-quote markers, while
# refusing a checkbox that merely appears later in ordinary prose.
def TaskMarker(text: string): number
  return match(text,
    '\C^\s*\%(\%([*+-]\|\d\+[.)]\|>\)\s\+\)*\zs\[[ xX]\]\ze\%(\s\|$\)')
enddef


def TaskWarning(message: string)
  echohl WarningMsg
  echom '[SimpleMarkdown] ' .. message
  echohl None
enddef


# The preview text and src_map are one render snapshot.  A source edit, source
# switch, or newer render request makes that snapshot unsafe for an editing
# action even though it may remain useful to look at until the refresh lands.
def SourceMapCurrent(session: dict<any>): bool
  var source_bufnr = get(session, 'src_bufnr', 0)
  return get(session, 'rendered', false)
    && source_bufnr > 0
    && bufexists(source_bufnr)
    && get(session, 'src_map_bufnr', 0) == source_bufnr
    && get(session, 'src_map_changedtick', -1) == getbufvar(source_bufnr, 'changedtick')
    && get(session, 'src_map_generation', 0) == get(session, 'render_generation', -1)
enddef


# Toggle a source checkbox from either side of the preview. Preview rows use
# their exact source mapping rather than the nearest-row fallback: generated
# task-progress rows deliberately have source 0 and must never toggle the last
# real task above them.
export def ToggleTask()
  var key = CurrentPreviewSession()
  if key ==# '' || !has_key(sessions, key)
    TaskWarning('no preview session in this tab page.')
    return
  endif
  var session = sessions[key]
  var src = 0
  if win_getid() == session.winid
    if !SourceMapCurrent(session)
      TaskWarning('preview mapping is stale; refreshing.')
      ScheduleSourceSessions(session.src_bufnr, 0)
      return
    endif
    var row = line('.') - 1
    src = row >= 0 && row < len(session.src_map) ? session.src_map[row] : 0
  elseif bufnr('%') == session.src_bufnr
    src = line('.')
  endif
  if src <= 0
    TaskWarning('no task on this preview row.')
    return
  endif
  if !getbufvar(session.src_bufnr, '&modifiable')
    TaskWarning('source buffer is not modifiable.')
    return
  endif
  var source = get(getbufline(session.src_bufnr, src), 0, '')
  var marker = TaskMarker(source)
  if marker < 0
    TaskWarning('source line is not a task item.')
    return
  endif
  var checked = source[marker + 1] !=# ' '
  var replacement = checked ? ' ' : 'x'
  var updated = strpart(source, 0, marker + 1) .. replacement
        \ .. strpart(source, marker + 2)
  if setbufline(session.src_bufnr, src, updated) != 0
    TaskWarning('could not update the source buffer.')
    return
  endif
  ScheduleSourceSessions(session.src_bufnr, 0)
  echo '[SimpleMarkdown] task ' .. (checked ? 'unchecked' : 'checked')
enddef


# `exact` refuses the row fallback below.  Pressing <CR> on a row with one link
# means that link even if the cursor is a column off; a hint that appeared for
# the whole row would claim the row is a link when most of it is prose.
def LinkAtCursor(session: dict<any>, row: number, col: number, exact: bool = false): dict<any>
  for link in session.links
    if get(link, 'row', 0) != row
      continue
    endif
    var start = get(link, 'col', 0)
    if col >= start && col < start + get(link, 'len', 0)
      return link
    endif
  endfor
  if exact
    return {}
  endif
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
  FollowHref(href, session.src_bufnr, session)
enddef


# Follow `href` as it is written in the document held by `src_bufnr`.
#
# `session` is the preview session to move within when the link is a bare
# `#anchor`; it is empty when the link was followed from the source buffer,
# where there may be no preview at all and the source cursor moves instead.
def FollowHref(href: string, src_bufnr: number, session: dict<any> = {})
  if href =~? '^\(https\?\|ftp\|mailto\):'
    simplemarkdown#external#Browse(href)
    return
  endif

  # strpart(), not `href[0 : hash - 1]`: a negative Vim slice index counts from
  # the end, so a bare `#anchor` — hash at 0, hence `[0 : -1]` — sliced that way
  # is the whole string, and the anchor is then looked for as a file called
  # `#anchor` in the document's directory.
  var hash = stridx(href, '#')
  var target = hash >= 0 ? strpart(href, 0, hash) : href
  var anchor = hash >= 0 ? strpart(href, hash + 1) : ''

  if target ==# ''
    if anchor ==# ''
      return
    endif
    if !empty(session)
      JumpToHeading(session, anchor)
    else
      JumpToAnchorHere(anchor)
    endif
    return
  endif

  # A relative link is a file in the source document's directory; opening it in
  # the source window keeps the preview where it is.
  var base = fnamemodify(bufname(src_bufnr), ':p:h')
  var path = target =~# '^/' ? target : base .. '/' .. target
  if !filereadable(path)
    echohl WarningMsg
    echom printf('[SimpleMarkdown] cannot open %s', path)
    echohl None
    return
  endif
  if !empty(session) && WindowExists(session.src_winid)
    win_gotoid(session.src_winid)
  endif
  execute 'edit ' .. fnameescape(path)
  # `other.md#section` means that section, not the top of the file.
  if anchor !=# ''
    JumpToAnchorHere(anchor)
  endif
enddef


def JumpToHeading(session: dict<any>, anchor: string)
  var entry = TocEntryForAnchor(session.toc, anchor)
  if empty(entry)
    AnchorWarning(anchor)
    return
  endif
  GoToRow(session, get(entry, 'row', 0), get(entry, 'src', 0))
enddef


# The heading `#anchor` names, in three passes.  The daemon's own slug first,
# because only it de-duplicates repeated headings the way GitHub does; then the
# slug computed here, so a daemon older than the `anchor` field still resolves
# links; and last the prose match this used to do alone, so a link written
# against a heading's words rather than its slug keeps working.
def TocEntryForAnchor(toc: list<any>, anchor: string): dict<any>
  var wanted = tolower(anchor)
  for entry in toc
    if get(entry, 'anchor', '') ==# wanted
      return entry
    endif
  endfor
  for entry in toc
    if Slug(get(entry, 'text', '')) ==# wanted
      return entry
    endif
  endfor
  var prose = substitute(wanted, '-', ' ', 'g')
  for entry in toc
    if tolower(get(entry, 'text', '')) ==# prose
      return entry
    endif
  endfor
  return {}
enddef


# GitHub's heading anchor, the Vim counterpart of `slug()` in render.rs: the
# daemon slugs the document it rendered, but `other.md#section` lands in a
# buffer no daemon has seen and has to be resolved there too.  ASCII is treated
# identically; a non-ASCII character is kept rather than classified, which is
# right for the letters and ideographs headings are made of and wrong only for
# non-ASCII punctuation, where the prose fallback still applies.
def Slug(text: string): string
  var out = ''
  for ch in split(trim(text), '\zs')
    if ch =~# '^[[:alnum:]_-]$' || char2nr(ch) > 127
      out ..= tolower(ch)
    elseif ch =~# '^\s$'
      out ..= '-'
    endif
  endfor
  return out
enddef


# Every ATX and Setext heading in `buf`, as `[line, text]`.  Fenced code is
# skipped, or a `# comment` in a shell block would answer to `#comment`.
def HeadingsIn(buf: number): list<list<any>>
  var lines = getbufline(buf, 1, '$')
  var found: list<list<any>> = []
  var fence = ''
  var lnum = 0
  for line in lines
    lnum += 1
    var marker = trim(matchstr(line, '^\s\{0,3}\%(`\{3,}\|\~\{3,}\)'))
    if fence !=# ''
      if marker !=# '' && marker[0] ==# fence[0]
        fence = ''
      endif
      continue
    elseif marker !=# ''
      fence = marker
      continue
    endif
    var atx = matchlist(line, '^\s\{0,3}#\{1,6}\s\+\(.\{-}\)\s*#*\s*$')
    if !empty(atx)
      found->add([lnum, atx[1]])
      continue
    endif
    # A Setext underline names the paragraph line above it.  `---` under a
    # paragraph really is a heading in CommonMark, so only a blank or
    # block-marker line above rules it out.
    if lnum > 1 && line =~# '^\s\{0,3}\%(=\+\|-\+\)\s*$'
      var above = lines[lnum - 2]
      if above !~# '^\s*$'
          && above !~# '^\s\{0,3}\%([-*+>#]\|\d\+[.)]\)\s'
          && above !~# '^\s\{0,3}\%(`\{3,}\|\~\{3,}\)'
        found->add([lnum - 1, trim(above)])
      endif
    endif
  endfor
  return found
enddef


# Enough inline markup stripped to match what the renderer's `plain()` would
# have produced for the same heading, since that is what the daemon slugs.
def PlainInline(text: string): string
  var out = substitute(text, '!\=\[\([^]]*\)\]([^()]*)', '\1', 'g')
  out = substitute(out, '!\=\[\([^]]*\)\]\[[^]]*\]', '\1', 'g')
  out = substitute(out, '[`*]\+\|\~\~', '', 'g')
  return trim(out)
enddef


# The source line of the heading `anchor` names in `buf`, or 0.
def HeadingLineForAnchor(buf: number, anchor: string): number
  var wanted = tolower(anchor)
  var prose = substitute(wanted, '-', ' ', 'g')
  var seen: dict<number> = {}
  var fallback = 0
  for [lnum, raw] in HeadingsIn(buf)
    var text = PlainInline(raw)
    var base = Slug(text)
    # The daemon's de-duplication, repeated here: `#notes-1` is the second
    # `## Notes`, not a heading that happens to end in `-1`.
    seen[base] = get(seen, base, 0) + 1
    var unique = seen[base] == 1 ? base : printf('%s-%d', base, seen[base] - 1)
    if unique ==# wanted
      return lnum
    endif
    if fallback == 0 && tolower(text) ==# prose
      fallback = lnum
    endif
  endfor
  return fallback
enddef


def JumpToAnchorHere(anchor: string)
  var lnum = HeadingLineForAnchor(bufnr('%'), anchor)
  if lnum <= 0
    AnchorWarning(anchor)
    return
  endif
  cursor(lnum, 1)
  normal! zz
enddef


def AnchorWarning(anchor: string)
  echohl WarningMsg
  echom printf('[SimpleMarkdown] no heading matching #%s', anchor)
  echohl None
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
  # No second exactness test: LinkAtCursor() already falls back to the row's
  # link on purpose, and re-testing here threw that fallback away, so <CR> and
  # `gx` disagreed about the same row.
  var link = LinkAtCursor(session, row, column)
  if !empty(link)
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


# Inline links, in the order they are tried.  Parsed rather than asked of the
# daemon: following a link from the source buffer must work with no preview
# open, and a round trip would make the jump wait on a render.
const SOURCE_LINK_PATTERNS: list<string> = [
  '!\=\[[^]]*\]([^()]*)',
  '!\=\[[^]]*\]\[[^]]*\]',
  '<\a[[:alnum:]+.-]*:[^ \t<>]\+>',
  '\%(https\?\|ftp\)://[^ \t<>"''`]\+',
]


# `[label]: dest` anywhere in the document.  Labels are case-insensitive and
# the definition may sit above or below the reference, so the whole buffer is
# searched.
def LinkDefinition(buf: number, label: string): string
  var wanted = tolower(trim(label))
  if wanted ==# ''
    return ''
  endif
  for line in getbufline(buf, 1, '$')
    var parts = matchlist(line, '^\s\{0,3}\[\([^]]\+\)\]:\s*\(\S\+\)')
    if !empty(parts) && tolower(trim(parts[1])) ==# wanted
      return parts[2] =~# '^<.*>$' ? parts[2][1 : -2] : parts[2]
    endif
  endfor
  return ''
enddef


def HrefOfMatch(matched: string, buf: number): string
  if matched =~# '^<'
    return matched[1 : -2]
  endif
  if matched =~# '^!\=\[[^]]*\]('
    # A destination may carry a title — `(./a.md "A")` — and may be wrapped in
    # angle brackets so that it can contain spaces.
    var dest = trim(matchstr(matched, '](\zs[^()]*\ze)$'))
    if dest =~# '^<.*>$'
      return dest[1 : -2]
    endif
    return matchstr(dest, '^\S*')
  endif
  if matched =~# '^!\=\[[^]]*\]\['
    var label = matchstr(matched, '\]\[\zs[^]]*\ze\]$')
    if label ==# ''
      # A collapsed reference — `[label][]` — names itself.
      label = matchstr(matched, '^!\=\[\zs[^]]*\ze\]')
    endif
    return LinkDefinition(buf, label)
  endif
  return matched
enddef


def SourceLinkAtCursor(buf: number, lnum: number, column: number): string
  var line = get(getbufline(buf, lnum), 0, '')
  var first = ''
  var first_at = -1
  for pattern in SOURCE_LINK_PATTERNS
    var start = 0
    while start <= len(line)
      var [matched, from, to] = matchstrpos(line, pattern, start)
      if from < 0
        break
      endif
      var href = HrefOfMatch(matched, buf)
      if href !=# ''
        # Byte columns, 1-based, the same convention as the preview's spans.
        if column >= from + 1 && column <= to
          return href
        endif
        if first_at < 0 || from < first_at
          first = href
          first_at = from
        endif
      endif
      start = to > from ? to : from + 1
    endwhile
  endfor
  # Nothing under the cursor: the line's leftmost link, which is what a user
  # pressing the key on a line with one link means — the same fallback the
  # preview makes in LinkAtCursor().
  return first
enddef


# `:SimpleMarkdownFollow`.  In the preview this is `gx`; in a Markdown source
# buffer it follows the link the cursor is on, so `nmap <buffer> gf` can be
# bound to it and a docs tree can be walked without opening a preview at all.
export def FollowUnderCursor()
  if SessionForPreviewWindow(win_getid()) !=# ''
    OpenLink()
    return
  endif
  var buf = bufnr('%')
  var href = SourceLinkAtCursor(buf, line('.'), col('.'))
  if href ==# ''
    echohl WarningMsg
    echom '[SimpleMarkdown] no link under the cursor.'
    echohl None
    return
  endif
  FollowHref(href, buf)
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
