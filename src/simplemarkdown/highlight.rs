//! Fenced-code-block syntax highlighting.
//!
//! syntect is used for parsing only, never for colouring.  It hands back a
//! TextMate scope stack per token (`keyword.control.rust`, `string.quoted.
//! double.rust`, …) and this module collapses that into the handful of coarse
//! classes in [`crate::classes`], which the Vim side links to whatever the
//! user's colour scheme already defines.  Shipping syntect's own themes would
//! mean emitting RGB, which looks wrong against every terminal palette that is
//! not the one the theme was authored for.

use crate::classes;
use std::collections::{HashMap, VecDeque};
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex, OnceLock};
use syntect::easy::ScopeRegionIterator;
use syntect::parsing::{ParseState, Scope, ScopeStack, SyntaxReference, SyntaxSet};

/// One highlighted line: `(byte_offset, byte_len, class)`, offsets 0-based and
/// relative to the line.
pub type Spans = Vec<(usize, usize, &'static str)>;

/// Loading the syntax dump costs tens of milliseconds and a few megabytes, and
/// a document with no fenced code blocks should pay neither.
static SYNTAXES: OnceLock<SyntaxSet> = OnceLock::new();

fn syntaxes() -> &'static SyntaxSet {
    SYNTAXES.get_or_init(SyntaxSet::load_defaults_newlines)
}

/// Info-string aliases syntect's own token lookup does not know about.  Only
/// aliases that map onto a bundled syntax are worth listing; `toml` and `vim`
/// have no default definition at all, so they fall through to plain text.
const ALIASES: &[(&str, &str)] = &[
    ("bash", "sh"),
    ("zsh", "sh"),
    ("shell", "sh"),
    ("console", "sh"),
    ("sh-session", "sh"),
    ("js", "javascript"),
    ("jsx", "javascript"),
    ("mjs", "javascript"),
    ("cjs", "javascript"),
    ("node", "javascript"),
    ("ts", "javascript"),
    ("tsx", "javascript"),
    ("typescript", "javascript"),
    ("py", "python"),
    ("python3", "python"),
    ("rs", "rust"),
    ("golang", "go"),
    ("c++", "cpp"),
    ("cc", "cpp"),
    ("hpp", "cpp"),
    ("h", "c"),
    ("cs", "c#"),
    ("csharp", "c#"),
    ("kt", "java"),
    ("kotlin", "java"),
    ("rb", "ruby"),
    ("yml", "yaml"),
    ("md", "markdown"),
    ("htm", "html"),
    ("psql", "sql"),
    ("mysql", "sql"),
    ("sqlite", "sql"),
    ("patch", "diff"),
    ("plaintext", "text"),
    ("txt", "text"),
];

/// A prepared highlighter for one language, or a no-op for an unknown one.
pub struct Highlighter {
    inner: Option<Inner>,
}

struct Inner {
    state: ParseState,
    stack: ScopeStack,
}

impl Highlighter {
    /// `info` is the fence's info string (`rust`, `js{.line-numbers}`, `console`
    /// …); only the first word matters.  An unrecognised language yields a
    /// highlighter that returns no properties, which is the right outcome —
    /// the code is still shown, just uncoloured.
    pub fn new(info: &str) -> Self {
        let token = language_token(info);
        if token.is_empty() {
            return Self { inner: None };
        }
        let set = syntaxes();
        match find_syntax(set, &token) {
            Some(syntax) => Self {
                inner: Some(Inner {
                    state: ParseState::new(syntax),
                    stack: ScopeStack::new(),
                }),
            },
            None => Self { inner: None },
        }
    }

    /// True when the language was recognised.  Callers use it to skip the
    /// per-line work entirely.
    pub fn active(&self) -> bool {
        self.inner.is_some()
    }

    /// Highlight one source line.  `line` must not contain a newline; syntect
    /// wants one, and several syntaxes rely on it to close line-scoped
    /// contexts, so it is appended internally.
    ///
    /// Returns spans as `(byte_offset, byte_len, class)` relative to `line`.
    /// Offsets are 0-based here; the caller shifts them into the box.
    pub fn line(&mut self, line: &str) -> Spans {
        let Some(inner) = self.inner.as_mut() else {
            return Vec::new();
        };
        let mut owned = String::with_capacity(line.len() + 1);
        owned.push_str(line);
        owned.push('\n');

        let ops = match inner.state.parse_line(&owned, syntaxes()) {
            Ok(ops) => ops,
            // A syntax whose regex engine gives up (fancy-regex backtrack
            // limits on a pathological line) must not poison the rest of the
            // block: drop this line's colouring and carry on.
            Err(_) => return Vec::new(),
        };

        let mut spans: Vec<(usize, usize, &'static str)> = Vec::new();
        let mut offset = 0usize;
        for (text, op) in ScopeRegionIterator::new(&ops, &owned) {
            if inner.stack.apply(op).is_err() {
                return spans;
            }
            if text.is_empty() {
                continue;
            }
            let len = text.len();
            // The synthetic newline is not part of the caller's line.
            let visible = len.min(line.len().saturating_sub(offset));
            if visible > 0
                && let Some(class) = classify(&inner.stack)
                && !text[..visible].trim().is_empty()
            {
                merge(&mut spans, offset, visible, class);
            }
            offset += len;
        }
        spans
    }
}

// ─────────────────────────── the block cache ───────────────────────────
//
// The preview re-renders the whole document on every keystroke burst, and
// syntect is by far the most expensive thing in that render.  But the code
// blocks are almost never what changed: editing a paragraph re-highlights
// every fence in the file for nothing.  Memoising a whole block on its exact
// content turns those back into a lookup.
//
// Entries hold the source they were computed from and it is compared on every
// hit, so a hash collision costs a miss rather than the wrong colours.

/// How much of the cache's own weight is kept, in bytes of source plus spans.
///
/// A budget, not a count, and evicted in the order entries arrived rather than
/// by recency.  This used to be 128 entries with move-to-front on a hit, which
/// is LRU — and a render walks a document's fences top to bottom exactly once,
/// which is the access pattern LRU is pessimal for: past capacity, every lookup
/// wants the entry the block after it has just evicted, so the hit rate is not
/// degraded but zero.  Measured on generated fixtures, steady-state render:
/// 128 fences 0.45 ms, 129 fences 11.12 ms, 400 fences 35.44 ms.  A budget
/// large enough to hold a whole document never evicts during a render, and a
/// document too large for it degrades to partial hits instead of none.
const CACHE_BUDGET: usize = 12 * 1024 * 1024;

/// Past this a block is highlighted afresh each time rather than kept.  A
/// megabyte of generated JSON pasted into a fence would otherwise be most of
/// the budget on its own.
const CACHE_MAX_BYTES: usize = 256 * 1024;

struct Entry {
    token: String,
    code: String,
    spans: Arc<Vec<Spans>>,
}

impl Entry {
    /// What this entry costs the budget.  The spans dominate a dense block and
    /// the source dominates a sparse one, so both are counted.
    fn weight(&self) -> usize {
        let spans: usize = self.spans.iter().map(|line| line.len() * 24).sum();
        self.token.len() + self.code.len() + spans + 64
    }
}

#[derive(Default)]
struct Cache {
    entries: HashMap<u64, Entry>,
    /// Fingerprints in the order they arrived, for eviction.  Never reordered
    /// on a hit: reordering is what made the scan pathological.
    arrived: VecDeque<u64>,
    bytes: usize,
}

fn cache() -> &'static Mutex<Cache> {
    static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(Cache::default()))
}

/// Highlight a whole fenced block, one entry per line, memoised on its content.
///
/// `lines` are the block exactly as the caller will lay it out, so a caller
/// that expands tabs and a caller that does not key the same block separately.
/// That is two entries where there could be one, and it is the honest cost of
/// letting the terminal renderer expand tabs — it must, a cell is a cell — and
/// the browser renderer leave them to the stylesheet.  With a budget rather
/// than a count, the duplication costs memory and not hits.
pub fn block(info: &str, lines: &[String]) -> Arc<Vec<Spans>> {
    let token = language_token(info);
    if token.is_empty() {
        return Arc::new(Vec::new());
    }
    let code = lines.join("\n");
    let hash = fingerprint(&token, &code);
    let cacheable = code.len() <= CACHE_MAX_BYTES;

    if cacheable
        && let Ok(cache) = cache().lock()
        && let Some(entry) = cache.entries.get(&hash)
        // Compared rather than trusted: a collision costs a miss, never the
        // wrong colours.
        && entry.token == token
        && entry.code == code
    {
        return entry.spans.clone();
    }

    let mut highlighter = Highlighter::new(&token);
    let spans: Arc<Vec<Spans>> = Arc::new(if highlighter.active() {
        lines.iter().map(|line| highlighter.line(line)).collect()
    } else {
        Vec::new()
    });

    if cacheable && let Ok(mut cache) = cache().lock() {
        let entry = Entry {
            token,
            code,
            spans: spans.clone(),
        };
        let weight = entry.weight();
        if let Some(replaced) = cache.entries.insert(hash, entry) {
            cache.bytes = cache.bytes.saturating_sub(replaced.weight());
        } else {
            cache.arrived.push_back(hash);
        }
        cache.bytes += weight;
        while cache.bytes > CACHE_BUDGET {
            let Some(oldest) = cache.arrived.pop_front() else {
                break;
            };
            // Not the one just inserted: a document larger than the whole
            // budget should still hit on the run of blocks it is walking.
            if oldest == hash {
                cache.arrived.push_back(oldest);
                break;
            }
            if let Some(gone) = cache.entries.remove(&oldest) {
                cache.bytes = cache.bytes.saturating_sub(gone.weight());
            }
        }
    }
    spans
}

/// The first word of a fence's info string, lowercased: `rust`, `js`, `sh`.
fn language_token(info: &str) -> String {
    info.split(|c: char| c.is_whitespace() || c == ',' || c == '{')
        .find(|part| !part.is_empty())
        .unwrap_or("")
        .trim_start_matches('.')
        .to_ascii_lowercase()
}

fn fingerprint(token: &str, code: &str) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    token.hash(&mut hasher);
    code.hash(&mut hasher);
    hasher.finish()
}

fn find_syntax<'a>(set: &'a SyntaxSet, token: &str) -> Option<&'a SyntaxReference> {
    let resolved = ALIASES
        .iter()
        .find(|(from, _)| *from == token)
        .map(|(_, to)| *to)
        .unwrap_or(token);
    set.find_syntax_by_token(resolved)
        .or_else(|| set.find_syntax_by_extension(resolved))
        .or_else(|| {
            set.syntaxes()
                .iter()
                .find(|syntax| syntax.name.eq_ignore_ascii_case(resolved))
        })
}

/// Adjacent spans of the same class are extremely common (one per punctuation
/// character in some grammars); collapsing them here keeps both the JSON and
/// the number of `prop_add()` calls down.
fn merge(
    spans: &mut Vec<(usize, usize, &'static str)>,
    offset: usize,
    len: usize,
    class: &'static str,
) {
    if let Some(last) = spans.last_mut()
        && last.2 == class
        && last.0 + last.1 == offset
    {
        last.1 += len;
        return;
    }
    spans.push((offset, len, class));
}

/// Walk the scope stack from the top down and take the first scope that maps
/// to a class.  Top-down matters: in `punctuation.definition.string` nested
/// inside `string.quoted.double`, the punctuation is the more specific answer,
/// and both land on the same class anyway.
fn classify(stack: &ScopeStack) -> Option<&'static str> {
    stack.scopes.iter().rev().copied().find_map(scope_class_of)
}

/// The hot path: called once per scope per token per line, so it must not
/// allocate.  syntect scopes are interned into a packed 128-bit atom vector,
/// and `is_prefix_of` compares them with two masked XORs — whereas
/// `Scope::build_string()` takes a global mutex and builds a String, and
/// prefix-matching that String needed a `format!` per candidate.  On a
/// code-heavy document that was tens of allocations and one lock acquisition
/// per token, and it dominated the render.
fn scope_class_of(scope: Scope) -> Option<&'static str> {
    let mut best: Option<(u32, &'static str)> = None;
    for (prefix, class) in prefixes() {
        if prefix.is_prefix_of(scope) {
            let len = prefix.len();
            if best.is_none_or(|(seen, _)| len > seen) {
                best = Some((len, class));
            }
        }
    }
    best.map(|(_, class)| class)
}

/// [`MAP`] with every prefix interned once.  Interning is what makes the
/// comparison above a bitwise operation instead of a string one.
fn prefixes() -> &'static [(Scope, &'static str)] {
    static PREFIXES: OnceLock<Vec<(Scope, &'static str)>> = OnceLock::new();
    PREFIXES.get_or_init(|| {
        MAP.iter()
            // A prefix that will not parse can only be a typo in MAP; dropping
            // it costs that one class its colour rather than the whole block.
            .filter_map(|(prefix, class)| Some((Scope::new(prefix).ok()?, *class)))
            .collect()
    })
}

/// Longest-prefix-first: `constant.numeric` must win over `constant`, and
/// `entity.name.tag` over `entity.name`.
const MAP: &[(&str, &str)] = &[
    ("comment", classes::SYN_COMMENT),
    ("punctuation.definition.comment", classes::SYN_COMMENT),
    ("string.regexp", classes::SYN_STRING),
    ("string", classes::SYN_STRING),
    ("punctuation.definition.string", classes::SYN_STRING),
    ("constant.character.escape", classes::SYN_ESCAPE),
    ("constant.numeric", classes::SYN_NUMBER),
    ("constant.language", classes::SYN_BOOLEAN),
    ("constant", classes::SYN_CONSTANT),
    ("keyword.operator", classes::SYN_OPERATOR),
    ("keyword", classes::SYN_KEYWORD),
    ("storage.type.function", classes::SYN_KEYWORD),
    ("storage.modifier", classes::SYN_KEYWORD),
    ("storage", classes::SYN_TYPE),
    ("entity.name.function", classes::SYN_FUNCTION),
    ("entity.name.macro", classes::SYN_PREPROC),
    ("entity.name.tag", classes::SYN_TAG),
    ("entity.name.type", classes::SYN_TYPE),
    ("entity.name.class", classes::SYN_TYPE),
    ("entity.name.struct", classes::SYN_TYPE),
    ("entity.name.namespace", classes::SYN_PREPROC),
    ("entity.name", classes::SYN_FUNCTION),
    ("entity.other.attribute-name", classes::SYN_PROPERTY),
    ("entity.other.inherited-class", classes::SYN_TYPE),
    ("support.function", classes::SYN_FUNCTION),
    ("support.macro", classes::SYN_PREPROC),
    ("support.type", classes::SYN_TYPE),
    ("support.class", classes::SYN_TYPE),
    ("support.constant", classes::SYN_CONSTANT),
    ("support.module", classes::SYN_PREPROC),
    ("variable.parameter", classes::SYN_VARIABLE),
    ("variable.function", classes::SYN_FUNCTION),
    ("variable.language", classes::SYN_CONSTANT),
    ("variable.other.member", classes::SYN_PROPERTY),
    ("variable.annotation", classes::SYN_PROPERTY),
    ("variable", classes::SYN_VARIABLE),
    ("meta.preprocessor", classes::SYN_PREPROC),
    ("meta.annotation", classes::SYN_PREPROC),
    ("punctuation.section", classes::SYN_PUNCT),
    ("punctuation.separator", classes::SYN_PUNCT),
    ("punctuation.terminator", classes::SYN_PUNCT),
    ("punctuation.accessor", classes::SYN_OPERATOR),
    ("invalid", classes::SYN_INVALID),
    ("markup.bold", classes::SYN_KEYWORD),
    ("markup.heading", classes::SYN_FUNCTION),
    ("markup.inserted", classes::SYN_STRING),
    ("markup.deleted", classes::SYN_INVALID),
];

/// The same lookup from a textual scope.  Only the tests reach for this — the
/// renderer always has an interned [`Scope`] already.
#[cfg(test)]
fn scope_class(scope: &str) -> Option<&'static str> {
    scope_class_of(Scope::new(scope).ok()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_language_produces_spans() {
        let mut hl = Highlighter::new("rust");
        assert!(hl.active());
        let spans = hl.line("fn main() {}");
        assert!(
            spans
                .iter()
                .any(|(_, _, class)| *class == classes::SYN_KEYWORD)
        );
    }

    #[test]
    fn unknown_language_is_inert() {
        let mut hl = Highlighter::new("definitely-not-a-language");
        assert!(!hl.active());
        assert!(hl.line("anything at all").is_empty());
    }

    fn owned(lines: &[&str]) -> Vec<String> {
        lines.iter().map(|line| (*line).to_string()).collect()
    }

    #[test]
    fn block_matches_line_by_line_highlighting() {
        let lines = owned(&[
            "fn main() {",
            "    // a comment",
            "    let x = \"hi\";",
            "}",
        ]);
        let mut hl = Highlighter::new("rust");
        let expected: Vec<Spans> = lines.iter().map(|line| hl.line(line)).collect();
        assert_eq!(*block("rust", &lines), expected);
    }

    #[test]
    fn block_is_memoised_on_its_content() {
        // Distinctive enough that no other test evicts or collides with it.
        let lines = owned(&["const MEMO_PROBE: u8 = 7; // block_is_memoised_on_its_content"]);
        let first = block("rust", &lines);
        let second = block("rust", &lines);
        assert!(
            Arc::ptr_eq(&first, &second),
            "the second call should come back from the cache"
        );

        // The language is part of the key: the same bytes as another syntax is
        // a different answer, not a hit.
        let other = block("python", &lines);
        assert!(!Arc::ptr_eq(&first, &other));
    }

    /// A document is walked top to bottom, once, and the cache has to survive
    /// that.  It did not: with a count-capped LRU, a document with one more
    /// fence than the cache held evicted every entry just before it was wanted
    /// again, and the hit rate went from complete to zero — 0.45 ms of render
    /// at 128 blocks against 11.12 ms at 129.
    #[test]
    fn a_scan_longer_than_the_cache_still_hits_on_the_second_pass() {
        let blocks: Vec<Vec<String>> = (0..300)
            .map(|index| owned(&[&format!("const SCAN_PROBE_{index}: u32 = {index};")]))
            .collect();
        let first: Vec<_> = blocks.iter().map(|lines| block("rust", lines)).collect();
        let second: Vec<_> = blocks.iter().map(|lines| block("rust", lines)).collect();

        let hits = first
            .iter()
            .zip(&second)
            .filter(|(a, b)| Arc::ptr_eq(a, b))
            .count();
        assert_eq!(
            hits,
            blocks.len(),
            "a second pass over the same document should hit every block"
        );
    }

    #[test]
    fn block_of_an_unknown_language_is_empty() {
        let lines = owned(&["anything at all"]);
        assert!(block("definitely-not-a-language", &lines).is_empty());
        assert!(block("", &lines).is_empty());
    }

    #[test]
    fn an_oversized_block_still_highlights() {
        // Too big to cache; it must come back highlighted all the same.
        let line = "let x = 1; // ".to_string() + &"padding ".repeat(64);
        let lines: Vec<String> = std::iter::repeat_n(line, CACHE_MAX_BYTES / 512 + 32).collect();
        let spans = block("rust", &lines);
        assert_eq!(spans.len(), lines.len());
        assert_eq!(spans[0], Highlighter::new("rust").line(&lines[0]));
        assert!(!spans[0].is_empty());
    }

    #[test]
    fn aliases_resolve() {
        assert!(Highlighter::new("py").active());
        assert!(Highlighter::new("bash").active());
        assert!(Highlighter::new("console").active());
    }

    #[test]
    fn info_string_extras_are_ignored() {
        assert!(Highlighter::new("rust,no_run").active());
        assert!(Highlighter::new("rust {.numbered}").active());
    }

    #[test]
    fn spans_stay_inside_the_line() {
        let mut hl = Highlighter::new("rust");
        let line = "let x = \"hi\";";
        for (offset, len, _) in hl.line(line) {
            assert!(
                offset + len <= line.len(),
                "span {offset}+{len} escapes {line:?}"
            );
        }
    }

    #[test]
    fn longest_prefix_wins() {
        assert_eq!(
            scope_class("constant.numeric.integer.rust"),
            Some(classes::SYN_NUMBER)
        );
        assert_eq!(
            scope_class("constant.other.rust"),
            Some(classes::SYN_CONSTANT)
        );
        assert_eq!(
            scope_class("keyword.operator.arithmetic"),
            Some(classes::SYN_OPERATOR)
        );
    }

    #[test]
    fn multibyte_source_keeps_char_boundaries() {
        let mut hl = Highlighter::new("python");
        let line = "s = \"中文注释\"  # 说明";
        for (offset, len, _) in hl.line(line) {
            assert!(line.is_char_boundary(offset));
            assert!(line.is_char_boundary(offset + len));
        }
    }
}
