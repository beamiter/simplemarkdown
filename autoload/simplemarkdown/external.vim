vim9script

# =============================================================================
# simplemarkdown#external — the out-of-editor preview.
#
# The in-Vim preview and this one answer different questions.  The buffer
# preview is for reading and navigating a document while you write it, over
# SSH, in tmux, with the cursors tied together.  This one is for seeing what
# the document will actually look like: real proportional type, images that
# are images, and LaTeX that is typeset rather than shown as source.
#
# It is deliberately a thin supervisor around `omd`, an external binary the
# user installs themselves.  Nothing here is linked into simplemarkdown-daemon:
# omd pulls in a web server, a file watcher and a clipboard stack, and none of
# that belongs in a process whose whole job is to lay out rows of text.
#
# One omd server per source buffer, each on its own port.  omd watches the file
# on disk with notify(7) and pushes a reload over SSE, so the browser follows
# `:w` — not every keystroke.  That is the trade for not having to keep a
# shadow copy of the buffer on disk.
# =============================================================================

# Where a probe — and the browser this plugin opens — has to go when omd was
# asked to bind a wildcard address.  Not the default for
# |g:simplemarkdown_omd_host|: since the settings table exists, every default
# is declared there and nowhere else.
const LOOPBACK = '127.0.0.1'
# How far above the configured port to look for a free one before giving up.
const PORT_ATTEMPTS = 24
# A server that dies this fast never bound its port; report its stderr rather
# than leaving a dead entry that looks live.
const STARTUP_GRACE_MS = 1500

# source bufnr (as a string) -> preview
var previews: dict<any> = {}

def Log(message: string)
  simplemarkdown#core#Log('external: ' .. message)
enddef


def Warn(message: string)
  echohl WarningMsg
  echom '[SimpleMarkdown] ' .. message
  echohl None
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

# ─────────────────────────── the omd binary ───────────────────────────

export def Executable(): string
  # Typed rather than checked: the settings table has already guaranteed a
  # string here, which is the point of asking it rather than g: directly.
  var configured: string = simplemarkdown#Setting('simplemarkdown_omd_path')
  if configured !=# ''
    return executable(configured) ? exepath(configured) : ''
  endif
  if executable('omd')
    return exepath('omd')
  endif
  # `cargo install` puts binaries here, and a Vim started from a desktop
  # session frequently has not sourced the profile that adds it to $PATH.
  for candidate in [expand('~/.cargo/bin/omd'), expand('~/.cargo/bin/omd.exe')]
    if executable(candidate)
      return candidate
    endif
  endfor
  return ''
enddef


def RequireExecutable(): string
  var exe = Executable()
  if exe ==# ''
    Warn('omd not found. Install it with `cargo install omd`, or set g:simplemarkdown_omd_path.')
  endif
  return exe
enddef

# ─────────────────────────── ports ───────────────────────────

# A wildcard bind is reachable on the loopback address, and that is where a
# probe — and the browser this plugin opens — has to go.
def ConnectHost(host: string): string
  return host ==# '0.0.0.0' || host ==# '::' ? LOOPBACK : host
enddef


def PortIsFree(host: string, port: number): bool
  var channel: channel
  try
    channel = ch_open(printf('%s:%d', ConnectHost(host), port), {waittime: 50, timeout: 50})
  catch
    # Refused: nothing is listening, which is exactly what we want.
    return true
  endtry
  if ch_status(channel) ==# 'open'
    ch_close(channel)
    return false
  endif
  return true
enddef


# The port a *previous* omd of ours is on is not free, but it is also not a
# port we should skip silently — Claim() only ever runs when we are starting a
# new server, and one of ours still holding a port means that buffer is already
# being previewed.
def Claim(host: string, base: number): number
  for offset in range(PORT_ATTEMPTS)
    var port = base + offset
    if port > 65535
      break
    endif
    if PortIsFree(host, port)
      return port
    endif
  endfor
  return 0
enddef

# ─────────────────────────── sessions ───────────────────────────

def Alive(preview: dict<any>): bool
  return get(preview, 'job', null_job) != null_job
    && job_status(preview.job) ==# 'run'
enddef


def Prune()
  for [key, preview] in items(previews)
    if !Alive(preview) || !bufexists(str2nr(key))
      Discard(key)
    endif
  endfor
enddef


def Discard(key: string)
  if !has_key(previews, key)
    return
  endif
  var preview = previews[key]
  previews->remove(key)
  if get(preview, 'job', null_job) != null_job && job_status(preview.job) ==# 'run'
    job_stop(preview.job, 'term')
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

  var path = fnamemodify(bufname(bufnr), ':p')
  if path ==# '' || !filereadable(path)
    Warn('omd previews a file on disk; write this buffer first.')
    return
  endif

  var exe = RequireExecutable()
  if exe ==# ''
    return
  endif

  var host: string = simplemarkdown#Setting('simplemarkdown_omd_host')
  var base: number = simplemarkdown#Setting('simplemarkdown_omd_port')
  var port = Claim(host, base)
  if port == 0
    Warn(printf('no free port in %d-%d; set g:simplemarkdown_omd_port.',
      base, base + PORT_ATTEMPTS - 1))
    return
  endif

  var extra: list<string> = simplemarkdown#Setting('simplemarkdown_omd_args')
  var argv = [exe, '--host', host, '--port', string(port)] + extra + [path]
  var url = printf('http://%s:%d', ConnectHost(host), port)
  var errors: list<string> = []

  var job = job_start(argv, {
    in_io: 'null',
    out_io: 'pipe',
    err_io: 'pipe',
    out_cb: (_, message) => {
      Log('omd: ' .. message)
    },
    err_cb: (_, message) => {
      add(errors, message)
      Log('omd!: ' .. message)
    },
    exit_cb: (_, code) => {
      OnExit(key, code, errors)
    },
  })
  if job_status(job) !=# 'run'
    Warn('could not start omd: ' .. join(argv))
    return
  endif

  previews[key] = {
    job: job,
    bufnr: bufnr,
    path: path,
    host: host,
    port: port,
    url: url,
    started_ms: Now(),
  }
  Log(printf('omd serving %s on %s', path, url))

  if simplemarkdown#Setting('simplemarkdown_omd_browser')
    # omd binds its socket before it prints anything, but the browser is a
    # separate process racing it; a short beat is cheaper than a 'connection
    # refused' page the user then has to reload by hand.
    var delay: number = simplemarkdown#Setting('simplemarkdown_omd_browser_delay')
    timer_start(delay, (_) => {
      if has_key(previews, key)
        Browse(url)
      endif
    })
  else
    echo printf('[SimpleMarkdown] omd serving %s at %s', Describe(bufnr), url)
  endif

  if &modified
    echohl WarningMsg
    echom '[SimpleMarkdown] the buffer has unwritten changes; omd reloads on :w.'
    echohl None
  endif
enddef


def OnExit(key: string, code: number, errors: list<string>)
  var known = has_key(previews, key)
  var young = known && Now() - previews[key].started_ms < STARTUP_GRACE_MS
  if known
    previews->remove(key)
  endif
  if code == 0 || !known
    return
  endif
  # An immediate non-zero exit is a real failure the user has to see — a port
  # that was taken between the probe and the bind, an unreadable file.  A late
  # one is usually the server being killed with the editor.
  var detail = empty(errors) ? printf('exit code %d', code) : trim(errors[-1])
  if young
    Warn('omd failed to start: ' .. detail)
  else
    Log(printf('omd exited: %s', detail))
  endif
enddef


export def Close(all: bool = false)
  Prune()
  if all
    for key in keys(previews)
      Discard(key)
    endfor
    return
  endif
  var key = string(TargetBuffer())
  if !has_key(previews, key)
    Warn('no omd preview for this buffer.')
    return
  endif
  Discard(key)
enddef


export def Toggle()
  Prune()
  if has_key(previews, string(TargetBuffer()))
    Close()
  else
    Open()
  endif
enddef


# One-shot: render to a temporary HTML file and hand it to the browser.  No
# server, no live reload, nothing left running — the right shape for "let me
# look at this once" and for a machine where a listening socket is awkward.
export def Static()
  var bufnr = TargetBuffer()
  var path = fnamemodify(bufname(bufnr), ':p')
  if path ==# '' || !filereadable(path)
    Warn('omd previews a file on disk; write this buffer first.')
    return
  endif
  var exe = RequireExecutable()
  if exe ==# ''
    return
  endif
  var errors: list<string> = []
  var extra: list<string> = simplemarkdown#Setting('simplemarkdown_omd_args')
  var job = job_start([exe, '--static-mode'] + extra + [path], {
    in_io: 'null',
    err_cb: (_, message) => {
      add(errors, message)
    },
    exit_cb: (_, code) => {
      if code != 0
        Warn('omd --static-mode failed: '
          .. (empty(errors) ? printf('exit code %d', code) : trim(errors[-1])))
      endif
    },
  })
  if job_status(job) !=# 'run'
    Warn('could not start omd.')
  endif
enddef


# Vim is going away; so should every server we started.  Without this they
# outlive the editor and hold their ports.
export def StopAll()
  for key in keys(previews)
    Discard(key)
  endfor
enddef


export def OnBufferWipeout(bufnr: number)
  Discard(string(bufnr))
enddef

# ─────────────────────────── introspection ───────────────────────────

def Now(): number
  return float2nr(reltimefloat(reltime()) * 1000)
enddef


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
  var exe = Executable()
  var lines = [printf('[%s] omd: %s', exe ==# '' ? 'WARN' : 'OK',
    exe ==# '' ? 'not installed (cargo install omd)' : exe)]
  for entry in Status()
    add(lines, printf('[INFO] external preview: %s -> %s', entry.name, entry.url))
  endfor
  return lines
enddef
