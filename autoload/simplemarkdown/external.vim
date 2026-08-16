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
# The subset of `opening` still waiting for its pictures (a remote document,
# see Stage()): nothing has been asked of the daemon yet, so a Close() takes
# the whole attempt back rather than leaving a `serve` to be stopped on reply.
var staging_open: dict<bool> = {}

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
  Unstage(key)
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
  return (fnamemodify(bufname(bufnr), ':t') ?? '[No Name]')
    .. simplemarkdown#RemoteSuffix(bufnr)
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

  opening[key] = true
  var remote = simplemarkdown#RemoteInfo(bufnr)
  if empty(remote)
    Serve(bufnr, path)
    return
  endif
  # A remote document's directory is on another host.  Its images are staged
  # into a local directory first and the daemon serves that; the page opens
  # once they are there, since a browser asked for a picture that has not
  # arrived yet shows a broken one until something makes it ask again.
  staging_open[key] = true
  Stage(bufnr, remote, simplemarkdown#ImageHrefs(bufnr),
    () => Serve(bufnr, StagedPath(bufnr, remote)))
enddef


# The `serve` itself, once the directory `path` is in exists on this machine.
# `opening[key]` was claimed by Open(); it is released here on failure and by
# OnServed() otherwise — or has been withdrawn in between by a Close(), which
# for a remote document can arrive while the images are still being fetched.
def Serve(bufnr: number, path: string)
  var key = string(bufnr)
  if has_key(staging_open, key)
    staging_open->remove(key)
  endif
  if !get(opening, key, false) || !bufexists(bufnr)
    # Withdrawn, or the buffer went away, while the pictures were being
    # fetched.  `has_key` before the remove: a Close() during staging takes the
    # whole attempt out of `opening` rather than marking it withdrawn, and
    # remove() on a key that is not there throws — inside a transfer callback,
    # which is the worst place for it.
    if has_key(opening, key)
      opening->remove(key)
    endif
    return
  endif
  var host: string = simplemarkdown#Setting('simplemarkdown_browser_host')
  var base: number = simplemarkdown#Setting('simplemarkdown_browser_port')
  var session = SessionKey(bufnr)
  var root = AssetRoot(host)

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
  # Absent rather than false is also "not wanted": Serve() only sends a request
  # for a key it has just claimed, so the key can only have gone because
  # `:SimpleMarkdownExternalClose!` replaced the whole table while the port was
  # being bound.  The has_key() is for the same reason — remove() on a key that
  # is no longer there throws, and this is a channel callback.
  var wanted = get(opening, string(bufnr), false)
  if has_key(opening, string(bufnr))
    opening->remove(string(bufnr))
  endif

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
  var remote = simplemarkdown#RemoteInfo(bufnr)
  previews[string(bufnr)] = {
    bufnr: bufnr,
    path: path,
    # The remote path of a SimpleRemote document, or ''.  `path` is then the
    # staging directory's copy — the one the daemon was told about — and this
    # is what a person reading :SimpleMarkdownHealth wants to see instead.
    remote: get(remote, 'path', ''),
    session: session,
    url: url,
    # What the page was built with.  Kept so that a later change to one of
    # these can be noticed rather than silently ignored — the preview would go
    # on updating its text and obeying nothing else.
    page: PageOptions(),
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
      if has_key(staging_open, key)
        # Still waiting for a remote document's pictures: the daemon has not
        # been asked for anything, so there is nothing to withdraw on reply.
        # Whatever transfer is in flight lands in a directory nobody serves.
        opening->remove(key)
        Unstage(key)
      else
        opening[key] = false
      endif
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
  var remote = simplemarkdown#RemoteInfo(bufnr)
  if empty(remote)
    RequestStatic(bufnr, path)
    return
  endif
  # The daemon inlines the pictures it finds beside the document, so for a
  # remote one they are staged first and it is pointed at the staging
  # directory — the page then carries them the way a local document's does.
  Stage(bufnr, remote, simplemarkdown#ImageHrefs(bufnr),
    () => RequestStatic(bufnr, StagedPath(bufnr, remote)))
enddef


def RequestStatic(bufnr: number, path: string)
  if !bufexists(bufnr)
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

# ─────────────────────────── remote documents ───────────────────────────
#
# A document open through SimpleRemote's virtual workspace is a `remote://`
# buffer: its text is here, its directory is on another host, and so are the
# pictures beside it.  The daemon serves whatever directory the document's path
# names, so for such a document it is handed a staging directory instead — a
# per-buffer temporary directory the referenced images are downloaded into,
# with g:SimpleRemoteDownload() — and a path inside it standing in for the
# document.  The same directory feeds :SimpleMarkdownExternalStatic, whose
# pictures the daemon inlines from beside the document.
#
# The staging directory is laid out as the *URLs* the browser will ask for, not
# as the remote tree.  A browser resolves `../assets/logo.png` against the
# page's URL and clamps it at `/`, so what reaches the server is
# `/assets/logo.png`; the copy of `<remote dir>/../assets/logo.png` therefore
# has to be at `<staging>/assets/logo.png`, and the same clamp is what the
# server's own safe_join enforces.  Nothing outside the staging directory is
# ever served, whatever the document says.
#
# What is fetched is what the document referred to when the preview opened plus
# whatever it names later (see Push()); a picture that changes on the host
# after that is not fetched again until the preview is reopened.

# Enough for a document that is a screenshot gallery, and few enough that a
# generated report with a thousand plots is not a thousand transfers over SSH
# before anything is shown.
const REMOTE_ASSET_MAX = 64
# All of one document's staged pictures together; past this the rest are left
# unstaged rather than filling a temporary directory.
const REMOTE_ASSET_MAX_BYTES = 64 * 1024 * 1024

# source bufnr (as a string) -> staging
#   dir      the staging directory
#   assets   href -> {remote, local, state: 'pending' | 'ok' | 'failed' | 'skipped', bytes}
#   pending  transfers in flight
#   bytes    what the 'ok' ones add up to
#   waiters  what to call once nothing is in flight
var staging: dict<any> = {}


# The staging directory of `bufnr`, made if it is not there.  Under Vim's own
# temporary directory, so it goes when Vim does; per buffer, so two remote
# documents named README.md do not stage over each other.
def StageDir(bufnr: number): string
  var dir = fnamemodify(tempname(), ':h') .. '/simplemarkdown-remote-' .. bufnr
  if !isdirectory(dir)
    mkdir(dir, 'p')
  endif
  return dir
enddef


# What the daemon is told the document is called: a path inside the staging
# directory carrying the document's own name, so that the served root is the
# staging directory and the tab is titled after the file.  Nothing is written
# there — the daemon renders the buffer's lines, not a file.
def StagedPath(bufnr: number, remote: dict<any>): string
  return StageDir(bufnr) .. '/' .. fnamemodify(remote.path, ':t')
enddef


# `%2e` and friends, decoded — the browser will send the URL encoded and the
# server decodes it before looking in the directory, so the copy has to be
# stored under the decoded name; and a document that wrote `my%20plot.png`
# means the file called `my plot.png` on the host.  A `%` that is not an escape
# is left alone rather than refused: it is a character a file name may have.
def PercentDecode(text: string): string
  return substitute(text, '%\(\x\x\)', (m) => nr2char(str2nr(m[1], 16)), 'g')
enddef


# `href` as the browser will ask for it: resolved against `/` with `.` and `..`
# removed the way RFC 3986 says — a `..` at the root is dropped, which is the
# clamp — and without any query or fragment.  Always begins with `/`; `/` alone
# is a URL that names no file.
def UrlPath(href: string): string
  var bare = PercentDecode(substitute(href, '[?#].*$', '', ''))
  var parts: list<string> = []
  for part in split(bare, '/')
    if part ==# '.'
      continue
    elseif part ==# '..'
      if !empty(parts)
        remove(parts, -1)
      endif
    else
      add(parts, part)
    endif
  endfor
  return '/' .. join(parts, '/')
enddef


# Where `href`, written in the remote document at `remote_path`, is on the
# host: absolute hrefs name its filesystem, relative ones the document's
# directory.  simplify() rather than the URL clamp: `../` here really does
# mean the parent directory, and it is the *copy* that has to land where the
# clamp says.
def RemoteAssetPath(remote_path: string, href: string): string
  var bare = PercentDecode(substitute(href, '[?#].*$', '', ''))
  if bare =~# '^/'
    return simplify(bare)
  endif
  var dir = fnamemodify(remote_path, ':h')
  return simplify(dir ==# '/' ? '/' .. bare : dir .. '/' .. bare)
enddef


# Whether an href names a file beside the document at all.  Anything with a
# scheme (`https:`, `data:`, `mailto:`) or a host (`//cdn/…`) is the browser's
# to fetch, and a bare `#fragment` or `?query` names the page itself.
def IsFetchable(href: string): bool
  return href !~# '^\a[[:alnum:]+.-]*:' && href !~# '^//' && href !~# '^[?#]'
    && UrlPath(href) !=# '/'
enddef


# Fetch the images among `hrefs` that are not already staged for `bufnr`, then
# call Then — at once when there is nothing to fetch.  Concurrent callers share
# the transfers: Then joins the waiters and everybody is called when the last
# one lands.
def Stage(bufnr: number, remote: dict<any>, hrefs: list<string>, Then: func)
  var key = string(bufnr)
  if !has_key(staging, key)
    staging[key] = {dir: StageDir(bufnr), assets: {}, pending: 0, bytes: 0, waiters: []}
  endif
  var stage = staging[key]
  add(stage.waiters, Then)
  var can = exists('*g:SimpleRemoteDownload')
  # Held while the loop runs: SimpleRemote answers a transfer it refuses —
  # not connected, nothing to run — from inside the call, and a first picture
  # refused that way would otherwise settle the whole batch before the second
  # had been asked for.
  stage.pending += 1
  for each in hrefs
    # Copied: a lambda in a :for captures the loop variable itself, which by
    # the time a transfer lands holds the last href of the loop, not this one.
    var href = each
    if has_key(stage.assets, href) || !IsFetchable(href)
      continue
    endif
    var local = stage.dir .. UrlPath(href)
    var asset = {
      remote: RemoteAssetPath(remote.path, href),
      local: local,
      state: 'pending',
      bytes: 0,
    }
    stage.assets[href] = asset
    if !can || len(stage.assets) > REMOTE_ASSET_MAX || stage.bytes >= REMOTE_ASSET_MAX_BYTES
      asset.state = 'skipped'
      continue
    endif
    # The transfer writes the file; the directory it goes in is this side's job,
    # and `a/b/c.png` under a staging directory that has never seen `a/` is the
    # ordinary case.
    var parent = fnamemodify(local, ':h')
    if !isdirectory(parent)
      mkdir(parent, 'p')
    endif
    stage.pending += 1
    # `force`: a preview reopened after the plot was regenerated must show the
    # new plot, and the stale copy from last time is exactly what is there.
    var started = g:SimpleRemoteDownload(asset.remote, local, {force: true},
      (ok, result) => OnStaged(key, href, !!ok, result))
    if !started && asset.state ==# 'pending'
      # Refused without the callback having been called — SimpleRemote calls it
      # even then, but a refusal is a refusal from anybody — so no answer is
      # coming and the transfer is accounted for here.
      stage.pending -= 1
      asset.state = 'failed'
    endif
  endfor
  stage.pending -= 1
  Settle(key)
enddef


def OnStaged(key: string, href: string, ok: bool, result: any)
  if !has_key(staging, key)
    # Closed while the transfer was in flight; the file may have landed in a
    # directory nobody is serving any more, which is fine.
    return
  endif
  var stage = staging[key]
  stage.pending = max([0, stage.pending - 1])
  var asset = get(stage.assets, href, {})
  if !empty(asset)
    var size = ok ? max([0, getfsize(asset.local)]) : 0
    if ok && stage.bytes + size > REMOTE_ASSET_MAX_BYTES
      # Over budget: the file is dropped rather than served, and the budget is
      # what stops the next one being fetched at all.
      delete(asset.local)
      asset.state = 'skipped'
      stage.bytes = REMOTE_ASSET_MAX_BYTES
      Log(printf('%s: %s not staged, over %d bytes for the document', key, href,
        REMOTE_ASSET_MAX_BYTES))
    elseif ok
      asset.state = 'ok'
      asset.bytes = size
      stage.bytes += size
    else
      asset.state = 'failed'
      Log(printf('%s: %s not staged: %s', key, href,
        type(result) == v:t_dict ? get(result, 'error', 'transfer failed') : string(result)))
    endif
  endif
  Settle(key)
enddef


# Nothing in flight: everybody who was waiting for that is told, in order.  Each
# waiter is removed before it is called, so one that stages more (Push() does)
# queues itself afresh rather than being called twice.
def Settle(key: string)
  if !has_key(staging, key)
    return
  endif
  var stage = staging[key]
  while stage.pending == 0 && !empty(stage.waiters)
    var Then: func = remove(stage.waiters, 0)
    Then()
  endwhile
enddef


def Unstage(key: string)
  if has_key(staging_open, key)
    staging_open->remove(key)
  endif
  if !has_key(staging, key)
    return
  endif
  var stage = staging->remove(key)
  # Waiters are dropped rather than called: what they were going to do was
  # serve or push a preview that has just been closed.
  if stage.dir =~# '/simplemarkdown-remote-\d\+$' && isdirectory(stage.dir)
    delete(stage.dir, 'rf')
  endif
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
  # A remote document that now names a picture it did not before: fetch it,
  # then push.  Pushed first, the page would ask for the file before it was
  # there and keep the broken image it got — an update that changes no block
  # is a splice of nothing, and does not make it ask again.  The delay is one
  # transfer, only on the edits that add an image, and never for a picture
  # already staged or already known to be missing.
  var remote = simplemarkdown#RemoteInfo(preview.bufnr)
  if !empty(remote) && has_key(staging, key)
    var missing = filter(simplemarkdown#ImageHrefs(preview.bufnr),
      (_, href) => !has_key(staging[key].assets, href))
    if !empty(missing)
      Stage(preview.bufnr, remote, missing, () => Update(key))
      return
    endif
  endif
  Update(key)
enddef


def Update(key: string)
  if !has_key(previews, key)
    return
  endif
  var preview = previews[key]
  if !bufexists(preview.bufnr) || !bufloaded(preview.bufnr)
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
  # A staging directory with no preview — :SimpleMarkdownExternalStatic on a
  # remote document leaves one — goes too.
  for key in keys(staging)
    Unstage(key)
  endfor
  opening = {}
  staging_open = {}
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
    var stage = get(staging, string(preview.bufnr), {})
    add(out, {
      bufnr: preview.bufnr,
      name: Describe(preview.bufnr),
      url: preview.url,
      path: preview.path,
      remote: get(preview, 'remote', ''),
      # How many of the remote document's pictures are on this machine, of how
      # many it names; 0/0 for a local document.
      staged: len(filter(values(get(stage, 'assets', {})), (_, a) => a.state ==# 'ok')),
      assets: len(get(stage, 'assets', {})),
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
    add(lines, printf('[INFO] browser preview: %s -> %s%s', entry.name, entry.url,
      entry.remote ==# '' ? ''
        : printf(' (remote %s, %d/%d images staged)', entry.remote, entry.staged, entry.assets)))
  endfor
  return lines
enddef
