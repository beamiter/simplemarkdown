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
# than four thousand.
#
# Protocol v3 separated the row → source map from the rows.  A row's source line
# is not part of what the row looks like, and treating it as part of the row's
# identity meant that inserting one line — which moves every row below it in the
# map and nothing on screen — had no common suffix and shipped the whole
# document.  The map now arrives as its own tiny correction (`patch.s`, usually
# one delta) applied after the row splice.  Two independently spliced arrays can
# drift where one could not, so there are two checksums: `total` for the rows and
# `src_sum` for the map, and a mismatch in either asks for a whole document back
# rather than redrawing something that is already wrong.
# =============================================================================

const PROTOCOL_VERSION = 4
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
var last_elapsed_ms = -1
# How the last renders were applied.  Worth counting: a patch path that has
# quietly stopped patching is invisible otherwise — the preview stays correct,
# it just gets slow again.
var patched_renders = 0
var full_renders = 0
var last_patch_rows = -1
# remote:// bufnr (as a string) -> the `#anchor` to jump to once SimpleRemote
# has filled the buffer.  A link into a remote document is followed by an
# `:edit remote://…` whose text arrives asynchronously, so the jump waits for
# the User SimpleRemoteBufferRead that says it has (see FollowHref).
var pending_anchors: dict<string> = {}

# ─────────────────────────── configuration ───────────────────────────
#
# Every `g:` option this plugin documents, what it may hold, and what it falls
# back to.  One table rather than a normalising expression per option, for
# three reasons.
#
# A value is checked twice.  NormalizeConfig() runs once from
# plugin/simplemarkdown.vim — that is where a documented default comes from —
# but a `:let` from a later `:source`, a modeline or a FileType autocommand is
# never seen by it, and the render options go straight into JSON: a quoted
# `'4'` where the daemon expects a number is rejected by serde, and what the
# user gets is a preview that stops updating with `invalid request` in a log
# nobody opens.  Every read below goes through Setting(), so a wrong value
# costs a fallback and a line in the health report, never the preview.
#
# A value silently corrected is a setting that does not work with nothing said
# about it.  Coerce() returns what was wrong as well as what it chose, so
# :SimpleMarkdownHealth can list it and the first use of the backend can say it
# once — the load-time correction especially, since by then `g:` holds the
# corrected value and the mistake has vanished from the only place anyone would
# think to look.
#
# And a name in one list only is a bug in one direction or the other: an option
# implemented and not documented is one nobody can find, an option documented
# and not implemented is a promise nothing keeps.  SettingNames() is what
# tests/vim_config.vim holds against the help.
#
# `kind` is one of:
#   flag      0/1, also accepting v:true/v:false
#   number    clamped into min..max — a width of 4000 is a typo, not a request
#   choice    one of `allowed`
#   strings   list of strings; an entry that is not a string is dropped
#   mappings  dict of string -> string; an entry that is not is dropped
#   string    anything textual (a path: the filesystem is the authority here,
#             not this table)
const SETTINGS: list<dict<any>> = [
  # 0 is "half the window": the preview is more useful side by side than
  # squeezed into a fixed column count that suits no terminal in particular.
  {name: 'simplemarkdown_width', kind: 'number', default: 0, min: 0, max: 400},
  {name: 'simplemarkdown_min_width', kind: 'number', default: 30, min: 12, max: 400},
  # Caps the text column inside the preview, independent of the window: prose is
  # hard to read at 200 columns even when the window offers them.
  {name: 'simplemarkdown_max_text_width', kind: 'number', default: 0, min: 0, max: 400},
  {name: 'simplemarkdown_side', kind: 'choice', default: 'right', allowed: ['left', 'right']},
  {name: 'simplemarkdown_debounce', kind: 'number', default: 120, min: 0, max: 5000},
  {name: 'simplemarkdown_style', kind: 'choice', default: 'unicode',
    allowed: ['unicode', 'ascii']},
  {name: 'simplemarkdown_syntax', kind: 'flag', default: 1},
  {name: 'simplemarkdown_wrap', kind: 'flag', default: 1},
  {name: 'simplemarkdown_code_wrap', kind: 'flag', default: 1},
  {name: 'simplemarkdown_show_urls', kind: 'flag', default: 0},
  {name: 'simplemarkdown_link_hint', kind: 'flag', default: 1},
  # Numbering the lines in a fenced block costs columns out of the code's own
  # width, and beside the source they are already on screen.
  {name: 'simplemarkdown_code_numbers', kind: 'flag', default: 0},
  # Tinting alternate table rows needs a CursorLine your colour scheme makes
  # visible but not loud, which is not a safe assumption.
  {name: 'simplemarkdown_table_zebra', kind: 'flag', default: 0},
  {name: 'simplemarkdown_task_progress', kind: 'flag', default: 1},
  {name: 'simplemarkdown_frontmatter', kind: 'flag', default: 1},
  {name: 'simplemarkdown_tab_width', kind: 'number', default: 4, min: 1, max: 16},
  # Off makes every render a whole document, which is only worth doing to rule
  # the patch path out while diagnosing something.
  {name: 'simplemarkdown_incremental', kind: 'flag', default: 1},
  {name: 'simplemarkdown_focus_block', kind: 'flag', default: 1},
  {name: 'simplemarkdown_sync_scroll', kind: 'flag', default: 1},
  {name: 'simplemarkdown_sync_back', kind: 'flag', default: 0},
  {name: 'simplemarkdown_auto_open', kind: 'flag', default: 0},
  {name: 'simplemarkdown_auto_close', kind: 'flag', default: 1},
  {name: 'simplemarkdown_auto_restart', kind: 'flag', default: 1},
  {name: 'simplemarkdown_set_default_mapping', kind: 'flag', default: 1},
  {name: 'simplemarkdown_default_mappings', kind: 'flag', default: 1},
  # Per-action overrides for the preview window's keys — `{'toggle-task': 'X'}`
  # to move one, `{'toggle-task': ''}` to turn that one off.
  {name: 'simplemarkdown_preview_mappings', kind: 'mappings', default: {}},
  # A plugin that changes 'foldmethod' behind your back is a plugin that gets
  # blamed for it, so folding is asked for rather than assumed.
  {name: 'simplemarkdown_folding', kind: 'flag', default: 0},
  # A save that opens a window is a save people stop making: on, the linter
  # fills the location list and says nothing.
  {name: 'simplemarkdown_lint_on_write', kind: 'flag', default: 0},
  {name: 'simplemarkdown_debug', kind: 'flag', default: 0},
  {name: 'simplemarkdown_filetypes', kind: 'strings',
    default: ['markdown', 'markdown.pandoc', 'pandoc', 'rmd', 'vimwiki', 'ghmarkdown']},
  {name: 'simplemarkdown_daemon_path', kind: 'string', default: ''},
  # ─── the external (browser) preview, served by the daemon ───
  {name: 'simplemarkdown_browser', kind: 'flag', default: 1},
  {name: 'simplemarkdown_browser_host', kind: 'choice', default: '127.0.0.1',
    allowed: ['127.0.0.1', 'localhost', '0.0.0.0', '::']},
  # The first port tried; a busy one moves the search up, it does not fail.
  {name: 'simplemarkdown_browser_port', kind: 'number', default: 3030, min: 1024, max: 65500},
  # 'auto' is the honest default: the page then agrees with whatever the reader
  # has told their system, and changes with it, which no fixed choice can do.
  {name: 'simplemarkdown_browser_theme', kind: 'choice', default: 'auto',
    allowed: ['auto', 'light', 'dark']},
  # Off follows the file rather than the buffer — the page then changes only at
  # moments the author chose, which is what the omd-backed preview could do.
  {name: 'simplemarkdown_browser_live', kind: 'flag', default: 1},
  {name: 'simplemarkdown_browser_sync', kind: 'flag', default: 1},
  # Off by default because it moves the cursor in a buffer somebody may be
  # typing in, from a window that does not have focus.
  {name: 'simplemarkdown_browser_sync_back', kind: 'flag', default: 0},
  # KaTeX is loaded from a CDN, which is the one thing on the page that is not
  # served from this machine; 'off' is a page that reaches nowhere at all.
  {name: 'simplemarkdown_browser_math', kind: 'choice', default: 'katex',
    allowed: ['off', 'katex', 'mathjax']},
  {name: 'simplemarkdown_browser_math_url', kind: 'string', default: ''},
  # Prose is hard to read at 200 columns in a browser for the same reason it is
  # in a terminal, and a maximised window offers rather more than 200.
  {name: 'simplemarkdown_browser_max_width', kind: 'number', default: 900, min: 480, max: 2400},
  # A second directory the preview may serve files from — the repository, for a
  # document that says `![](../assets/logo.png)`.  Empty is the document's own
  # directory and nothing else, and it is ignored on a non-loopback bind.
  {name: 'simplemarkdown_browser_root', kind: 'string', default: ''},
]

final SETTING_BY_NAME: dict<dict<any>> = {}
for spec in SETTINGS
  SETTING_BY_NAME[spec.name] = spec
endfor

# What writing a validated value back into `g:` had to correct: option name ->
# {said, value}.  Kept because the correction happens in place — by the time
# anyone looks, `g:` holds the corrected value and the mistake is gone from the
# one place a user would think to check.  `value` is what was written, and the
# complaint stands only while `g:` still holds it: someone who fixes the option
# during the session has fixed it, and a report that keeps saying otherwise is
# one people stop reading.
var corrections: dict<dict<any>> = {}
var config_warned = false


# The value to use, and what was wrong with the one that was there — an empty
# complaint means nothing was.
def Coerce(spec: dict<any>, raw: any): list<any>
  var name: string = spec.name
  var shown = string(raw)
  if spec.kind ==# 'flag'
    if type(raw) == v:t_bool
      return [raw ? 1 : 0, '']
    endif
    if type(raw) == v:t_number
      return [raw == 0 ? 0 : 1, '']
    endif
    return [spec.default,
      printf('g:%s = %s is not 0 or 1 — using %d', name, shown, spec.default)]
  elseif spec.kind ==# 'number'
    if type(raw) != v:t_number
      return [spec.default,
        printf('g:%s = %s is not a number — using %d', name, shown, spec.default)]
    endif
    var lower: number = spec.min
    var upper: number = spec.max
    var given: number = raw
    var clamped = min([upper, max([lower, given])])
    return [clamped, clamped == given ? '' :
      printf('g:%s = %d is outside %d..%d — using %d',
        name, given, lower, upper, clamped)]
  elseif spec.kind ==# 'choice'
    var allowed: list<string> = spec.allowed
    if type(raw) == v:t_string && index(allowed, raw) >= 0
      return [raw, '']
    endif
    return [spec.default,
      printf('g:%s = %s is not one of %s — using %s',
        name, shown, join(allowed, '/'), string(spec.default))]
  elseif spec.kind ==# 'strings'
    if type(raw) != v:t_list
      return [copy(spec.default),
        printf('g:%s = %s is not a list of strings — using %s',
          name, shown, string(spec.default))]
    endif
    var given: list<any> = raw
    var kept = filter(copy(given), (_, item) => type(item) == v:t_string)
    var lost = len(given) - len(kept)
    return [kept, lost == 0 ? '' :
      printf('g:%s: %d entr%s was not a string and %s dropped',
        name, lost, lost == 1 ? 'y' : 'ies', lost == 1 ? 'was' : 'were')]
  elseif spec.kind ==# 'mappings'
    if type(raw) != v:t_dict
      return [{}, printf('g:%s = %s is not a dictionary — using {}', name, shown)]
    endif
    var given: dict<any> = raw
    var kept = filter(copy(given), (_, value) => type(value) == v:t_string)
    var lost = len(given) - len(kept)
    return [kept, lost == 0 ? '' :
      printf('g:%s: %d entr%s did not name a key sequence and %s dropped',
        name, lost, lost == 1 ? 'y' : 'ies', lost == 1 ? 'was' : 'were')]
  endif
  # 'string': a path.  Whether it exists is the backend's answer to give, not
  # this table's; all that is checked here is that it is text at all.
  if type(raw) == v:t_string
    return [raw, '']
  endif
  return [spec.default, printf('g:%s = %s is not a string — using ""', name, shown)]
enddef


# A fresh copy for a container default, so that a caller that mutates what it
# was handed cannot edit the table itself.
def DefaultOf(spec: dict<any>): any
  return type(spec.default) == v:t_list || type(spec.default) == v:t_dict
    ? copy(spec.default)
    : spec.default
enddef


# Every option there is, in the order the table declares them.  Exported for
# tests/vim_config.vim, which holds this list against the `*g:simplemarkdown_*`
# tags in doc/simplemarkdown.txt: the two are the same set or one of them is
# lying.
export def SettingNames(): list<string>
  return mapnew(SETTINGS, (_, spec) => spec.name)
enddef


# The validated value of one option, whatever the user has done to it since the
# plugin loaded.  Every read of a `g:` option goes through here, bar the two the
# vendored supervisor reads by name — see SyncCoreSettings().
export def Setting(name: string): any
  if !has_key(SETTING_BY_NAME, name)
    # Not a name in the table: this plugin's typo rather than a user's, and
    # answering 0 would be a silent wrong default in whatever asked for it.
    # Loud, because only this repository can produce it — and `make
    # check-settings` proves no caller does.
    throw 'simplemarkdown: no such setting: ' .. name
  endif
  var spec = SETTING_BY_NAME[name]
  if !exists('g:' .. name)
    return DefaultOf(spec)
  endif
  return Coerce(spec, g:[name])[0]
enddef


# Put one option's validated value into `g:`, and remember what had to be
# corrected to get there — the rewrite destroys the evidence, so it is kept
# here or it is lost.
def Adopt(spec: dict<any>)
  var name: string = spec.name
  if has_key(corrections, name) && !StillAsNormalized(name, corrections[name].value)
    # `g:` no longer holds what we put there, so whatever is there now
    # supersedes what we remembered.  Guarded, and not simply dropped: Adopt()
    # is called again on every use of the backend, and a second pass over an
    # already-corrected value finds nothing wrong with it — which would erase
    # the only record that anything ever was.
    remove(corrections, name)
  endif
  # exists(), not get() with a fallback: an unset variable and one the user set
  # to an empty list are indistinguishable through get(), and defaulting the
  # unset case to [] leaves the plugin recognising no filetype at all.
  if !exists('g:' .. name)
    g:[name] = DefaultOf(spec)
    return
  endif
  var [value, complaint] = Coerce(spec, g:[name])
  g:[name] = value
  if complaint !=# ''
    corrections[name] = {said: complaint, value: value}
  endif
enddef


# The other direction: a `g:` option this plugin's own commands write, put
# through the same table a user's value goes through, answering with what had
# to be corrected ('' when nothing was).
#
# Not a convenience.  `:SimpleMarkdownResize 500` used to assign 500 to
# g:simplemarkdown_width directly, and the validator — whose whole job is to
# name real configuration mistakes — then reported that width in every
# :SimpleMarkdownHealth for the rest of the session, naming one the user had
# never made.  No command of this plugin may leave an option holding a value
# this plugin complains about, so every command that writes one writes it here.
def PutSetting(name: string, raw: any): string
  if !has_key(SETTING_BY_NAME, name)
    throw 'simplemarkdown: no such setting: ' .. name
  endif
  var [value, complaint] = Coerce(SETTING_BY_NAME[name], raw)
  g:[name] = value
  return complaint
enddef


# Called once from plugin/simplemarkdown.vim: every documented option ends up
# present, of the documented type and inside its documented range, so that the
# code and the tests that read `g:` plainly — and a user reading `:echo g:` —
# all see the value actually in force.
export def NormalizeConfig()
  corrections = {}
  for spec in SETTINGS
    Adopt(spec)
  endfor
enddef


# Is `g:name` still exactly what Adopt() wrote into it?  The types are compared
# first, and not only as an optimisation: Vim9 refuses to compare a string with
# a number outright, and `g:simplemarkdown_tab_width` going from the 4 we wrote
# to a later `'eight'` is precisely the case this is asked about.
def StillAsNormalized(name: string, value: any): bool
  if !exists('g:' .. name)
    return false
  endif
  var current: any = g:[name]
  return type(current) == type(value) && current == value
enddef


# Levenshtein distance, used only to turn a misspelt option name into a
# suggestion.  Both names carry the same 15-character prefix, so the matrix is
# small and this runs at most once per unknown variable per report.
def Distance(a: string, b: string): number
  var left = split(a, '\zs')
  var right = split(b, '\zs')
  var previous = range(len(right) + 1)
  for i in range(len(left))
    var current = [i + 1]
    for j in range(len(right))
      add(current, min([
        previous[j] + (left[i] ==# right[j] ? 0 : 1),
        previous[j + 1] + 1,
        current[j] + 1,
      ]))
    endfor
    previous = current
  endfor
  return previous[-1]
enddef


# The option a stray `g:simplemarkdown_` variable was probably meant to be, or
# '' when nothing is close enough.  Two edits in a name this long is a slip;
# more than that is a different word, and guessing at it would be noise.
def NearestSetting(name: string): string
  var best = ''
  var best_distance = 3
  for spec in SETTINGS
    var distance = Distance(name, spec.name)
    if distance < best_distance
      best = spec.name
      best_distance = distance
    endif
  endfor
  return best
enddef


# Everything wrong with the configuration right now, as `[WARN]`/`[INFO]`
# lines: the values that had to be corrected, and any `g:simplemarkdown_`
# variable that is not an option at all — which is what a misspelt option looks
# like, and is otherwise perfectly silent, because nothing ever reads it.
#
# At most one line per option: a value broken right now describes itself, and
# is the more useful of the two things that could be said about it.
export def ValidateConfig(): list<string>
  var problems: list<string> = []
  for spec in SETTINGS
    var name: string = spec.name
    var complaint: string = exists('g:' .. name) ? Coerce(spec, g:[name])[1] : ''
    if complaint ==# '' && has_key(corrections, name)
      # Nothing wrong with the value in force, but this option did not arrive
      # at it on its own: while `g:` still holds what the correction wrote, the
      # correction is the only surviving account of what the user asked for.
      if StillAsNormalized(name, corrections[name].value)
        complaint = corrections[name].said
      endif
    endif
    if complaint !=# ''
      add(problems, '[WARN] ' .. complaint)
    endif
  endfor
  for name in sort(keys(g:))
    if name !~# '^simplemarkdown_' || has_key(SETTING_BY_NAME, name)
      continue
    endif
    var nearest = NearestSetting(name)
    add(problems, printf('[INFO] g:%s is not an option this plugin has%s',
      name, nearest ==# '' ? '' : printf(' — did you mean g:%s?', nearest)))
  endfor
  return problems
enddef


# Said once, the first time the backend is wanted.  Not at load — a plugin that
# echoes while Vim is still starting is a plugin whose message is scrolled away
# by the next one — and not on every render either, which is the other way to
# make a warning invisible.
def WarnAboutConfigOnce()
  if config_warned
    return
  endif
  config_warned = true
  var problems = ValidateConfig()
  if empty(problems)
    return
  endif
  Warn(printf('%d configuration problem%s (:SimpleMarkdownHealth lists them again):',
    len(problems), len(problems) == 1 ? '' : 's'))
  for problem in problems
    Warn('  ' .. substitute(problem, '^\[\a\+\] ', '', ''))
  endfor
enddef

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
    auto_restart: Setting('simplemarkdown_auto_restart') ? true : false,
    request_timeout_ms: RENDER_TIMEOUT_MS,
    handshake: {request: {type: 'ping'}, reply_type: 'pong'},
    OnReady: OnDaemonReady,
    OnExit: OnDaemonExit,
    OnEvent: OnDaemonMessage,
  })
enddef


# The two options the supervisor reads out of `g:` by name rather than through
# us — it is vendored from simplecore and shared with nine other plugins, so it
# knows the names and nothing else about them.  Writing the validated value
# back is what makes "checked again on every read" true of these two as well:
# `!!get(g:, 'simplemarkdown_debug', 0)` on a string is a hard E1135 inside the
# logger, which is a poor place to discover a typo.
def SyncCoreSettings()
  Adopt(SETTING_BY_NAME['simplemarkdown_daemon_path'])
  Adopt(SETTING_BY_NAME['simplemarkdown_debug'])
enddef


def EnsureBackend(): bool
  # Before SetupCore(), which resolves the executable, and before the warning,
  # so that a value broken since load is corrected and reported in the same
  # breath as everything else.
  SyncCoreSettings()
  SetupCore()
  WarnAboutConfigOnce()
  return simplemarkdown#core#Ensure()
enddef


# The browser preview needs the same daemon the in-Vim one does, started the
# same way: settings synced, supervisor configured, configuration problems
# reported once.  Exported rather than reimplemented over there, because two
# ways to start one daemon is one way too many.
export def EnsureDaemon(): bool
  return EnsureBackend()
enddef


# What to tell someone whose daemon is older than their plugin, or '' when it
# is not.  The in-Vim preview says this in its own window; the browser preview
# has no window to say it in until it has started, which is exactly the thing
# a skew stops it doing.
export def DaemonSkew(): string
  var negotiated = ProtocolMismatch()
  return negotiated > 0 ? ProtocolMessage(negotiated) : ''
enddef


def ProtocolMessage(protocol: number): string
  return printf(
    'Daemon speaks protocol v%d, this plugin speaks v%d. Run ./install.sh, then :SimpleMarkdownRestart.',
    protocol, PROTOCOL_VERSION)
enddef


# The daemon answered the handshake with a protocol this plugin cannot read.
# Not a transient state: it lasts until the binary is rebuilt.
def ProtocolMismatch(): number
  var negotiated = simplemarkdown#core#Protocol()
  return simplemarkdown#core#Ready() && negotiated != PROTOCOL_VERSION ? negotiated : 0
enddef


def OnDaemonReady(protocol: number, caps: dict<any>)
  if protocol != PROTOCOL_VERSION
    # A protocol we do not know is worse than no preview: the row and property
    # layout is exactly what changes when it is bumped.  This is what a plugin
    # update without a rebuild looks like — the commonest failure in a plugin
    # with a compiled backend — so the explanation goes in the window the user
    # is looking at, not only in a message that the next redraw scrolls away.
    echohl WarningMsg
    echom '[SimpleMarkdown] ' .. ProtocolMessage(protocol)
    echohl None
    for key in keys(sessions)
      Placeholder(key, ProtocolMessage(protocol))
    endfor
    return
  endif
  Log(printf('daemon ready, %d capabilities', len(caps)))
  # Anything opened while the daemon was starting is still showing its
  # placeholder; now that it can answer, ask.
  for key in keys(sessions)
    Schedule(key, 0)
  endfor
enddef


# Everything the daemon says that is not the answer to something we asked.
# There is one such message: the browser preview reporting that its reader
# scrolled.  It cannot be a reply — nobody sent a request the page could be
# answering — so it arrives here, and the supervisor's id routing steps over it
# because it carries no id.
def OnDaemonMessage(msg: dict<any>)
  if get(msg, 'type', '') ==# 'serve_scrolled'
    simplemarkdown#external#OnScrolled(get(msg, 'session', ''), get(msg, 'line', 0))
  endif
enddef


def OnDaemonExit(code: number, restarting: bool)
  # Every browser preview died with the process that was holding its socket.
  simplemarkdown#external#OnDaemonExit()
  for key in keys(sessions)
    var session = sessions[key]
    session.pending = false
    if !restarting
      Placeholder(key, printf('Backend exited unexpectedly (code %d).', code))
    endif
  endfor
enddef


# Request ids come from the supervisor's sequence, not a second one of our own.
# Both end up as keys in the same pending table, and a plugin that starts
# counting at 1 collides with the handshake the supervisor has in flight at
# exactly the moment a session opens: the `pong` then resolves the first
# request's callback and the request's own reply finds nobody waiting.  A
# render recovers from that (the width does not match, so it resynchronises and
# asks again), which is why it went unnoticed; a one-shot request does not.
def NextId(): number
  return simplemarkdown#core#NextId()
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
  # 'acwrite' is a file that is read and written by an autocommand rather than
  # by Vim — SimpleRemote's remote:// buffers, netrw's scp:// ones — and it
  # holds real Markdown.  Every other 'buftype' (the plugin's own nofile
  # preview, quickfix, help, a terminal) is something this plugin must not
  # preview, lint or fold.
  var buftype = getbufvar(bufnr, '&buftype')
  if type(buftype) != v:t_string || (buftype !=# '' && buftype !=# 'acwrite')
    return false
  endif
  var filetype = getbufvar(bufnr, '&filetype')
  if type(filetype) != v:t_string
    return false
  endif
  if index(Setting('simplemarkdown_filetypes'), filetype) >= 0
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
  var configured = Setting('simplemarkdown_width')
  var minimum = Setting('simplemarkdown_min_width')
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
  var side = Setting('simplemarkdown_side') ==# 'left' ? 'topleft' : 'botright'
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
  var title = printf('[SimpleMarkdown] %s%s',
    fnamemodify(bufname(src_bufnr), ':t') ?? '[No Name]', RemoteSuffix(src_bufnr))
  if bufexists(title)
    # A second tab page previewing the same file: :file would fail with E95
    # and leave the buffer unnamed.
    title ..= printf(' (%d)', bufnr)
  endif
  silent! execute 'file ' .. fnameescape(title)
  b:simplemarkdown_preview = 1

  if Setting('simplemarkdown_default_mappings')
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


# Everything the preview window binds, as `[action, default key, <Plug>, what
# it does]`.  One table, used three ways: to install the buffer maps, to answer
# `g?`, and — because a cheat sheet that lies is worse than none — to show the
# keys actually in force after |g:simplemarkdown_preview_mappings| has had its
# say.  Each action maps onto a <Plug> rather than a call, so a user can bind
# any of them anywhere without copying an implementation detail.
const PREVIEW_MAPPINGS: list<list<string>> = [
  ['close', 'q', '<Plug>(simplemarkdown-preview-close)', 'close the preview'],
  ['refresh', 'r', '<Plug>(simplemarkdown-preview-refresh)',
    're-render this document in every tab'],
  ['activate', '<CR>', '<Plug>(simplemarkdown-preview-activate)',
    'follow the link on this row, or jump the source to the line it came from'],
  ['open-link', 'gx', '<Plug>(simplemarkdown-follow)', 'follow the link on this row'],
  ['toc', 'gO', '<Plug>(simplemarkdown-toc)', 'table of contents'],
  ['toggle-task', 'x', '<Plug>(simplemarkdown-toggle-task)',
    'check or uncheck this task in the Markdown source'],
  ['next-heading', ']]', '<Plug>(simplemarkdown-next-heading)', 'next heading'],
  ['prev-heading', '[[', '<Plug>(simplemarkdown-prev-heading)', 'previous heading'],
  ['help', 'g?', '<Plug>(simplemarkdown-preview-help)', 'this list'],
]


# The key this action is bound to in the preview, after the user's overrides.
# An empty string means the user turned that one off — which used to require
# turning all of them off.
def PreviewKey(action: string, fallback: string): string
  var overrides = Setting('simplemarkdown_preview_mappings')
  if type(overrides) != v:t_dict || !has_key(overrides, action)
    return fallback
  endif
  var wanted = overrides[action]
  return type(wanted) == v:t_string ? wanted : fallback
enddef


def SetupBufferMappings()
  for [action, fallback, plug, _] in PREVIEW_MAPPINGS
    var key = PreviewKey(action, fallback)
    if key ==# ''
      continue
    endif
    # nmap, not nnoremap: the right-hand side is a <Plug> that has to be
    # followed.  <silent> is on the <Plug> definitions themselves.
    execute printf('nmap <buffer> %s %s', key, plug)
  endfor
enddef


export def PreviewHelp()
  var rows: list<string> = []
  for [action, fallback, _, description] in PREVIEW_MAPPINGS
    var key = PreviewKey(action, fallback)
    if key ==# ''
      continue
    endif
    rows->add(printf('%-6s %s', key, description))
  endfor
  if empty(rows)
    rows = ['every preview mapping is turned off']
  endif
  if !has('popupwin')
    for row in rows
      echom row
    endfor
    return
  endif
  popup_create(rows, {
    title: ' SimpleMarkdown ',
    padding: [0, 1, 0, 1],
    border: [],
    moved: 'any',
    close: 'click',
  })
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
  var wait = delay >= 0 ? delay : Setting('simplemarkdown_debounce')
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
    unicode: Setting('simplemarkdown_style') ==# 'unicode' ? true : false,
    syntax: Setting('simplemarkdown_syntax') ? true : false,
    wrap: Setting('simplemarkdown_wrap') ? true : false,
    code_wrap: Setting('simplemarkdown_code_wrap') ? true : false,
    show_urls: Setting('simplemarkdown_show_urls') ? true : false,
    frontmatter: Setting('simplemarkdown_frontmatter') ? true : false,
    max_width: Setting('simplemarkdown_max_text_width'),
    tab_width: Setting('simplemarkdown_tab_width'),
    code_numbers: Setting('simplemarkdown_code_numbers') ? true : false,
    table_zebra: Setting('simplemarkdown_table_zebra') ? true : false,
    task_progress: Setting('simplemarkdown_task_progress') ? true : false,
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
  # Asking a daemon whose protocol we cannot read for rows would paint a
  # document laid out to a format we do not know how to place properties in.
  # The handshake already said so; a manual :SimpleMarkdownRefresh must not be
  # a way around it.
  var mismatch = ProtocolMismatch()
  if mismatch != 0
    Placeholder(key, ProtocolMessage(mismatch))
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
    incremental: session.rendered && Setting('simplemarkdown_incremental') ? true : false,
  }, (reply) => {
    OnRenderReply(key, generation, source_bufnr, source_changedtick, reply)
  }, RENDER_TIMEOUT_MS)

  if sent == 0
    session.pending = false
    requests->remove(string(id))
  endif
enddef


# A reply this session cannot use — laid out for a window size it no longer
# has, or answering a request it has already moved past.
#
# Throwing it away is not enough.  The daemon believes the client is holding
# the rows that reply carried and computes the next patch against them, so a
# session that quietly kept its older rows would splice that patch into the
# wrong document.  Say the rows are gone and ask again: `rendered` false makes
# the next request a full one, and Apply() refuses any patch that arrives in
# the meantime.  Without the re-request the preview can sit on a stale document
# indefinitely — the render that would have updated it is the one just thrown
# away.
def Discard(key: string)
  if !has_key(sessions, key)
    return
  endif
  var session = sessions[key]
  session.pending = false
  session.rendered = false
  Schedule(key, 0)
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
    Discard(key)
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
    # A render issued before the handshake landed and refused by a daemon that
    # speaks another protocol answers with whatever that daemon says about the
    # request — `unknown type render`, say.  True, and useless: the reason is
    # the version skew, and that is what the window has to keep saying.
    var mismatch = ProtocolMismatch()
    Placeholder(key, mismatch != 0 ? ProtocolMessage(mismatch) : message)
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
    Discard(key)
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
  # `rendered` false means this session is not holding the rows the daemon
  # thinks it sent — a placeholder went up, or a reply was discarded — so a
  # patch computed against those rows cannot be spliced into these.  Ask for a
  # whole document rather than splicing into the wrong one, and leave the buffer
  # alone in the meantime: what is on screen is stale, not wrong.
  if incremental && !session.rendered
    Log(printf('render %s: a patch arrived for a session that is not holding a render; resynchronising', key))
    Schedule(key, 0)
    return false
  endif
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

  # The rows and the row → source map are spliced independently since v3, so the
  # rows agreeing no longer implies the map does.  A drifted map is not a wrong
  # pixel — it is `x` toggling the wrong task and <CR> landing on the wrong
  # line — so it gets a checksum of its own.
  var src_sum = get(reply, 'src_sum', -1)
  if src_sum >= 0 && src_sum != SourceSum(session.src_map)
    Log(printf('render %s: the source map does not match the daemon''s; resynchronising', key))
    session.rendered = false
    Schedule(key, 0)
    return false
  endif

  # Counted here rather than at the splice above, and deliberately: a patch that
  # is spliced in and then thrown out by either checksum costs a whole document,
  # so counting the attempt would report the incremental path working at exactly
  # the moment it has stopped working.  `patched_renders` means a patch that
  # survived validation; anything short of that shows up as the resynchronising
  # `full_renders` it really is.
  if incremental
    patched_renders += 1
    last_patch_rows = len(get(patch, 'l', []))
  else
    full_renders += 1
    last_patch_rows = -1
  endif

  session.rendered = true
  # Absent means unchanged, not empty.  All three describe the whole document
  # however little of it moved — on a one-word edit they were the reply, the
  # patch being a rounding error beside them — so the daemon leaves out the ones
  # this session already has.  A session that threw its copies away asks with
  # `incremental` false, which is exactly what tells the daemon to send them.
  session.toc = get(reply, 'toc', session.toc)
  session.links = get(reply, 'links', session.links)
  session.blocks = get(reply, 'blocks', session.blocks)
  session.row_for_src = BuildSourceIndex(session.src_map)

  # Re-anchor on the source cursor: after an edit the row a given source line
  # maps to has usually moved.
  if Setting('simplemarkdown_sync_scroll')
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
    # Nothing moved on screen.  The daemon sends this when a keystroke did not
    # change the rendering at all — a space inside a fence, a character in a
    # comment.  The source map can still have moved underneath it: deleting one
    # of two blank lines renders identically and shifts every row below.
    return PatchSourceMap(session, patch)
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

  SpliceInto(session.lines, from, del, text)
  SpliceInto(session.src_map, from, del, src_map)
  return PatchSourceMap(session, patch)
enddef


# The second half of a v3 patch: repair the rows whose source line moved but
# whose appearance did not, which the row splice above cannot have covered
# precisely because the daemon's diff compares appearance alone.
#
# `d` shifts every non-zero entry from row `f` on — one integer for a document
# of any size, and the shape almost every insertion and deletion takes.  `s`
# carries those entries in full for the rare case a single delta cannot
# describe.  A correction that does not fit what this session holds fails
# closed: the caller then resynchronises with a whole document.
def PatchSourceMap(session: dict<any>, patch: dict<any>): bool
  var fix = get(patch, 's', {})
  if type(fix) != v:t_dict || empty(fix)
    return true
  endif
  var from = get(fix, 'f', 0)
  if from < 1 || from > len(session.src_map)
    return false
  endif
  if has_key(fix, 's')
    var tail = fix.s
    if type(tail) != v:t_list || from - 1 + len(tail) != len(session.src_map)
      return false
    endif
    SpliceInto(session.src_map, from, len(session.src_map) - from + 1, tail)
    return true
  endif
  var delta = get(fix, 'd', 0)
  if delta == 0
    return true
  endif
  var index = from - 1
  while index < len(session.src_map)
    # A row that came from no particular source line — a box border, a blank
    # spacer — stays at 0; it did not move, it never had a place.
    if session.src_map[index] > 0
      session.src_map[index] += delta
    endif
    index += 1
  endwhile
  return true
enddef


# `list[from - 1 : from - 1 + del] = replacement`, in place.
#
# Spelled out because Vim's slice indices are end-relative when negative and
# `list[0 : -1]` is not the empty list — and done with remove()/extend() rather
# than by building `head + replacement + tail`, which allocated a fresh copy of
# the whole document for each of the two lists on every patched keystroke:
# measured at 0.21 ms each against 0.013 ms on a 4200-row document.  The lists
# are the session's own and nothing else holds them; DebugSourceMap() hands out
# a copy().
def SpliceInto(list_: list<any>, from: number, del: number, replacement: list<any>)
  if del > 0
    remove(list_, from - 1, from - 2 + del)
  endif
  if !empty(replacement)
    extend(list_, replacement, from - 1)
  endif
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


# The checksum the daemon sends the map with.
#
# A `for` loop rather than reduce(): inside a compiled function reduce() pays a
# lambda call per element, and this runs over the whole map on every patched
# keystroke — 0.64 ms against 0.078 ms on a 4200-row document.  (Uncompiled the
# comparison is the other way round, which is a good way to measure this wrong.)
def SourceSum(src_map: list<number>): number
  var sum = 0
  for src in src_map
    sum += src
  endfor
  return sum
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
  if !Setting('simplemarkdown_focus_block') || !bufexists(session.bufnr)
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
  if !Setting('simplemarkdown_link_hint')
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
  if !Setting('simplemarkdown_sync_back')
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
  if empty(info)
    return
  endif
  if info[0].linecount > HUGE_BUFFER_LINES && mode() =~# '^[iR]'
    # Live rendering a novel on every keystroke is not a service to anybody —
    # to a preview window or to a browser, and the cost that matters is the
    # same one either way: this buffer, encoded as JSON, on the main thread.
    # The write and :SimpleMarkdownRefresh paths still work.
    return
  endif
  # Before the in-Vim preview's own check: the two previews are independent,
  # and a browser preview open on a buffer with no preview window is an
  # ordinary thing to want.
  simplemarkdown#external#OnTextChanged(bufnr)
  if empty(SessionKeysForSourceBuffer(bufnr))
    return
  endif
  ScheduleSourceSessions(bufnr)
enddef


# A save is the moment a document is worth checking: it is finished enough to
# be written and the diagnostics are still about what is on screen.  Silent —
# the list is filled, nothing is opened and nothing is echoed — because a
# command that grabs the screen on every `:w` is one people stop saving with.
export def OnWritten(bufnr: number)
  # A preview that is not following the buffer follows the write instead, so
  # this happens whatever the linter is set to.
  simplemarkdown#external#OnWritten(bufnr)
  if !Setting('simplemarkdown_lint_on_write')
    return
  endif
  if bufnr <= 0 || bufnr != bufnr('%') || !IsMarkdownBuffer(bufnr)
    return
  endif
  Lint(false)
enddef


export def OnCursorMoved(winid: number)
  simplemarkdown#external#OnCursorMoved(winid)
  PruneSessions()
  var preview = SessionForPreviewWindow(winid)
  if preview !=# ''
    HintLink(sessions[preview])
    SyncToPreview(preview)
    return
  endif
  if !Setting('simplemarkdown_sync_scroll')
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
  if !Setting('simplemarkdown_auto_close')
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
  if has_key(pending_anchors, string(bufnr))
    pending_anchors->remove(string(bufnr))
  endif
  for [key, session] in items(sessions)
    if session.bufnr == bufnr
      DropSession(key)
    elseif session.src_bufnr == bufnr && Setting('simplemarkdown_auto_close')
      CloseSession(key)
    endif
  endfor
  simplemarkdown#external#OnBufferWipeout(bufnr)
enddef


export def MaybeAutoOpen()
  if !Setting('simplemarkdown_auto_open')
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
  # The browser preview is refreshed by the same command, and the thing it can
  # be stale about is not the document — that follows the buffer — but the
  # options it was opened with.
  simplemarkdown#external#OnOptionsChanged()
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
    # Through the table, not straight into `g:`: the floor was applied here
    # already, but the ceiling the table declares was not, so a number above it
    # was stored as written and reported as a misconfiguration ever after.
    # Capping is worth a word too — a command that quietly does something other
    # than what it was asked is one whose silence stops meaning anything.
    var floor: number = Setting('simplemarkdown_min_width')
    var stored = max([floor, wanted])
    var complaint = PutSetting('simplemarkdown_width', stored)
    if complaint !=# ''
      Warn(complaint)
    elseif stored != wanted
      # The floor is this command's own, applied above rather than declared in
      # the table, so `Coerce` is handed a number already inside its range and
      # has nothing to say about it.  Raising one is as much "something other
      # than what it was asked" as capping one, and the help promises both are
      # said out loud, so this half is said here.
      Warn(printf('g:simplemarkdown_width = %d is below g:simplemarkdown_min_width = %d — using %d',
        wanted, floor, stored))
    endif
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
    var current = index(styles, Setting('simplemarkdown_style'))
    wanted = styles[current < 0 ? 0 : (current + 1) % len(styles)]
  endif
  if index(styles, wanted) < 0
    echohl ErrorMsg
    echom '[SimpleMarkdown] style must be "unicode" or "ascii".'
    echohl None
    return
  endif
  # Already known to be one of the two, but written through the table anyway:
  # "every command that writes an option writes it through PutSetting" is an
  # invariant worth being able to state without exceptions.
  PutSetting('simplemarkdown_style', wanted)
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


# The binary in lib/ against the sources it was built from.  A plugin manager
# updates the Vim files and the Rust files together and rebuilds neither, so
# "the backend is older than its source" is the single most useful fact a
# health report can carry — and the one it never had.
def BackendStaleness(): string
  var exe = simplemarkdown#core#Health().exe_path
  if exe ==# '' || !filereadable(exe)
    return ''
  endif
  var built = getftime(exe)
  var newest = 0
  for source in glob(fnamemodify(exe, ':p:h:h') .. '/src/**/*.rs', false, true)
    var stamp = getftime(source)
    if stamp > newest
      newest = stamp
    endif
  endfor
  if newest <= 0 || built <= 0
    # No sources beside it: an installed copy rather than a working tree.
    return ''
  endif
  return built >= newest
    ? printf('[OK] backend: built %s, newer than its sources', strftime('%Y-%m-%d %H:%M', built))
    : printf('[WARN] backend: built %s, older than src/ (%s). Run ./install.sh, then :SimpleMarkdownRestart.',
        strftime('%Y-%m-%d %H:%M', built), strftime('%Y-%m-%d %H:%M', newest))
enddef


export def Health()
  SetupCore()
  var lines = simplemarkdown#core#HealthLines()
  var negotiated = simplemarkdown#core#Protocol()
  add(lines, negotiated == PROTOCOL_VERSION || !simplemarkdown#core#Ready()
    ? printf('[OK] protocol: plugin speaks v%d', PROTOCOL_VERSION)
    : printf('[ERROR] protocol: plugin speaks v%d, the daemon speaks v%d. '
        .. 'Run ./install.sh, then :SimpleMarkdownRestart.', PROTOCOL_VERSION, negotiated))
  var staleness = BackendStaleness()
  if staleness !=# ''
    add(lines, staleness)
  endif
  add(lines, printf('[INFO] preview sessions: %d', len(sessions)))
  if last_elapsed_ms >= 0
    add(lines, printf('[INFO] last render: %dms', last_elapsed_ms))
  endif
  add(lines, printf('[INFO] renders: %d incremental, %d full%s',
    patched_renders, full_renders,
    last_patch_rows >= 0 ? printf(' (last patch: %d rows)', last_patch_rows) : ''))
  add(lines, printf('[%s] text properties: %s',
    has('textprop') ? 'OK' : 'ERROR', has('textprop') ? 'available' : 'missing'))
  # The configuration, including what was quietly corrected at load.  An option
  # that does not hold what it says it holds is the first thing to rule out and
  # the last thing anyone thinks to check, because `g:` reads back as correct.
  var problems = ValidateConfig()
  if empty(problems)
    add(lines, printf('[OK] config: %d options, all valid', len(SETTINGS)))
  else
    lines += problems
  endif
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
    style: Setting('simplemarkdown_style'),
    patched_renders: patched_renders,
    full_renders: full_renders,
    last_patch_rows: last_patch_rows,
    external: simplemarkdown#external#Status(),
  }
enddef


# The row → source map of the session this window belongs to.  Deliberately not
# a key of DebugStatus(): `:SimpleMarkdownDebug` echoes that dict, and one
# integer per preview row would bury everything else on any real document.  It
# exists so a test can compare the map two renders produced — the map is half of
# what a render *is*, and unlike the rows it leaves no trace on screen, so
# nothing else can tell a correct one from a plausible one.
export def DebugSourceMap(): list<number>
  var key = CurrentPreviewSession()
  if key ==# '' || !has_key(sessions, key)
    return []
  endif
  return copy(sessions[key].src_map)
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


def Warn(message: string)
  echohl WarningMsg
  echom '[SimpleMarkdown] ' .. message
  echohl None
enddef


# What an answer that arrived on the channel says when it went well.
#
# `echom` rather than `echo`: this runs in a channel callback, minutes of
# thinking or milliseconds after the command, and a plain `echo` from there is
# painted over by the next redraw with nothing left behind.  The result of a
# command a user typed has to be findable in `:messages` afterwards.
def Say(message: string)
  echom '[SimpleMarkdown] ' .. message
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
    Warn('no preview session in this tab page.')
    return
  endif
  var session = sessions[key]
  var src = 0
  if win_getid() == session.winid
    if !SourceMapCurrent(session)
      Warn('preview mapping is stale; refreshing.')
      ScheduleSourceSessions(session.src_bufnr, 0)
      return
    endif
    var row = line('.') - 1
    src = row >= 0 && row < len(session.src_map) ? session.src_map[row] : 0
  elseif bufnr('%') == session.src_bufnr
    src = line('.')
  endif
  if src <= 0
    Warn('no task on this preview row.')
    return
  endif
  if !getbufvar(session.src_bufnr, '&modifiable')
    Warn('source buffer is not modifiable.')
    return
  endif
  var source = get(getbufline(session.src_bufnr, src), 0, '')
  var marker = TaskMarker(source)
  if marker < 0
    Warn('source line is not a task item.')
    return
  endif
  var checked = source[marker + 1] !=# ' '
  var replacement = checked ? ' ' : 'x'
  var updated = strpart(source, 0, marker + 1) .. replacement
        \ .. strpart(source, marker + 2)
  if setbufline(session.src_bufnr, src, updated) != 0
    Warn('could not update the source buffer.')
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

  # A document in a SimpleRemote virtual workspace is a `remote:///abs/path`
  # buffer: its neighbours are on the remote host, so the link is resolved
  # against the remote path and opened as another remote:// buffer, which
  # SimpleRemote's BufReadCmd fills.  There is nothing to test for readability
  # here — SimpleRemote reports a missing file itself — and the anchor jump has
  # to wait for the text, which arrives asynchronously.
  var remote = RemoteInfo(src_bufnr)
  if !empty(remote)
    var uri = 'remote://' .. RemoteHrefPath(remote.path, target)
    if !empty(session) && WindowExists(session.src_winid)
      win_gotoid(session.src_winid)
    endif
    # A link to the document itself — `README.md#usage` — is a jump, not a
    # reload of a buffer that may have unwritten changes.
    if bufname('%') !=# uri
      execute 'edit ' .. fnameescape(uri)
    endif
    if anchor !=# ''
      var buf = bufnr('%')
      if RemoteFillPending(buf)
        pending_anchors[string(buf)] = anchor
      else
        JumpToAnchorHere(anchor)
      endif
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


# ─────────────────────────── remote workspaces ───────────────────────────
#
# SimpleRemote (a sibling plugin, never required) opens files of an SSH host or
# a Docker container in one of two shapes.  A *projected* workspace mounts or
# maps the remote tree onto local paths, and such buffers are ordinary files to
# this plugin.  A *virtual* workspace opens `remote:///abs/path` buffers with
# 'buftype' acwrite and `b:vimrc_remote = {path, uri, generation}`, filled by a
# BufReadCmd and announced by `User SimpleRemoteBufferRead`; those need the
# handful of accommodations below.  Everything is feature-detected: without
# SimpleRemote none of it is reached.

# `b:vimrc_remote` of a SimpleRemote virtual buffer, or {} for any other buffer.
export def RemoteInfo(bufnr: number): dict<any>
  if bufnr <= 0
    return {}
  endif
  var info = getbufvar(bufnr, 'vimrc_remote', {})
  if type(info) != v:t_dict || type(get(info, 'path', 0)) != v:t_string
      || info.path !~# '^/'
    return {}
  endif
  return info
enddef


# ' @kind:target:root' for a document that lives in a SimpleRemote workspace —
# virtual or projected — so that a preview of `README.md` on a remote host is
# not titled like the local one; '' for a local file.
export def RemoteSuffix(bufnr: number): string
  if !exists('*g:SimpleRemoteStatusline')
    return ''
  endif
  var projected = getbufvar(bufnr, 'simpleremote_path', '')
  if empty(RemoteInfo(bufnr)) && (type(projected) != v:t_string || projected ==# '')
    return ''
  endif
  var status = g:SimpleRemoteStatusline()
  return type(status) == v:t_string && status !=# '' ? ' @' .. status : ''
enddef


# Where `target`, as written in the remote document at `remote_path`, lives on
# the remote host.  Absolute hrefs name the remote filesystem; relative ones
# the document's directory.  simplify() runs on the bare path — on
# `remote:///a/../b` it would collapse the `///` and hand back a second buffer
# name for the same file.
def RemoteHrefPath(remote_path: string, target: string): string
  if target =~# '^/'
    return simplify(target)
  endif
  var dir = fnamemodify(remote_path, ':h')
  return simplify(dir ==# '/' ? '/' .. target : dir .. '/' .. target)
enddef


# Whether SimpleRemote has still to fill `buf`: a remote:// buffer that has been
# opened and not yet read has no `b:vimrc_remote` (it is set after the fill),
# and one being re-read carries the read it is waiting for in
# `b:vimrc_remote_read`.
def RemoteFillPending(buf: number): bool
  if empty(RemoteInfo(buf))
    return true
  endif
  var reading = getbufvar(buf, 'vimrc_remote_read', {})
  return type(reading) == v:t_dict && !empty(reading)
enddef


# `User SimpleRemoteBufferRead`: SimpleRemote has (re)filled remote:// buffer
# `bufnr` from a channel callback, which is not a TextChanged, so the previews
# are told the way an edit tells them; and a link followed into this buffer
# while it was still empty gets its `#anchor` jump now that the headings are
# there.
export def OnRemoteBufferRead(bufnr: number)
  if bufnr <= 0 || !bufexists(bufnr)
    return
  endif
  OnTextChanged(bufnr)
  if !has_key(pending_anchors, string(bufnr))
    return
  endif
  var anchor = pending_anchors->remove(string(bufnr))
  var winid = bufnr('%') == bufnr ? win_getid() : bufwinid(bufnr)
  if winid > 0
    win_execute(winid, 'call simplemarkdown#JumpToAnchor(' .. string(anchor) .. ')')
  endif
enddef


# The deferred half of FollowHref for a remote document, run inside the window
# holding it.  Public only so that win_execute() can name it.
export def JumpToAnchor(anchor: string)
  JumpToAnchorHere(anchor)
enddef


const IMAGE_PATTERNS: list<string> = [
  '!\[[^]]*\]([^()]*)',
  '!\[[^]]*\]\[[^]]*\]',
  '\c<img\s[^>]*>',
]

# The `src` of a raw `<img>`, quoted or not.  HTML5 allows `<img src=plot.png>`
# and generators emit it; the daemon passes such a tag into the page verbatim,
# so an href only the quoted branch recognised was one the browser asked for
# and the staging never fetched — a broken picture that :SimpleMarkdownHealth
# did not even count as missing.  The unquoted value ends at whitespace or at
# the `>` that ends the tag, which is what an HTML parser does with it.  The
# preceding whitespace is required so that `data-src=` is not read as `src=`.
const IMG_SRC_PATTERN =
  '\c\s\+src\s*=\s*\%(["'']\zs[^"'']*\|\zs[^"''[:space:]>]\+\)'

# Every image the document draws — `![alt](href)`, `![alt][ref]` through its
# `[ref]:` definition, and a raw `<img src=…>` with the value quoted or not —
# as the hrefs it wrote, in document order, each once.  Fenced code is skipped, as it is for headings: a
# `![](x.png)` in a Markdown tutorial's code sample draws nothing.  What the
# browser preview stages for a remote document; nothing here decides whether an
# href can be fetched.
export def ImageHrefs(bufnr: number): list<string>
  var out: list<string> = []
  var seen: dict<bool> = {}
  var fence = ''
  for line in getbufline(bufnr, 1, '$')
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
    for pattern in IMAGE_PATTERNS
      var start = 0
      while start <= len(line)
        var [matched, from, to] = matchstrpos(line, pattern, start)
        if from < 0
          break
        endif
        var href = matched =~? '^<img'
          ? matchstr(matched, IMG_SRC_PATTERN)
          : HrefOfMatch(matched, bufnr)
        if href !=# '' && !has_key(seen, href)
          seen[href] = true
          add(out, href)
        endif
        start = to > from ? to : from + 1
      endwhile
    endfor
  endfor
  return out
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


# ─────────────────────────── authoring ───────────────────────────

# Replace source lines `from`..`to` of `buf` with `replacement`.
#
# Equal counts are the common case and are one `setbufline()`, hence one undo
# step — a formatter a user cannot undo with a single `u` is one they stop
# using.  The unequal cases are handled rather than refused so that an
# operation which does change a document's height has somewhere to land.
def ReplaceRange(buf: number, from: number, to: number, replacement: list<string>)
  var had = to - from + 1
  var common = min([had, len(replacement)])
  if common > 0
    setbufline(buf, from, replacement[0 : common - 1])
  endif
  if len(replacement) > had
    appendbufline(buf, from + common - 1, replacement[common : ])
  elseif len(replacement) < had
    deletebufline(buf, from + common, to)
  endif
enddef


# Everything a command that writes to the document has to be sure of before it
# sends anything: that this is a source buffer holding Markdown, that it may be
# written to, and that the backend on the other end understands the request.
# Shared so that a new authoring command cannot quietly acquire a weaker set of
# checks than the ones already here — the preview buffer in particular is a
# scratch buffer whose text is a layout, and editing it edits nothing.
def AuthoringReady(buf: number, capability: string, ability: string): bool
  if IsPreviewBuffer(buf)
    Warn('this command edits the document: run it in the source buffer.')
    return false
  endif
  if !IsMarkdownBuffer(buf)
    Warn('not a Markdown buffer.')
    return false
  endif
  if !getbufvar(buf, '&modifiable')
    Warn('buffer is not modifiable.')
    return false
  endif
  if !EnsureBackend()
    return false
  endif
  var mismatch = ProtocolMismatch()
  if mismatch != 0
    Warn(ProtocolMessage(mismatch))
    return false
  endif
  # A daemon old enough to predate this request answers `invalid request`,
  # which arrives as an opaque error some time after the keystroke.  The
  # handshake already said what this one can do.
  if simplemarkdown#core#Ready() && !simplemarkdown#core#HasCap(capability)
    Warn(printf('this backend cannot %s. Run ./install.sh, then :SimpleMarkdownRestart.',
      ability))
    return false
  endif
  return true
enddef


# The daemon owns table formatting for the same reason it owns the preview: a
# column is as wide as its widest cell *on screen*, and the only measure
# Vimscript has for that is strdisplaywidth(), which answers for the terminal
# this Vim is running in rather than for the file.  Asking also settles which
# lines are the table with a parser, so a `|` inside a fenced code block is not
# mistaken for a row and a table inside a block quote keeps its `> `.
export def FormatTable()
  var buf = bufnr('%')
  if !AuthoringReady(buf, 'format', 'format tables')
    return
  endif

  # The reply names line numbers in the document that was sent.  Recording the
  # tick here is what makes applying it to a buffer that has moved on
  # impossible rather than merely unlikely.
  var tick: number = getbufvar(buf, 'changedtick')
  var sent = simplemarkdown#core#Request({
    type: 'format_table',
    id: NextId(),
    lines: getbufline(buf, 1, '$'),
    line: line('.'),
  }, (reply) => OnFormatReply(buf, tick, reply), RENDER_TIMEOUT_MS)
  if sent == 0
    Warn('the backend is not running.')
  endif
enddef


def OnFormatReply(buf: number, tick: number, reply: dict<any>)
  if get(reply, '_failed', false) || get(reply, 'type', '') ==# 'error'
    Warn(get(reply, 'message', 'the backend could not format this table.'))
    return
  endif
  var from = get(reply, 'from', 0)
  if from <= 0
    Warn('no table under the cursor.')
    return
  endif
  if !bufexists(buf)
    return
  endif
  if getbufvar(buf, 'changedtick') != tick
    Warn('the buffer changed while the table was being formatted.')
    return
  endif
  if !getbufvar(buf, '&modifiable')
    Warn('buffer is not modifiable.')
    return
  endif
  var to = get(reply, 'to', from)
  var replacement: list<string> = get(reply, 'lines', [])
  if empty(replacement) || to < from
    return
  endif
  if getbufline(buf, from, to) ==# replacement
    Say('the table is already aligned')
    return
  endif
  ReplaceRange(buf, from, to, replacement)
  ScheduleSourceSessions(buf, 0)
  Say(printf('aligned %d table row%s',
    len(replacement), len(replacement) == 1 ? '' : 's'))
enddef


# `:SimpleMarkdownPromote`, `:SimpleMarkdownDemote` and `:SimpleMarkdownRenumber`
# — the structural edits, all three the same round trip with a different verb.
#
# The daemon is asked rather than a pattern applied for the reason it renders:
# a `#` at the start of a line inside a fenced shell block is a comment, `1.` in
# a code sample is not a list item, and a setext underline makes a heading out
# of a line with no `#` on it at all.  `:%s/^#/##/` gets all three wrong, and
# the last one it cannot even see.
#
# `from` and `to` are the command's range.  Equal — which is what a bare
# `:SimpleMarkdownDemote` gives, the cursor's line — means the whole section for
# the heading ops, so a chapter takes its subsections down with it and the tree
# still says what it said.  A range the user drew means exactly the headings
# inside it.
export def Promote(from: number, to: number)
  SendEdit('promote', from, to)
enddef

export def Demote(from: number, to: number)
  SendEdit('demote', from, to)
enddef

export def Renumber(from: number, to: number)
  SendEdit('renumber', from, to)
enddef

# What each op is called when something has to be said about it: the ability
# for a capability refusal, and the past tense for the count afterwards.
const EDIT_VERBS: dict<list<string>> = {
  promote: ['shift heading levels', 'promoted', 'heading'],
  demote: ['shift heading levels', 'demoted', 'heading'],
  renumber: ['renumber lists', 'renumbered', 'list item'],
}

def SendEdit(op: string, from: number, to: number)
  var buf = bufnr('%')
  if !AuthoringReady(buf, 'edit', EDIT_VERBS[op][0])
    return
  endif
  # The reply names lines in the document that was sent; the tick is what makes
  # applying it to a buffer that has moved on impossible rather than unlikely.
  var tick: number = getbufvar(buf, 'changedtick')
  var sent = simplemarkdown#core#Request({
    type: 'edit',
    id: NextId(),
    op: op,
    lines: getbufline(buf, 1, '$'),
    from: from,
    to: to,
  }, (reply) => OnEditReply(buf, tick, op, reply), RENDER_TIMEOUT_MS)
  if sent == 0
    Warn('the backend is not running.')
  endif
enddef


def OnEditReply(buf: number, tick: number, op: string, reply: dict<any>)
  if get(reply, '_failed', false) || get(reply, 'type', '') ==# 'error'
    # A refusal — "promoting would take "Top" past H1" — is the answer to what
    # the user asked and is shown as it came.
    Warn(get(reply, 'message', 'the backend could not make this edit.'))
    return
  endif
  if !bufexists(buf)
    return
  endif
  if getbufvar(buf, 'changedtick') != tick
    Warn('the buffer changed while the edit was being worked out.')
    return
  endif
  if !getbufvar(buf, '&modifiable')
    Warn('buffer is not modifiable.')
    return
  endif
  var edits: list<any> = get(reply, 'edits', [])
  if empty(edits)
    Say(op ==# 'renumber'
      ? 'no ordered list here, or it is already numbered'
      : 'no heading here')
    return
  endif
  # Bottom up: a setext heading demoted past H2 becomes one ATX line, and every
  # range above an edit that changes the document's height is only valid while
  # that edit has not been made yet.
  for change in sort(copy(edits), (a, b) => get(b, 'from', 0) - get(a, 'from', 0))
    ReplaceRange(buf, get(change, 'from', 0), get(change, 'to', 0),
      get(change, 'lines', []))
  endfor
  ScheduleSourceSessions(buf, 0)
  Say(printf('%s %d %s%s', EDIT_VERBS[op][1], len(edits),
    EDIT_VERBS[op][2], len(edits) == 1 ? '' : 's'))
enddef

# ─────────────────────────── diagnostics ───────────────────────────

# Run `command` in `winid`.  Directly when that is where we already are:
# win_execute() cannot open a window from another window's context, and the
# location list is per window, so `lopen` has to happen in the window whose
# list was just set.
def InWindow(winid: number, command: string)
  if win_getid() == winid
    execute command
  else
    win_execute(winid, command)
  endif
enddef


# `:SimpleMarkdownLint`.  `reveal` is false for the on-write pass: it fills the
# location list and says nothing, so a save does not steal the screen.
export def Lint(reveal: bool = true)
  var buf = bufnr('%')
  if !IsMarkdownBuffer(buf)
    if reveal
      Warn('not a Markdown buffer.')
    endif
    return
  endif
  if !EnsureBackend()
    return
  endif
  var mismatch = ProtocolMismatch()
  if mismatch != 0
    if reveal
      Warn(ProtocolMessage(mismatch))
    endif
    return
  endif
  if simplemarkdown#core#Ready() && !simplemarkdown#core#HasCap('lint')
    if reveal
      Warn('this backend cannot lint. Run ./install.sh, then :SimpleMarkdownRestart.')
    endif
    return
  endif
  var winid = win_getid()
  var sent = simplemarkdown#core#Request({
    type: 'lint',
    id: NextId(),
    lines: getbufline(buf, 1, '$'),
  }, (reply) => OnLintReply(buf, winid, reveal, reply), RENDER_TIMEOUT_MS)
  if sent == 0 && reveal
    Warn('the backend is not running.')
  endif
enddef


def OnLintReply(buf: number, winid: number, reveal: bool, reply: dict<any>)
  if get(reply, '_failed', false) || get(reply, 'type', '') ==# 'error'
    if reveal
      Warn(get(reply, 'message', 'the backend could not check this document.'))
    endif
    return
  endif
  # The window may have been closed while the answer was in flight; its
  # location list went with it.
  if !bufexists(buf) || !WindowExists(winid)
    return
  endif

  var entries: list<dict<any>> = []
  for item in get(reply, 'items', [])
    entries->add({
      bufnr: buf,
      lnum: get(item, 'line', 1),
      col: get(item, 'col', 1),
      type: get(item, 'severity', 'W'),
      # The code goes in the text rather than in `nr`: quickfix prints `nr` as
      # a bare number, and `broken-anchor` is the half of a diagnostic a reader
      # can act on without opening the help.
      text: printf('%s: %s', get(item, 'code', ''), get(item, 'text', '')),
    })
  endfor
  setloclist(winid, [], ' ', {items: entries, title: 'SimpleMarkdown diagnostics'})

  if empty(entries)
    if reveal
      # A window still showing the last run's problems is worse than no window:
      # every one of them has just been fixed.
      InWindow(winid, 'lclose')
      echo '[SimpleMarkdown] no problems found'
    endif
    return
  endif
  if reveal
    InWindow(winid, 'lopen')
    echo printf('[SimpleMarkdown] %d problem%s', len(entries), len(entries) == 1 ? '' : 's')
  endif
enddef


# `]]` / `[[`.  In the preview this moves between rendered headings; in a
# Markdown source buffer it moves this cursor between real ones, which is what
# pressing it there means — it used to reach across and move a preview window's
# cursor while leaving yours where it was.
export def NextHeading(direction: number)
  var key = SessionForPreviewWindow(win_getid())
  if key ==# ''
    SourceNextHeading(direction)
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
  if key ==# '' || !has_key(sessions, key) || empty(get(sessions[key], 'toc', []))
    # In the preview itself there is nothing else to ask: its session is the
    # document, and an empty outline means the document has no headings.
    if IsPreviewBuffer(bufnr('%'))
      Warn('no headings in this document.')
      return
    endif
    # Otherwise ask the backend for the headings, which is cheap — no width, no
    # wrapping, no highlighting.  Answering "what is in this document" by
    # splitting the window and starting a render is a surprise: the question
    # was about the document, not about the screen.
    SourceToc()
    return
  endif
  var session = sessions[key]

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

# ─────────────────────────── the outline ───────────────────────────
#
# The heading tree of a source buffer, independent of any preview.  A render's
# table of contents is a by-product of laying rows out for a window of some
# width; this is the same question asked directly, and two things need it where
# no preview exists: `:SimpleMarkdownToc` in a plain buffer, and folding, which
# Vim asks about once per line per redraw and can never be made to wait.
#
# Held in buffer variables rather than in `sessions`, because it belongs to the
# document rather than to a window:
#   b:simplemarkdown_outline       the entries the backend last sent
#   b:simplemarkdown_outline_tick  the changedtick they describe
#   b:simplemarkdown_outline_wait  the changedtick a request is out for
#   b:simplemarkdown_outline_due   the changedtick a refresh is armed for
#   b:simplemarkdown_outline_timer the timer that will send it
#   b:simplemarkdown_outline_id    the background request in flight, to withdraw
#   b:simplemarkdown_folds         one foldexpr answer per line, from the above

# `background` is a refresh nobody asked for by name — the folding path.  It is
# the one that may be withdrawn when a newer one supersedes it: a `:...Toc` is
# waiting on its own reply and cancelling that would leave the popup that never
# opens.
def RequestOutline(buf: number, Done: func(list<any>), background: bool = false): bool
  if !IsMarkdownBuffer(buf) || !EnsureBackend() || ProtocolMismatch() != 0
    return false
  endif
  if simplemarkdown#core#Ready() && !simplemarkdown#core#HasCap('outline')
    return false
  endif
  var tick: number = getbufvar(buf, 'changedtick')
  if background
    var superseded: number = getbufvar(buf, 'simplemarkdown_outline_id', 0)
    if superseded > 0
      # The daemon is parsing a document this buffer has already moved past.
      # Withdrawing it is what the render path does with a superseded render,
      # and for the same reason: the whole document goes into every one of
      # these, and a parse nobody will read still costs a core.
      simplemarkdown#core#Cancel(superseded)
      simplemarkdown#core#Send({type: 'cancel', id: superseded})
      setbufvar(buf, 'simplemarkdown_outline_id', 0)
    endif
  endif
  var id = NextId()
  # Whichever kind it is, this tick now has a request out for it, so the
  # foldexpr path does not arm a second one behind it.
  setbufvar(buf, 'simplemarkdown_outline_wait', tick)
  if background
    setbufvar(buf, 'simplemarkdown_outline_id', id)
  endif
  var sent = simplemarkdown#core#Request({
    type: 'outline',
    id: id,
    lines: getbufline(buf, 1, '$'),
  }, (reply) => {
    if getbufvar(buf, 'simplemarkdown_outline_id', 0) == id
      setbufvar(buf, 'simplemarkdown_outline_id', 0)
    endif
    if get(reply, '_failed', false) || get(reply, 'type', '') !=# 'outline_result'
      return
    endif
    var entries: list<any> = get(reply, 'toc', [])
    CacheOutline(buf, tick, entries)
    Done(entries)
  }, RENDER_TIMEOUT_MS)
  if sent == 0
    setbufvar(buf, 'simplemarkdown_outline_wait', -1)
    setbufvar(buf, 'simplemarkdown_outline_id', 0)
  endif
  return sent != 0
enddef


def CacheOutline(buf: number, tick: number, entries: list<any>)
  if !bufexists(buf)
    return
  endif
  # The backend answers concurrently, so two outlines in flight can land in
  # the other order.  Taking the older one back would not merely show a stale
  # heading tree for a moment: it also writes back an older tick, and
  # EnsureOutline is by then waiting on the newer one — so nothing would ever
  # ask again and the folds would stay wrong until the next edit.
  if tick < getbufvar(buf, 'simplemarkdown_outline_tick', -1)
    return
  endif
  var previous = getbufvar(buf, 'simplemarkdown_outline', [])
  var count = get(getbufinfo(buf), 0, {linecount: 0}).linecount
  setbufvar(buf, 'simplemarkdown_outline', entries)
  setbufvar(buf, 'simplemarkdown_outline_tick', tick)
  # The folds are a function of the heading tree and the line count, so when
  # neither moved there is nothing to rebuild and — more to the point — nothing
  # to invalidate.  The invalidation below costs one foldexpr call per line of
  # the buffer, and most edits do not touch a heading: typing inside a paragraph
  # of a 3800-line document was paying 58 ms of Vim to be told the folds it
  # already had.
  if getbufvar(buf, 'simplemarkdown_folds_lines', -1) == count
      && type(previous) == v:t_list && previous == entries
    return
  endif
  setbufvar(buf, 'simplemarkdown_folds', BuildFolds(entries, count))
  setbufvar(buf, 'simplemarkdown_folds_lines', count)
  # Vim caches what foldexpr answered and only asks again when the buffer
  # changes.  This answer arrived without one, so nothing would ask.
  #
  # Setting 'foldexpr' to the value it already has is what invalidates that
  # cache: Vim recomputes the folds from scratch and keeps the open/closed
  # state of the ones that come back the same.  `zx` also recomputes them, but
  # `zx` *means* "undo manually opened and closed folds" — with it here, every
  # section a reader had closed sprang open one keystroke later, in this window
  # and (through the `zv` it ends with) around every other cursor on the
  # buffer.  A background refresh must not touch what the reader folded.
  for winid in win_findbuf(buf)
    var expr: string = getwinvar(winid, '&foldexpr', '')
    if getwinvar(winid, '&foldmethod') ==# 'expr' && expr !=# ''
      win_execute(winid, 'setlocal foldexpr=' .. escape(expr, ' \|"'))
    endif
  endfor
enddef


# One foldexpr answer per line: `>N` opens a section at level N, `N` continues
# it, `0` is everything above the first heading.  Deeper sections are written
# after the ones containing them, so a nested heading simply overwrites its
# parent's level over its own lines.
def BuildFolds(entries: list<any>, count: number): list<string>
  var folds: list<string> = repeat(['0'], count)
  for entry in entries
    var level = get(entry, 'level', 1)
    var from = get(entry, 'src', 0)
    var to = min([get(entry, 'end_src', 0), count])
    if from < 1 || from > count || to < from
      continue
    endif
    for lnum in range(from, to)
      folds[lnum - 1] = string(level)
    endfor
    folds[from - 1] = '>' .. level
  endfor
  return folds
enddef


# Ask for a fresh outline if this buffer's has been overtaken by an edit, at
# most once per changedtick.  Called from foldexpr, so it must do nothing at
# all in the common case: three buffer-variable reads.
#
# Debounced on |g:simplemarkdown_debounce|, the same option and for the same
# reason a render is.  Once per changedtick still meant once per edit, and an
# outline request carries the whole document and costs a whole parse — so
# typing a word with folding on sent a full copy of the file per keystroke, and
# ran as many parses concurrently as the typing outran the daemon.  What the
# reader is waiting for is the fold structure after they stop, not one per
# character on the way there.
def EnsureOutline(buf: number)
  var tick: number = getbufvar(buf, 'changedtick')
  if getbufvar(buf, 'simplemarkdown_outline_tick', -1) == tick
      || getbufvar(buf, 'simplemarkdown_outline_wait', -1) == tick
      || getbufvar(buf, 'simplemarkdown_outline_due', -1) == tick
    return
  endif
  # Set before anything can fail, and never cleared: this is what stops the
  # foldexpr from asking again for a tick already dealt with, whether the
  # request went out, was refused, or is still sitting behind the timer.
  setbufvar(buf, 'simplemarkdown_outline_due', tick)
  var armed: number = getbufvar(buf, 'simplemarkdown_outline_timer', 0)
  if armed > 0
    timer_stop(armed)
    setbufvar(buf, 'simplemarkdown_outline_timer', 0)
  endif
  var wait = Setting('simplemarkdown_debounce')
  if wait <= 0
    RequestOutline(buf, (_) => {
    }, true)
    return
  endif
  setbufvar(buf, 'simplemarkdown_outline_timer', timer_start(wait, (_) => {
    if !bufexists(buf)
      return
    endif
    setbufvar(buf, 'simplemarkdown_outline_timer', 0)
    RequestOutline(buf, (_) => {
    }, true)
  }))
enddef


# `:SimpleMarkdownToc` with no preview open.
def SourceToc()
  var buf = bufnr('%')
  if !IsMarkdownBuffer(buf)
    Warn('not a Markdown buffer.')
    return
  endif
  var winid = win_getid()
  if !RequestOutline(buf, (entries) => ShowSourceToc(buf, winid, entries))
    Warn('the backend cannot list this document''s headings.')
  endif
enddef


def ShowSourceToc(buf: number, winid: number, entries: list<any>)
  if empty(entries)
    Warn('no headings in this document.')
    return
  endif
  if !WindowExists(winid)
    return
  endif
  var items: list<string> = []
  for entry in entries
    items->add(printf('%s%s', repeat('  ', get(entry, 'level', 1) - 1), get(entry, 'text', '')))
  endfor

  if !has('popupwin')
    var loc: list<dict<any>> = []
    for entry in entries
      add(loc, {bufnr: buf, lnum: get(entry, 'src', 1), text: get(entry, 'text', '')})
    endfor
    setloclist(winid, [], ' ', {items: loc, title: 'SimpleMarkdown contents'})
    InWindow(winid, 'lopen')
    return
  endif

  popup_menu(items, {
    title: ' Contents ',
    padding: [0, 1, 0, 1],
    border: [],
    maxheight: max([5, &lines - 8]),
    callback: (_, index) => {
      if index <= 0 || !WindowExists(winid)
        return
      endif
      var entry = get(entries, index - 1, {})
      if empty(entry)
        return
      endif
      win_gotoid(winid)
      cursor(get(entry, 'src', 1), 1)
      normal! zz
    },
  })
enddef


# The heading lines of a source buffer, for a motion — which has to answer now.
# The cached outline is the better answer when it is current, because it comes
# from the parser; the scanner is the one that is always available, and it
# already knows not to call a `#` inside a fence a heading.
def SourceHeadingLines(buf: number): list<number>
  if getbufvar(buf, 'simplemarkdown_outline_tick', -1) == getbufvar(buf, 'changedtick')
    return mapnew(getbufvar(buf, 'simplemarkdown_outline', []),
      (_, entry) => get(entry, 'src', 0))
  endif
  # Warm the cache for next time, then answer with what is at hand.
  EnsureOutline(buf)
  return mapnew(HeadingsIn(buf), (_, heading) => heading[0])
enddef


def SourceNextHeading(direction: number)
  var buf = bufnr('%')
  if !IsMarkdownBuffer(buf)
    return
  endif
  var here = line('.')
  var lines = SourceHeadingLines(buf)
  if direction < 0
    lines = reverse(copy(lines))
  endif
  for lnum in lines
    if direction > 0 ? lnum > here : lnum < here
      cursor(lnum, 1)
      normal! zz
      return
    endif
  endfor
enddef


# Turn heading folding on for this buffer, from the FileType autocommand.
# Behind g:simplemarkdown_folding because a plugin that silently changes
# 'foldmethod' on a filetype is a plugin that gets blamed for someone else's
# folds.
export def SetupFolding()
  var buf = bufnr('%')
  if !Setting('simplemarkdown_folding') || !IsMarkdownBuffer(buf)
    return
  endif
  setlocal foldmethod=expr
  setlocal foldexpr=simplemarkdown#FoldLevel(v:lnum)
  setlocal foldtext=simplemarkdown#FoldText()
  # Opened, not closed.  A document that folds itself shut the moment it is
  # loaded is one people turn folding off for; `zM` is one keystroke away.
  setlocal foldlevel=99
  EnsureOutline(buf)
enddef


export def FoldLevel(lnum: number): string
  var buf = bufnr('%')
  EnsureOutline(buf)
  # Whatever the last outline said, including while a newer one is in flight:
  # answering 0 for a document that has one heading more than it did would
  # flatten every fold on screen for the length of a round trip.
  var folds: list<any> = getbufvar(buf, 'simplemarkdown_folds', [])
  return get(folds, lnum - 1, '0')
enddef


export def FoldText(): string
  var text = substitute(getline(v:foldstart), '^\s*#\+\s*', '', '')
  var count = v:foldend - v:foldstart + 1
  var mark = Setting('simplemarkdown_style') ==# 'unicode' ? '▸' : '+'
  return printf('%s %s  (%d lines)', mark, text, count)
enddef
