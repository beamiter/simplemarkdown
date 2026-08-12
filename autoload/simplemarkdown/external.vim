vim9script

# =============================================================================
# simplemarkdown#external — the out-of-editor preview.
#
# The in-Vim preview and this one answer different questions.  The buffer
# preview is for reading and navigating a document while you write it, over
# SSH, in tmux, with the cursors tied together.  This one is for seeing what
# the document will actually look like: real proportional type, images that are
# images, a heading that is a heading rather than a row of `#`.
#
# It used to be a thin supervisor around `omd`, an external binary the user
# installed themselves.  That was the right shape until the day someone wanted
# the page to look different: omd's stylesheet is `include_str!`d into its
# binary, so the whole appearance of this plugin's browser preview — the font,
# the colours, whether it followed the system's light or dark setting — was a
# decision another project had made and this one could not revisit.  A preview
# you cannot restyle is not a preview you own.
#
# So the daemon renders the HTML and serves it now, and this file is what it
# always was minus the process supervision: it opens a preview, keeps it fed
# with the buffer, ties the two cursors together and takes it down again.  The
# server lives in the daemon we were already running, which is also what makes
# the page follow the buffer rather than the file — omd watched the file with
# notify(7) and could only ever reload on `:w`.
#
# One server per source buffer, each on its own port, all of them stopped when
# Vim exits.
# =============================================================================

# How far above the configured port the daemon looks for a free one.  Passed
# rather than searched here: the process that binds the socket is the only one
# whose answer cannot be stale by the time it is used.
const PORT_ATTEMPTS = 24
# A `serve` costs a render of the whole document before it can answer, so it is
# given more room than an ordinary request.
const OPEN_TIMEOUT_MS = 8000
# Holding `j` moves the cursor faster than a browser can animate a scroll to
# each line it passes through.  One message per this many milliseconds, with the
# last position always sent, is smooth at the far end and still lands within a
# frame of the key being released.
const CURSOR_THROTTLE_MS = 60
# How long a scroll the *page* asked for suppresses the cursor messages this
# side would otherwise answer it with.  Without it the two ends chase each
# other: the browser reports a line, Vim moves to it, CursorMoved reports it
# back, and the page scrolls again.
const SYNC_BACK_QUIET_MS = 400

# source bufnr (as a string) -> preview
var previews: dict<any> = {}
# Buffers whose `serve` is still in flight.  Opening one takes a render of the
# whole document before the daemon can answer, which is long enough for a user
# to press the key twice — and the second one, with nothing in `previews` yet to
# stop it, would start a second server this side could never name again.
var opening: dict<bool> = {}

def Log(message: string)
  simplemarkdown#core#Log('external: ' .. message)
enddef


def Warn(message: string)
  echohl WarningMsg
  echom '[SimpleMarkdown] ' .. message
  echohl None
enddef


def Now(): number
  return float2nr(reltimefloat(reltime()) * 1000)
enddef

# ─────────────────────────── the browser ───────────────────────────

# Shared with the in-Vim preview's `gx`/<CR> link handling: opening a URL is
# the one thing both previews need and neither should reimplement.
export def Browse(url: string): bool
  if exists('*netrw#BrowseX')
    try
      netrw#BrowseX(url, 0)
      return true
    catch
      # netrw is present but unhappy (a stripped $BROWSER, a headless box);
      # the platform openers below are still worth trying.
      Log('netrw#BrowseX failed: ' .. v:exception)
    endtry
  endif
  for opener in [['xdg-open'], ['open'], ['wslview'], ['cmd.exe', '/c', 'start', '']]
    if executable(opener[0])
      job_start(opener + [url])
      return true
    endif
  endfor
  echo url
  return false
enddef

# ─────────────────────────── the page ───────────────────────────

# Everything about the page that is a user's choice rather than the document's.
# Sent whole on `serve` and on `html`, and not again: an update carries the
# document, and re-declaring the theme on every keystroke would be JSON the
# daemon parses for nothing.
def PageOptions(): dict<any>
  return {
    syntax: simplemarkdown#Setting('simplemarkdown_syntax') ? true : false,
    frontmatter: simplemarkdown#Setting('simplemarkdown_frontmatter') ? true : false,
    theme: simplemarkdown#Setting('simplemarkdown_browser_theme'),
    math: simplemarkdown#Setting('simplemarkdown_browser_math'),
    math_url: simplemarkdown#Setting('simplemarkdown_browser_math_url'),
    max_width: simplemarkdown#Setting('simplemarkdown_browser_max_width'),
    live: simplemarkdown#Setting('simplemarkdown_browser_live') ? true : false,
    follow: simplemarkdown#Setting('simplemarkdown_browser_sync') ? true : false,
    sync_back: simplemarkdown#Setting('simplemarkdown_browser_sync_back') ? true : false,
  }
enddef

# The second directory the preview may serve files from, or '' for none.
#
# Interlocked with the bind address rather than merely documented: widening the
# tree is a reasonable thing to want on your own machine and a poor thing to do
# by accident on `0.0.0.0`, and the setting that widens it is not the one that
# decides who can reach it.
def AssetRoot(host: string): string
  var configured: string = simplemarkdown#Setting('simplemarkdown_browser_root')
  if configured ==# ''
    return ''
  endif
  if host !=# '127.0.0.1' && host !=# 'localhost'
    Warn(printf('g:simplemarkdown_browser_root is ignored on %s: '
      .. 'it would serve that directory to everyone who can reach the port.', host))
    return ''
  endif
  var expanded = fnamemodify(expand(configured), ':p')
  if !isdirectory(expanded)
    Warn('g:simplemarkdown_browser_root is not a directory: ' .. configured)
    return ''
  endif
  return expanded
enddef

# ─────────────────────────── sessions ───────────────────────────

def SessionKey(bufnr: number): string
  return 'external:' .. bufnr
enddef


def Prune()
  for key in keys(previews)
    if !bufexists(str2nr(key))
      Discard(key)
    endif
  endfor
enddef


# Drop what this side is holding for a preview.  Split out of Discard()
# because the daemon has two ways of being told — one session, or all of them —
# and because a daemon that has already exited has to be forgotten without
# being told anything at all.
def Forget(key: string): dict<any>
  if !has_key(previews, key)
    return {}
  endif
  var preview = previews->remove(key)
  for name in ['timer', 'cursor_timer']
    if get(preview, name, 0) > 0
      timer_stop(preview[name])
    endif
  endfor
  return preview
enddef


def Discard(key: string)
  var preview = Forget(key)
  if !empty(preview)
    simplemarkdown#core#Send({type: 'serve_stop', session: preview.session})
  endif
enddef


def TargetBuffer(): number
  var bufnr = bufnr('%')
  # Invoked from inside the preview window, the document the user means is the
  # one being previewed, not the preview buffer.
  var source = simplemarkdown#SourceBufferFor(win_getid())
  return source > 0 ? source : bufnr
enddef


def Describe(bufnr: number): string
  return fnamemodify(bufname(bufnr), ':t') ?? '[No Name]'
enddef


def PreviewFor(session: string): dict<any>
  for preview in values(previews)
    if preview.session ==# session
      return preview
    endif
  endfor
  return {}
enddef


# The daemon, started the way the in-Vim preview starts it, and refused with
# the same explanation when the binary is older than this plugin.  A skew shows
# up here as a `serve` the daemon answers with an error from inside a callback,
# which is a poor place to read one.
def Ready(): bool
  if !simplemarkdown#EnsureDaemon()
    return false
  endif
  var skew = simplemarkdown#DaemonSkew()
  if skew !=# ''
    Warn(skew)
    return false
  endif
  return true
enddef

# ─────────────────────────── commands ───────────────────────────

export def Open()
  Prune()
  var bufnr = TargetBuffer()
  var key = string(bufnr)

  if has_key(previews, key)
    # Already serving: the useful thing to do is put the tab back in front of
    # the user, not refuse.
    Browse(previews[key].url)
    return
  endif
  if has_key(opening, key)
    echo '[SimpleMarkdown] the browser preview for this buffer is still starting.'
    return
  endif

  var path = fnamemodify(bufname(bufnr), ':p')
  if path ==# ''
    # The buffer's own text is what gets served, so an unwritten one is fine —
    # but a document with no path has no directory to resolve `![](./x.png)`
    # against and no name to put in the title bar, and inventing one would put
    # the preview somewhere the user cannot predict.
    Warn('the browser preview needs a named buffer; :file or :w it first.')
    return
  endif

  if !Ready()
    return
  endif

  var host: string = simplemarkdown#Setting('simplemarkdown_browser_host')
  var base: number = simplemarkdown#Setting('simplemarkdown_browser_port')
  var session = SessionKey(bufnr)
  var root = AssetRoot(host)

  opening[key] = true
  var sent = simplemarkdown#core#Request({
    type: 'serve',
    session: session,
    path: path,
    lines: getbufline(bufnr, 1, '$'),
    root: root,
    host: host,
    port: base,
    attempts: PORT_ATTEMPTS,
    page: PageOptions(),
  }, (reply) => OnServed(bufnr, path, session, reply), OPEN_TIMEOUT_MS)

  if sent == 0
    opening->remove(key)
    Warn('could not ask the daemon to serve this buffer.')
  endif
enddef


def OnServed(bufnr: number, path: string, session: string, reply: dict<any>)
  var wanted = get(opening, string(bufnr), true)
  opening->remove(string(bufnr))

  if get(reply, '_failed', false) || get(reply, 'type', '') !=# 'serve_result'
    # A timeout is the dangerous one: the request was not withdrawn, so the
    # daemon may bind the port a moment after we have given up, and a server
    # nothing on this side knows about is a port held until Vim exits.  Saying
    # stop costs one line and covers both that and the case where it never
    # started.
    simplemarkdown#core#Send({type: 'serve_stop', session: session})
    # A daemon too old to serve answers a request type it has never heard of
    # with an error, from inside this callback, which is a poor place to read
    # one — so it is translated here into the sentence that says what to do.
    var detail = simplemarkdown#core#Ready() && !simplemarkdown#core#HasCap('serve')
      ? simplemarkdown#DaemonSkew()
      : get(reply, 'message', 'no answer from the daemon')
    Warn('browser preview failed: ' .. detail)
    return
  endif
  if !wanted || !bufexists(bufnr)
    # Withdrawn while the port was being bound — by :SimpleMarkdownExternalClose
    # or by the buffer going away.  Either way nothing is going to feed this
    # server, so it must not be left holding the port.
    simplemarkdown#core#Send({type: 'serve_stop', session: session})
    return
  endif

  var url: string = get(reply, 'url', '')
  previews[string(bufnr)] = {
    bufnr: bufnr,
    path: path,
    session: session,
    url: url,
    # What the page was built with.  Kept so that a later change to one of
    # these can be noticed rather than silently ignored — the preview would go
    # on updating its text and obeying nothing else.
    page: PageOptions(),
    port: get(reply, 'port', 0),
    timer: 0,
    last_line: 0,
    cursor_sent_ms: 0,
    cursor_timer: 0,
    quiet_until_ms: 0,
  }
  Log(printf('serving %s at %s', path, url))

  if simplemarkdown#Setting('simplemarkdown_browser')
    Browse(url)
  else
    echo printf('[SimpleMarkdown] serving %s at %s', Describe(bufnr), url)
  endif
enddef


export def Close(all: bool = false)
  Prune()
  if all
    StopAll()
    return
  endif
  var key = string(TargetBuffer())
  if !has_key(previews, key)
    if has_key(opening, key)
      # Asked for and not yet answered.  Saying "there is none" would be false,
      # and leaving the request alone would open a browser tab a moment after
      # the user said stop — the first render of a long document is as long as
      # this window gets.
      opening[key] = false
      echo '[SimpleMarkdown] the browser preview was still starting; it will not open.'
      return
    endif
    Warn('no browser preview for this buffer.')
    return
  endif
  Discard(key)
enddef


export def Toggle()
  Prune()
  var key = string(TargetBuffer())
  # `opening` counts as open: toggling while one is starting means stop, not
  # start a second.
  if has_key(previews, key) || has_key(opening, key)
    Close()
  else
    Open()
  endif
enddef


# One-shot: render to a temporary HTML file and hand it to the browser.  No
# server, no live reload, nothing left running — the right shape for "let me
# look at this once", for a machine where a listening socket is awkward, and
# for a page you want to keep or send to someone.  The daemon hands the page
# back rather than writing it: a process that lays out documents and a process
# that creates files beside them are different blast radii.
export def Static()
  var bufnr = TargetBuffer()
  var path = fnamemodify(bufname(bufnr), ':p')
  if path ==# ''
    Warn('the browser preview needs a named buffer; :file or :w it first.')
    return
  endif
  if !Ready()
    return
  endif

  var page = PageOptions()
  # Nothing is listening: a page written to a file must not spend its life
  # reconnecting to an event stream that was never there.
  page.live = false
  page.sync_back = false

  var sent = simplemarkdown#core#Request({
    type: 'html',
    path: path,
    lines: getbufline(bufnr, 1, '$'),
    page: page,
  }, (reply) => OnStatic(bufnr, reply), OPEN_TIMEOUT_MS)

  if sent == 0
    Warn('could not ask the daemon for a page.')
  endif
enddef


def OnStatic(bufnr: number, reply: dict<any>)
  if get(reply, '_failed', false) || get(reply, 'type', '') !=# 'html_result'
    Warn('static preview failed: ' .. get(reply, 'message', 'no answer from the daemon'))
    return
  endif
  # Named after the document rather than given a random name: a browser tab
  # titled `simplemarkdown-a7f3.html` tells the reader nothing, and these
  # accumulate in the temporary directory where a person may have to identify
  # one later.
  var stem = fnamemodify(bufname(bufnr), ':t:r')
  var file = fnamemodify(tempname(), ':h') .. '/'
    .. (stem ==# '' ? 'markdown' : stem) .. '.html'
  try
    writefile(split(get(reply, 'html', ''), "\n", true), file)
  catch
    Warn('could not write ' .. file .. ': ' .. v:exception)
    return
  endtry
  Browse(FileUrl(file))
enddef


# A path a browser will take.  `file://` plus a Windows path is not a URL —
# `C:\Users\...` has backslashes for separators and no leading slash — and a
# temporary directory is allowed to have a space in it, which ends the URL.
def FileUrl(path: string): string
  var slashed = substitute(path, '\\', '/', 'g')
  var escaped = substitute(slashed, '[ "#%?<>^`{|}]',
    (m) => printf('%%%02X', char2nr(m[0])), 'g')
  return 'file://' .. (escaped =~# '^/' ? '' : '/') .. escaped
enddef

# ─────────────────────────── keeping it fed ───────────────────────────

# The buffer changed.  Debounced with the same option the in-Vim preview uses:
# a browser repainting a whole document per keystroke is the same waste as a
# terminal doing it, and the two previews should not disagree about how eager
# they are.
export def OnTextChanged(bufnr: number)
  var key = string(bufnr)
  if !has_key(previews, key)
    return
  endif
  if !simplemarkdown#Setting('simplemarkdown_browser_live')
    # Following the file rather than the buffer, which is what the previous
    # implementation could do and some people prefer: the page then changes
    # only at moments the author chose.
    return
  endif
  var preview = previews[key]
  if preview.timer > 0
    timer_stop(preview.timer)
  endif
  var delay: number = simplemarkdown#Setting('simplemarkdown_debounce')
  preview.timer = timer_start(delay, (_) => Push(key))
enddef


export def OnWritten(bufnr: number)
  var key = string(bufnr)
  if !has_key(previews, key)
    return
  endif
  if simplemarkdown#Setting('simplemarkdown_browser_live')
    # `BufWritePost` is one of the events that already scheduled a push, and a
    # second render of the same document would only say the same thing.
    return
  endif
  # A write is the one moment a preview that is not following the buffer has
  # agreed to move.
  Push(key)
enddef


def Push(key: string)
  if !has_key(previews, key)
    return
  endif
  var preview = previews[key]
  preview.timer = 0
  if !bufexists(preview.bufnr)
    Discard(key)
    return
  endif
  if !bufloaded(preview.bufnr)
    # `getbufline()` on an unloaded buffer answers with nothing, and nothing is
    # a document: the page would go blank and stay blank, since a buffer nobody
    # loads again never produces another change to undo it.  The preview keeps
    # showing what it last had, which is what the buffer last said.
    return
  endif
  simplemarkdown#core#Send({
    type: 'serve_update',
    session: preview.session,
    lines: getbufline(preview.bufnr, 1, '$'),
    # The page is scrolled by the same message that changed it, so a reader
    # watching the browser while typing at the bottom of a long document does
    # not have to chase it.  0 leaves the page where they put it.
    line: FollowLine(preview),
  })
enddef


def FollowLine(preview: dict<any>): number
  if !simplemarkdown#Setting('simplemarkdown_browser_sync')
    return 0
  endif
  return preview.bufnr == bufnr('%') ? line('.') : 0
enddef

# The user changed a `g:simplemarkdown_browser_*` option.  Some of it a page
# already open can take; `math` decides which engine the *shell* loads and
# `sync_back` decides whether the server answers `POST /cursor` at all, and
# neither is something an open page can be talked into — so those are said out
# loud instead of being dropped.
export def OnOptionsChanged()
  Prune()
  for [key, preview] in items(previews)
    var now = PageOptions()
    if now == preview.page
      continue
    endif
    var reopen = now.math !=# preview.page.math || now.sync_back != preview.page.sync_back
    preview.page = now
    simplemarkdown#core#Send({type: 'serve_opts', session: preview.session, page: now})
    if reopen
      echohl WarningMsg
      echom printf('[SimpleMarkdown] %s: maths and scroll-back need the preview reopened '
        .. '(:SimpleMarkdownExternal twice).', Describe(preview.bufnr))
      echohl None
    endif
  endfor
enddef

# ─────────────────────────── the two cursors ───────────────────────────

export def OnCursorMoved(winid: number)
  if !simplemarkdown#Setting('simplemarkdown_browser_sync')
    return
  endif
  var key = string(winbufnr(winid))
  if !has_key(previews, key)
    return
  endif
  var preview = previews[key]
  var lnum = line('.', winid)
  if lnum <= 0 || lnum == preview.last_line
    return
  endif
  # A move this side made in answer to the page's own scrolling would be
  # reported straight back, and the two ends would chase each other down the
  # document.
  if Now() < preview.quiet_until_ms
    preview.last_line = lnum
    return
  endif
  preview.last_line = lnum

  var since = Now() - preview.cursor_sent_ms
  if since >= CURSOR_THROTTLE_MS
    SendCursor(key)
    return
  endif
  # Trailing edge: the position at rest is the one that matters, and dropping
  # it because the last of a run of moves arrived inside the window would leave
  # the page one line behind wherever the cursor stopped.
  if preview.cursor_timer == 0
    preview.cursor_timer = timer_start(CURSOR_THROTTLE_MS - since, (_) => SendCursor(key))
  endif
enddef


def SendCursor(key: string)
  if !has_key(previews, key)
    return
  endif
  var preview = previews[key]
  preview.cursor_timer = 0
  preview.cursor_sent_ms = Now()
  simplemarkdown#core#Send({
    type: 'serve_cursor',
    session: preview.session,
    line: preview.last_line,
  })
enddef


# The reader scrolled the page and asked the editor to follow.  Unsolicited:
# routed here from the daemon's event stream, not from a reply.
export def OnScrolled(session: string, lnum: number)
  if !simplemarkdown#Setting('simplemarkdown_browser_sync_back') || lnum <= 0
    return
  endif
  var preview = PreviewFor(session)
  if empty(preview) || !bufexists(preview.bufnr)
    return
  endif
  var target = min([lnum, getbufinfo(preview.bufnr)[0].linecount])
  preview.quiet_until_ms = Now() + SYNC_BACK_QUIET_MS
  preview.last_line = target
  # Every window showing the document, and none of them focused: a preview that
  # steals the cursor out of the buffer you are typing in is a preview you
  # close.
  for winid in win_findbuf(preview.bufnr)
    win_execute(winid, printf('call cursor(%d, 1) | normal! zz', target))
  endfor
enddef

# ─────────────────────────── lifecycle ───────────────────────────

# Vim is going away; so should every server we started.  Without this they
# outlive the editor and hold their ports — though only until the daemon
# notices its own stdin has closed, which is the belt to this file's braces.
export def StopAll()
  for key in keys(previews)
    Forget(key)
  endfor
  opening = {}
  # Sent whether or not this side thought it had anything, and as one message
  # rather than one per preview.  `:SimpleMarkdownExternalClose!` is reached for
  # precisely when the two tables have drifted — a server this side has lost
  # track of is the only kind worth a bang — and it runs from VimLeavePre too,
  # where what is left of the session is a pipe about to close.
  simplemarkdown#core#Send({type: 'serve_stop', all: true})
enddef


export def OnBufferWipeout(bufnr: number)
  Discard(string(bufnr))
enddef


# The daemon exited, taking every socket it was holding with it.  The table
# here would otherwise keep answering "already serving" for URLs that now
# refuse the connection.
export def OnDaemonExit()
  if empty(previews)
    return
  endif
  for key in keys(previews)
    Forget(key)
  endfor
  Log('daemon exited; every browser preview went with it')
enddef

# ─────────────────────────── introspection ───────────────────────────

export def Status(): list<any>
  Prune()
  var out: list<any> = []
  for preview in values(previews)
    add(out, {
      bufnr: preview.bufnr,
      name: Describe(preview.bufnr),
      url: preview.url,
      path: preview.path,
    })
  endfor
  return sort(out, (a, b) => a.bufnr - b.bufnr)
enddef


export def HealthLines(): list<string>
  var lines: list<string> = []
  var served = simplemarkdown#core#HasCap('serve')
  add(lines, printf('[%s] browser preview: %s', served ? 'OK' : 'WARN',
    served ? 'served by the daemon'
      : 'this daemon cannot serve; run ./install.sh, then :SimpleMarkdownRestart'))
  for entry in Status()
    add(lines, printf('[INFO] browser preview: %s -> %s', entry.name, entry.url))
  endfor
  return lines
enddef
