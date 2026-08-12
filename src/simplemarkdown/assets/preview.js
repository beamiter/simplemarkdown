/*
 * preview.js — the browser half of the external preview.
 *
 * The daemon renders the document and pushes it over SSE; this keeps the page
 * in step with it.  Four things earn their keep here, and they are the four
 * that decide whether a live preview is pleasant or gets switched off:
 *
 *   - the reader's place survives every swap.  A preview that jumps to the top
 *     on each keystroke is one nobody leaves open, so the topmost visible
 *     block's source line and its distance from the top of the viewport are
 *     recorded *before* the innerHTML changes and put back after it;
 *   - following the cursor yields to the wheel.  A sync-scroll that argues
 *     with the hand on the mouse is the classic failure, so editor lines are
 *     ignored for a moment after the reader has scrolled by hand;
 *   - nothing is searched linearly.  A 3000-line document arrives on every
 *     keystroke, so the data-line index is built once per swap and then
 *     bisected, rather than queried out of the DOM per message;
 *   - the page still works with no server behind it.  `:SimpleMarkdownExternalStatic`
 *     writes this same page to disk, where there is no /events and no /cursor:
 *     it has to degrade to a plain readable document, not to a console full of
 *     failed connections.
 *
 * It is inlined into a plain <script> tag: no modules, no bundler, no
 * dependencies, and nothing global is touched but `window.SM` (read-only) and
 * the elements named in the page shell.  It deliberately does not render
 * Markdown, highlight code or lay anything out — that is the daemon's job, and
 * doing any of it here would mean two implementations to keep in agreement.
 */
(function () {
  'use strict';

  // ─────────────────────────── constants ───────────────────────────

  // How long the editor's cursor is ignored after the reader has scrolled by
  // hand.  Long enough to cover the tail of a flick, short enough that going
  // back to typing feels like the preview reattaches at once.
  const USER_SCROLL_QUIET_MS = 1200;
  // A scroll we performed ourselves must not be reported back to the editor
  // and must not count as the reader taking over.  This window only has to
  // cover the scroll events the browser emits for one instant jump.
  const OWN_SCROLL_MS = 250;
  // A smooth scroll animates for an unbounded time; this is the practical cap.
  const OWN_SMOOTH_SCROLL_MS = 900;
  // Trailing throttle on POST /cursor.  The editor needs to know where the
  // reader ended up, not every frame of them getting there.
  const CURSOR_THROTTLE_MS = 120;
  // Where a followed line is parked: a third of the way down, so that the
  // lines after it — the ones being typed — are the ones on screen.
  const FOLLOW_FRACTION = 1 / 3;
  // A heading counts as the one being read once it reaches the top third.
  const TOC_HERE_FRACTION = 1 / 3;
  // A rail for two headings is clutter, not navigation.
  const TOC_MIN_HEADINGS = 3;
  const FLASH_MS = 1200;
  const COPIED_MS = 1000;
  const RECONNECT_BASE_MS = 1000;
  const RECONNECT_CAP_MS = 30000;
  // After this many consecutive failures the daemon is not slow, it is gone.
  const RECONNECT_GIVE_UP = 8;
  // Namespaced, so that a preview cannot collide with whatever else the reader
  // has open on the same host and port.
  const STORE_PREFIX = 'simplemarkdown.preview.';

  const THEMES = ['auto', 'light', 'dark'];
  const THEME_GLYPH = { auto: '◐', light: '☀', dark: '☾' };
  const THEME_TITLE = {
    auto: 'Theme: follow the system',
    light: 'Theme: light',
    dark: 'Theme: dark'
  };
  const DOT_TITLE = {
    live: 'live',
    reconnecting: 'reconnecting…',
    dead: 'disconnected',
    stale: 'out of step with the editor — reload to catch up'
  };

  // ─────────────────────────── configuration ───────────────────────────

  // Every field is defaulted rather than read through.  The static page may
  // carry no window.SM at all, and a daemon older than this script may carry
  // fewer fields than it asks for; neither is a reason to stop.
  function readConfig() {
    const given = window.SM && typeof window.SM === 'object' ? window.SM : {};
    return {
      // -1 for a page that came from no server at all: it can hold no patch,
      // and there is nothing to tell a stream it already has.
      seq: Number.isInteger(given.seq) ? given.seq : -1,
      live: given.live === true,
      follow: given.follow === true,
      syncBack: given.syncBack === true,
      theme: THEMES.includes(given.theme) ? given.theme : 'auto',
      math: given.math === 'katex' || given.math === 'mathjax' ? given.math : 'off',
      toc: Array.isArray(given.toc) ? given.toc : [],
      name: typeof given.name === 'string' ? given.name : ''
    };
  }

  const SM = readConfig();

  const doc = document.getElementById('sm-doc');
  const main = document.getElementById('sm-main');
  const rail = document.getElementById('sm-toc');
  const tocList = document.getElementById('sm-toc-list');
  const tocBtn = document.getElementById('sm-toc-btn');
  const followBtn = document.getElementById('sm-follow');
  const themeBtn = document.getElementById('sm-theme');
  const dot = document.getElementById('sm-dot');

  // ─────────────────────────── stored preferences ───────────────────────────

  // localStorage is not merely empty in a private window — reading it throws
  // outright in some of them, and an uncaught throw here would take the rest of
  // the page's behaviour with it.
  function stored(key) {
    try {
      return window.localStorage.getItem(STORE_PREFIX + key);
    } catch (err) {
      return null;
    }
  }

  function remember(key, value) {
    try {
      window.localStorage.setItem(STORE_PREFIX + key, value);
    } catch (err) {
      // A reader who cannot store a preference still gets to use it this visit.
    }
  }

  // ─────────────────────────── the scrolling box ───────────────────────────

  // The stylesheet decides whether the page scrolls or a column inside it
  // does — a fixed contents rail beside a scrolling <main> is a reasonable
  // layout, and so is a plain document.  Everything below measures with
  // viewport rectangles, which are true either way; the only thing that has to
  // be decided is which box to move.  The answer is cached because it costs a
  // computed style and is wanted on every throttled scroll.
  let cachedHost = null;

  function scrollHost() {
    if (!cachedHost) {
      cachedHost = detectScrollHost();
    }
    return cachedHost;
  }

  function detectScrollHost() {
    if (main && main.scrollHeight > main.clientHeight + 1) {
      const overflow = window.getComputedStyle(main).overflowY;
      if (overflow === 'auto' || overflow === 'scroll') {
        return main;
      }
    }
    return document.scrollingElement || document.documentElement;
  }

  function forgetScrollHost() {
    cachedHost = null;
  }

  function isRootScroller(host) {
    return host === document.scrollingElement || host === document.documentElement;
  }

  // The viewport's top edge in client coordinates: zero for the page itself,
  // the element's own top when a column is doing the scrolling.
  function viewportTop(host) {
    return isRootScroller(host) ? 0 : host.getBoundingClientRect().top;
  }

  let programmaticUntil = 0;
  let lastUserScroll = 0;

  // A reader who has asked the system for less motion has asked for it here
  // too; an animated jump is exactly the kind of movement that setting is for.
  function animates(smooth) {
    if (!smooth || typeof window.matchMedia !== 'function') {
      return smooth;
    }
    return !window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  }

  function scrollHostBy(delta, wanted) {
    if (Math.abs(delta) < 1) {
      return;
    }
    const smooth = animates(wanted);
    const host = scrollHost();
    // The scroll events this is about to provoke are claimed as ours before
    // they happen, or the handler reads them as the reader taking over and
    // reports them back to the editor — which is how the two ends end up
    // chasing each other down the document.
    programmaticUntil = Date.now() + (smooth ? OWN_SMOOTH_SCROLL_MS : OWN_SCROLL_MS);
    // `instant`, not `auto`.  `auto` defers to the computed `scroll-behavior`,
    // and the stylesheet sets that to `smooth` on the root for everyone who has
    // not asked for reduced motion — so a scroll claimed for OWN_SCROLL_MS
    // would actually animate for longer, and the scroll events arriving after
    // the claim expired would be read as the reader taking over: follow-mode
    // going deaf right after each jump it made itself, and, with sync-back on,
    // the page telling the editor to move to where the editor had just sent it.
    host.scrollTo({ top: host.scrollTop + delta, behavior: smooth ? 'smooth' : 'instant' });
  }

  function scrollElementTo(el, fraction, smooth) {
    const host = scrollHost();
    const want = viewportTop(host) + host.clientHeight * fraction;
    scrollHostBy(el.getBoundingClientRect().top - want, smooth);
  }

  // ─────────────────────────── the data-line index ───────────────────────────

  // One entry per block that carries a source line, in document order.  Two
  // questions are asked of it — "which block is at the top of the screen" and
  // "which block holds line N" — and both are answered by bisection, because
  // they are asked on every keystroke of a document that may be thousands of
  // lines long.
  //
  // Both want the *last* entry satisfying a test that is true for a prefix of
  // the array and false after it, and both tests have that shape here: html.rs
  // walks the source in order, so `line` never decreases, and blocks in normal
  // flow never start above the block before them.  Nested ones — an <li>
  // inside its <ul> — start at or below their parent, which is exactly the
  // answer wanted when a long list spans the top of the screen.
  let blocks = [];

  function indexBlocks() {
    blocks = [];
    if (!doc) {
      return;
    }
    for (const el of doc.querySelectorAll('[data-line]')) {
      const line = Number.parseInt(el.getAttribute('data-line'), 10);
      if (line > 0) {
        blocks.push({ line, el });
      }
    }
  }

  function lastIndexWhere(test) {
    let low = 0;
    let high = blocks.length - 1;
    let best = -1;
    while (low <= high) {
      const middle = (low + high) >> 1;
      if (test(blocks[middle])) {
        best = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return best;
  }

  // The block the reader is looking at: the last one that starts at or above
  // the top edge.  Falling back to the first covers the space above the first
  // block, where nothing has started yet.
  function topmostBlock() {
    if (!blocks.length) {
      return null;
    }
    const edge = viewportTop(scrollHost()) + 1;
    const at = lastIndexWhere(function startsAbove(block) {
      return block.el.getBoundingClientRect().top <= edge;
    });
    return blocks[at < 0 ? 0 : at];
  }

  function elementForLine(line) {
    const at = lastIndexWhere(function beginsAtOrBefore(block) {
      return block.line <= line;
    });
    return at < 0 ? null : blocks[at].el;
  }

  // ─────────────────────────── keeping the reader's place ───────────────────

  // Taken before the swap, because afterwards the elements it describes are
  // gone: the source line of the topmost block, and how far its top sat from
  // the top of the viewport.  Those two numbers are the only thing about the
  // old DOM that survives a re-render of all of it.
  function recordAnchor() {
    const block = topmostBlock();
    if (!block) {
      return null;
    }
    return {
      line: block.line,
      offset: block.el.getBoundingClientRect().top - viewportTop(scrollHost())
    };
  }

  function restoreAnchor(anchor) {
    if (!anchor) {
      return;
    }
    const el = elementForLine(anchor.line);
    if (!el) {
      return;
    }
    const top = el.getBoundingClientRect().top - viewportTop(scrollHost());
    scrollHostBy(top - anchor.offset, false);
  }

  // ─────────────────────────── the flash ───────────────────────────

  let flashedEl = null;
  let flashTimer = 0;

  // Restarting the animation takes the class off, a layout read to make the
  // removal take effect, and the class back on.  The timer is the belt to
  // animationend's braces: a stylesheet that defines no animation would leave
  // the class on forever, and the flash after it would not show at all.
  function flash(el) {
    dropFlash();
    flashedEl = el;
    el.classList.remove('sm-flash');
    void el.offsetWidth;
    el.classList.add('sm-flash');
    flashTimer = window.setTimeout(dropFlash, FLASH_MS);
  }

  function dropFlash() {
    if (flashTimer) {
      window.clearTimeout(flashTimer);
      flashTimer = 0;
    }
    if (flashedEl) {
      flashedEl.classList.remove('sm-flash');
      flashedEl = null;
    }
  }

  // ─────────────────────────── following the editor ───────────────────────────

  let following = SM.follow;

  function setPressed(button, on) {
    if (!button) {
      return;
    }
    button.setAttribute('aria-pressed', on ? 'true' : 'false');
    button.dataset.state = on ? 'on' : 'off';
  }

  // Deliberately not remembered across loads, unlike the theme and the rail:
  // whether the preview chases the cursor is the plugin's setting, and a reader
  // who turned it off for one document should not find it off in every session
  // after this one.
  function setFollow(on) {
    following = on;
    setPressed(followBtn, following);
  }

  function onEditorLine(line) {
    if (!following || typeof line !== 'number' || !Number.isFinite(line)) {
      return;
    }
    // The wheel wins.  While the reader is moving about by hand, the editor's
    // cursor is not where they are looking, and scrolling to it would drag them
    // off the paragraph they are in the middle of.
    if (Date.now() - lastUserScroll < USER_SCROLL_QUIET_MS) {
      return;
    }
    const el = elementForLine(line);
    if (!el) {
      return;
    }
    // The editor has moved, so the last position reported to it no longer
    // describes where it is.  Without this, a reader who scrolls back to the
    // block they last reported would report nothing — the de-duplication would
    // swallow it — and the editor would sit where *it* had gone instead.
    lastSentLine = -1;
    scrollElementTo(el, FOLLOW_FRACTION, false);
    flash(el);
  }

  // ─────────────────────────── reporting back ───────────────────────────

  let cursorTimer = 0;
  let lastSentLine = -1;

  function onScroll() {
    if (Date.now() < programmaticUntil) {
      // Ours, not the reader's.  Reporting it would tell the editor to move its
      // cursor to where the editor has just told us to scroll.
      return;
    }
    lastUserScroll = Date.now();
    dropFlash();
    if (!SM.syncBack || !SM.live || cursorTimer) {
      return;
    }
    // Trailing edge: the editor wants to know where the reader stopped, and a
    // leading-edge throttle would send a request per frame of a long flick.
    cursorTimer = window.setTimeout(sendCursor, CURSOR_THROTTLE_MS);
  }

  function sendCursor() {
    cursorTimer = 0;
    const block = topmostBlock();
    if (!block || block.line === lastSentLine) {
      return;
    }
    lastSentLine = block.line;
    // keepalive, so that the last position still reaches the editor when the
    // reader closes the tab in the same breath as scrolling it.
    window
      .fetch('/cursor', {
        method: 'POST',
        keepalive: true,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ line: block.line })
      })
      .catch(function ignore() {
        // The daemon has gone.  The SSE connection is finding that out too, and
        // it is the one that says so; a rejected POST needs no second report.
      });
  }

  // ─────────────────────────── theme ───────────────────────────

  let theme = SM.theme;

  function applyTheme(name) {
    theme = THEMES.includes(name) ? name : 'auto';
    document.documentElement.setAttribute('data-theme', theme);
    if (!themeBtn) {
      return;
    }
    themeBtn.dataset.state = theme;
    themeBtn.title = THEME_TITLE[theme];
    themeBtn.setAttribute('aria-label', THEME_TITLE[theme]);
    // The glyph is only written when the button holds text.  Where the page
    // shell put an <svg> in there instead, the stylesheet switches icons on
    // [data-state] and overwriting the markup would throw the icons away.
    if (!themeBtn.firstElementChild) {
      themeBtn.textContent = THEME_GLYPH[theme];
    }
  }

  function cycleTheme() {
    const next = THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length];
    applyTheme(next);
    remember('theme', next);
  }

  // ─────────────────────────── the contents rail ───────────────────────────

  let tocEntries = SM.toc;
  let tocOpen = stored('toc') === 'open';
  let tocLinks = new Map();
  let headings = [];
  let headingObserver = null;
  let hereLink = null;

  function buildToc(entries) {
    tocEntries = Array.isArray(entries) ? entries : [];
    const enough = tocEntries.length >= TOC_MIN_HEADINGS;
    if (tocBtn) {
      tocBtn.hidden = !enough;
    }
    tocLinks = new Map();
    headings = [];
    hereLink = null;
    if (tocList) {
      tocList.replaceChildren(tocFragment(headingIndex()));
    }
    setTocOpen(tocOpen && enough);
    observeHeadings();
  }

  // Every heading in the fresh document, by id, gathered in one pass.  A
  // querySelector per table-of-contents entry would be a hundred tree walks per
  // keystroke on a document with a hundred headings.
  function headingIndex() {
    const byId = new Map();
    if (!doc) {
      return byId;
    }
    for (const heading of doc.querySelectorAll('h1[id], h2[id], h3[id], h4[id], h5[id], h6[id]')) {
      byId.set(heading.id, heading);
    }
    return byId;
  }

  function tocFragment(byId) {
    const fragment = document.createDocumentFragment();
    for (const entry of tocEntries) {
      if (!entry || typeof entry.anchor !== 'string') {
        continue;
      }
      const link = document.createElement('a');
      const level = typeof entry.level === 'number' ? entry.level : 1;
      link.className = 'sm-toc-link';
      link.href = '#' + entry.anchor;
      link.textContent = typeof entry.text === 'string' ? entry.text : entry.anchor;
      link.dataset.level = String(level);
      link.dataset.anchor = entry.anchor;
      // A custom property as well as the attribute, so that the stylesheet can
      // indent by arithmetic rather than by six selectors.
      link.style.setProperty('--sm-toc-depth', String(Math.max(0, level - 1)));
      fragment.appendChild(link);
      tocLinks.set(entry.anchor, link);
      const heading = byId.get(entry.anchor);
      if (heading) {
        headings.push(heading);
      }
    }
    return fragment;
  }

  function setTocOpen(open) {
    tocOpen = open && tocEntries.length >= TOC_MIN_HEADINGS;
    if (rail) {
      rail.hidden = !tocOpen;
    }
    document.body.classList.toggle('sm-toc-open', tocOpen);
    setPressed(tocBtn, tocOpen);
    // Opening the rail can move the scrollbar from the page to the column.
    forgetScrollHost();
  }

  function toggleToc() {
    setTocOpen(!tocOpen);
    remember('toc', tocOpen ? 'open' : 'closed');
  }

  function onTocClick(event) {
    const link = closestFrom(event.target, '.sm-toc-link');
    if (!link || !doc) {
      return;
    }
    const heading = doc.querySelector('#' + cssEscape(link.dataset.anchor || ''));
    if (!heading) {
      return;
    }
    // Handled here rather than left to the browser: the default jump is instant
    // and writes a history entry per heading, so a reader who clicked their way
    // down the rail then needs a dozen presses of Back to leave the page.
    event.preventDefault();
    scrollElementTo(heading, 0.06, true);
    markHere(heading);
  }

  // Anchors are slugs, but a heading made entirely of punctuation can still
  // slug to something a selector would choke on.
  function cssEscape(value) {
    if (window.CSS && typeof window.CSS.escape === 'function') {
      return window.CSS.escape(value);
    }
    return value.replace(/[^\w-]/g, '\\$&');
  }

  // An observer rather than a scroll handler: the question is "which section am
  // I in", which only changes when a heading crosses a line, while a scroll
  // handler would ask it sixty times a second to get the same answer.  The
  // callback recomputes from rectangles rather than from the entries, because
  // the heading that just crossed is not necessarily the one now current.
  function observeHeadings() {
    if (headingObserver) {
      headingObserver.disconnect();
      headingObserver = null;
    }
    if (!headings.length || typeof window.IntersectionObserver !== 'function') {
      return;
    }
    const host = scrollHost();
    headingObserver = new window.IntersectionObserver(
      function onCross() {
        markHere(currentHeading());
      },
      {
        root: isRootScroller(host) ? null : host,
        rootMargin: '0px 0px -66% 0px',
        threshold: 0
      }
    );
    for (const heading of headings) {
      headingObserver.observe(heading);
    }
    markHere(currentHeading());
  }

  function currentHeading() {
    if (!headings.length) {
      return null;
    }
    const host = scrollHost();
    const edge = viewportTop(host) + host.clientHeight * TOC_HERE_FRACTION;
    let found = headings[0];
    for (const heading of headings) {
      if (heading.getBoundingClientRect().top > edge) {
        break;
      }
      found = heading;
    }
    return found;
  }

  function markHere(heading) {
    const link = heading ? tocLinks.get(heading.id) : null;
    if (link === hereLink) {
      return;
    }
    if (hereLink) {
      hereLink.classList.remove('sm-toc-here');
    }
    hereLink = link || null;
    if (hereLink) {
      hereLink.classList.add('sm-toc-here');
    }
  }

  // ─────────────────────────── copy buttons ───────────────────────────

  const copyState = new WeakMap();

  // One delegated listener rather than a wiring pass after every swap: the
  // buttons are replaced wholesale with each document, and listeners bound to
  // them would have to be bound again every time.
  function onDocClick(event) {
    const button = closestFrom(event.target, '.sm-copy');
    if (!button) {
      return;
    }
    const figure = button.closest('.sm-code');
    const code = figure ? figure.querySelector('code') : null;
    if (!code) {
      return;
    }
    copyText(code.textContent).then(function report(ok) {
      showCopied(button, ok);
    });
  }

  function copyText(text) {
    // navigator.clipboard exists only in a secure context — https anywhere, or
    // http on loopback.  This preview is regularly opened from another machine
    // against a wildcard bind, which is plain http on a routable address, and
    // there the API is not refused but simply absent.  execCommand('copy') is
    // deprecated and is still the only thing that works in that case.
    if (window.isSecureContext && navigator.clipboard) {
      return navigator.clipboard.writeText(text).then(
        function done() {
          return true;
        },
        function fallback() {
          return legacyCopy(text);
        }
      );
    }
    return Promise.resolve(legacyCopy(text));
  }

  function legacyCopy(text) {
    const scratch = document.createElement('textarea');
    scratch.value = text;
    scratch.setAttribute('readonly', '');
    // Off-screen rather than hidden: a display:none element cannot be selected,
    // and an unselected one cannot be copied.
    scratch.style.position = 'fixed';
    scratch.style.top = '-1000px';
    scratch.style.opacity = '0';
    document.body.appendChild(scratch);
    let ok = false;
    try {
      scratch.select();
      ok = document.execCommand('copy');
    } catch (err) {
      ok = false;
    }
    document.body.removeChild(scratch);
    return ok;
  }

  function showCopied(button, ok) {
    const state = copyState.get(button) || { label: button.textContent, timer: 0 };
    window.clearTimeout(state.timer);
    button.textContent = ok ? 'Copied' : 'Failed';
    // The attribute, not a class: the stylesheet reveals the button on hover
    // and keys the confirmation off `[data-copied]`, so a class here would let
    // "Copied" fade out under the pointer the moment it moved away.
    button.dataset.copied = ok ? 'yes' : 'no';
    state.timer = window.setTimeout(function restore() {
      button.textContent = state.label;
      delete button.dataset.copied;
    }, COPIED_MS);
    copyState.set(button, state);
  }

  // ─────────────────────────── math ───────────────────────────

  // Both engines are loaded with `defer`, which means they run *after* this
  // inline script — and may never arrive at all, on a machine with no network
  // or with the CDN blocked.  So the global is looked for every time, and its
  // absence is not an error: the raw `$…$` the daemon emitted is still a
  // perfectly readable formula.
  function typesetMath(afterSettled) {
    if (!doc || SM.math === 'off') {
      return;
    }
    try {
      if (SM.math === 'katex' && window.katex) {
        renderKatex();
      } else if (SM.math === 'mathjax' && window.MathJax && window.MathJax.typesetPromise) {
        window.MathJax.typesetPromise([doc]).then(afterSettled || noop, noop);
      }
    } catch (err) {
      // A document is worth more than its formulae: a math engine that throws
      // must not cost the reader the swap it was called from.
    }
  }

  function renderKatex() {
    for (const el of doc.querySelectorAll('.sm-math')) {
      const tex = el.dataset.tex;
      if (typeof tex !== 'string') {
        continue;
      }
      try {
        window.katex.render(tex, el, {
          displayMode: el.classList.contains('sm-math-display'),
          throwOnError: false
        });
      } catch (err) {
        // One bad formula, one formula left as source; the page still typesets.
      }
    }
  }

  function noop() {}

  // ─────────────────────────── the live connection ───────────────────────────

  let source = null;
  let failures = 0;
  let retryTimer = 0;
  let farewelled = false;

  function setDot(state) {
    if (!dot) {
      return;
    }
    dot.classList.toggle('sm-reconnecting', state === 'reconnecting');
    dot.classList.toggle('sm-dead', state === 'dead');
    dot.classList.toggle('sm-stale', state === 'stale');
    dot.dataset.state = state;
    dot.title = DOT_TITLE[state];
  }

  function connect() {
    if (farewelled || !SM.live || source || typeof window.EventSource !== 'function') {
      return;
    }
    window.clearTimeout(retryTimer);
    retryTimer = 0;
    try {
      // Says which document this page is holding, so the stream does not open
      // by sending back the one it was just served in the page it is running
      // from — a quarter of a megabyte, on a long document, for nothing.
      source = new window.EventSource('/events?have=' + encodeURIComponent(seq));
    } catch (err) {
      // A page opened from disk has no origin to ask, and no amount of retrying
      // will give it one.
      SM.live = false;
      setDot('dead');
      return;
    }
    source.addEventListener('open', onOpen);
    source.addEventListener('message', onMessage);
    source.addEventListener('error', onError);
  }

  function onOpen() {
    failures = 0;
    setDot('live');
  }

  // EventSource reconnects on its own, but always with the same patience and
  // forever: a daemon that has exited looks to it exactly like one that is
  // briefly busy, and the tab would go on knocking at a closed door for the
  // rest of the day.  Closing it here takes the retry over, which is what makes
  // it possible to back off and, eventually, to admit the preview is dead.
  function onError() {
    if (source) {
      source.close();
      source = null;
    }
    if (farewelled) {
      return;
    }
    failures += 1;
    if (failures >= RECONNECT_GIVE_UP) {
      setDot('dead');
      return;
    }
    setDot('reconnecting');
    const wait = Math.min(RECONNECT_BASE_MS * 2 ** (failures - 1), RECONNECT_CAP_MS);
    retryTimer = window.setTimeout(connect, wait);
  }

  function onMessage(event) {
    let message = null;
    try {
      message = JSON.parse(event.data);
    } catch (err) {
      // A frame that is not JSON is a bug on the other side of the socket.
      // Logging it once per keystroke would only bury the one that matters.
      return;
    }
    if (!message || typeof message !== 'object') {
      return;
    }
    if (message.k === 'doc') {
      applyDoc(message);
    } else if (message.k === 'patch') {
      applyPatch(message);
    } else if (message.k === 'line') {
      onEditorLine(message.line);
    } else if (message.k === 'bye') {
      onBye();
    }
  }

  function onBye() {
    farewelled = true;
    if (source) {
      source.close();
      source = null;
    }
    window.clearTimeout(retryTimer);
    retryTimer = 0;
    setDot('dead');
    // Nothing is listening on that port for this document any more, and the
    // next thing to bind it will not be this preview.  Reporting scroll
    // positions to it would be telling a stranger where to put somebody's
    // cursor.
    SM.syncBack = false;
  }

  // Which document this page is holding, and whether it may be spliced into.
  // A patch names the sequence it applies to; one that names any other is a
  // frame this page has missed, and splicing it in would edit the wrong
  // paragraph rather than fail.  Patching stops until the next whole document,
  // which the daemon sends periodically for exactly this reason.
  // Seeded from the shell: the page was rendered from a document the daemon
  // knows the number of, and its markup is that document — so it starts able to
  // take a patch, and tells the stream not to send it what it is looking at.
  let seq = typeof SM.seq === 'number' ? SM.seq : -1;
  let patchable = seq >= 0;

  function applyDoc(message) {
    if (!doc || typeof message.html !== 'string') {
      return;
    }
    const anchor = recordAnchor();
    dropFlash();
    doc.innerHTML = message.html;
    seq = typeof message.seq === 'number' ? message.seq : -1;
    // The daemon splices by child index and cannot see what the browser built
    // out of the HTML it sent.  This is the one check that catches a document
    // whose blocks did not come out one element each — and it is a comparison,
    // not a guess.
    patchable = seq >= 0 && doc.children.length === message.blocks;
    finishSwap(message.title, message.toc, anchor);
  }

  function applyPatch(message) {
    if (!doc || typeof message.html !== 'string') {
      return;
    }
    if (!patchable || message.base !== seq) {
      resync();
      return;
    }
    const from = message.from;
    const del = message.del;
    if (!Number.isInteger(from) || !Number.isInteger(del) || from < 0 || del < 0
        || from + del > doc.children.length) {
      resync();
      return;
    }

    const anchor = recordAnchor();
    dropFlash();

    // Before the splice, and indexed against the children as they stand: every
    // block below an inserted line kept its markup and moved its source line,
    // which is exactly what the diff refused to call a change — so the
    // correction arrives as one integer rather than as the document.  The
    // blocks the splice is about to insert already carry the right lines, and
    // shifting them too would move them twice.
    if (message.shift) {
      shiftLines(message.shift.from, message.shift.delta);
    }

    // Parsed in a template so the fragment is built once, off the document,
    // and the page lays out once when it is put in — rather than once per
    // element as they are appended.
    const template = document.createElement('template');
    template.innerHTML = message.html;
    const before = doc.children[from + del] || null;
    for (let i = 0; i < del; i += 1) {
      const going = doc.children[from];
      // The newline the daemon writes after each block is a text node no child
      // index can see.  It belongs to the block, and left behind it would
      // accumulate one stray node per replacement for the life of the tab.
      let trailing = going.nextSibling;
      going.remove();
      while (trailing && trailing.nodeType === Node.TEXT_NODE && !trailing.nodeValue.trim()) {
        const next = trailing.nextSibling;
        trailing.remove();
        trailing = next;
      }
    }
    doc.insertBefore(template.content, before);

    seq = message.seq;
    patchable = doc.children.length === message.blocks;
    // Absent means unchanged, which on a keystroke inside a paragraph is the
    // ordinary case: neither the tab's name nor the rail has moved.
    finishSwap(message.title, message.toc, anchor);
  }

  // A patch that cannot be applied means this page is holding a document the
  // daemon does not think it is holding.  There is no channel to ask for a
  // fresh one — the stream only goes one way — so the page fetches it the way
  // it fetched the first: by loading itself again.  Guarded by the clock, in
  // session storage so it survives the reload, because a page that reloaded
  // itself in a loop would be worse than one showing a stale document.
  const RESYNC_KEY = 'simplemarkdown:resync';
  const RESYNC_QUIET_MS = 30000;

  function resync() {
    patchable = false;
    let last = 0;
    try {
      last = Number(window.sessionStorage.getItem(RESYNC_KEY)) || 0;
    } catch (err) {
      // Storage is unavailable in some privacy modes.  Without it the guard
      // cannot be trusted, so the reload is not taken at all.
      setDot('stale');
      return;
    }
    if (Date.now() - last < RESYNC_QUIET_MS) {
      // Already tried recently: stay put and show it, rather than spin.  The
      // next edit large enough to be sent whole repairs the page anyway.
      setDot('stale');
      return;
    }
    try {
      window.sessionStorage.setItem(RESYNC_KEY, String(Date.now()));
    } catch (err) {
      setDot('stale');
      return;
    }
    window.location.reload();
  }

  function shiftLines(from, delta) {
    if (!Number.isInteger(from) || !Number.isInteger(delta) || delta === 0) {
      return;
    }
    const children = doc.children;
    for (let i = Math.max(0, from); i < children.length; i += 1) {
      shiftElement(children[i], delta);
      // Descendants too.  A paragraph inside a quote, an item inside a list and
      // a row inside a table all carry their own source line, and the index the
      // scroll sync bisects is built from every `[data-line]` in the document,
      // not from the top-level children alone — so shifting only the blocks
      // would leave the finer anchors pointing where the text used to be.
      for (const nested of children[i].querySelectorAll('[data-line]')) {
        shiftElement(nested, delta);
      }
    }
  }

  function shiftElement(el, delta) {
    const had = Number(el.dataset.line);
    // An element that came from no particular source line — the footnote
    // section — stays where it is, exactly as an unmapped row does.
    if (had > 0) {
      el.dataset.line = String(had + delta);
    }
  }

  function finishSwap(rawTitle, toc, anchor) {
    const title = typeof rawTitle === 'string' && rawTitle ? rawTitle : SM.name;
    if (typeof rawTitle === 'string' && title) {
      document.title = title;
    }
    indexBlocks();
    if (toc) {
      buildToc(toc);
    }
    // MathJax typesets asynchronously, and the height of everything below each
    // formula changes as they land.  So the place is put back twice: once now,
    // for the document as it stands, and once more when the engine has settled.
    typesetMath(function settled() {
      restoreAnchor(anchor);
    });
    restoreAnchor(anchor);
  }

  // ─────────────────────────── keyboard ───────────────────────────

  function typing(target) {
    if (!target || target.isContentEditable) {
      return true;
    }
    const tag = (target.tagName || '').toLowerCase();
    return tag === 'input' || tag === 'textarea' || tag === 'select';
  }

  function onKeyDown(event) {
    // Anything with a modifier belongs to the browser or the window manager.
    if (event.ctrlKey || event.metaKey || event.altKey || typing(event.target)) {
      return;
    }
    if (event.key === 't') {
      toggleToc();
    } else if (event.key === 'f') {
      setFollow(!following);
    } else if (event.key === 'd') {
      cycleTheme();
    } else {
      return;
    }
    event.preventDefault();
  }

  // ─────────────────────────── wiring ───────────────────────────

  function closestFrom(target, selector) {
    return target && typeof target.closest === 'function' ? target.closest(selector) : null;
  }

  // The reader chose their theme after the plugin's setting was written, so
  // theirs is the one that stands.
  const chosen = stored('theme');
  applyTheme(THEMES.includes(chosen) ? chosen : SM.theme);
  setFollow(SM.follow);

  if (SM.live) {
    setDot('live');
  } else {
    // A page saved to disk: nothing will push to it and nothing is listening,
    // so a status dot and a follow button would both be telling lies.
    document.body.classList.add('sm-static');
    if (dot) {
      dot.hidden = true;
    }
    if (followBtn) {
      followBtn.hidden = true;
    }
  }

  indexBlocks();
  buildToc(SM.toc);

  if (doc) {
    doc.addEventListener('click', onDocClick);
  }
  if (tocList) {
    tocList.addEventListener('click', onTocClick);
  }
  if (tocBtn) {
    tocBtn.addEventListener('click', toggleToc);
  }
  if (followBtn) {
    followBtn.addEventListener('click', function toggleFollow() {
      setFollow(!following);
    });
  }
  if (themeBtn) {
    themeBtn.addEventListener('click', cycleTheme);
  }

  window.addEventListener('scroll', onScroll, { passive: true });
  if (main) {
    // Scroll events do not bubble, so the column has to be listened to in its
    // own right for the layouts where it, and not the page, is what moves.
    main.addEventListener('scroll', onScroll, { passive: true });
  }
  window.addEventListener('resize', forgetScrollHost);
  window.addEventListener('keydown', onKeyDown);

  document.addEventListener('visibilitychange', function onVisible() {
    if (document.visibilityState !== 'visible' || farewelled || source) {
      return;
    }
    // A reader coming back to the tab is the one moment worth spending another
    // connection on, however long the backoff had grown and however many
    // failures ago we had given up.
    failures = 0;
    connect();
  });

  // The math engines are deferred, so at this point in the parse they do not
  // exist yet and the first typeset has to wait for the load event that follows
  // them.  Trying now as well costs nothing and covers an already-running
  // engine on a hard reload.
  typesetMath(null);
  window.addEventListener('load', function typesetOnce() {
    typesetMath(null);
  });

  connect();
})();
