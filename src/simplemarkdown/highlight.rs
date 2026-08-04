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
use std::sync::OnceLock;
use syntect::easy::ScopeRegionIterator;
use syntect::parsing::{ParseState, ScopeStack, SyntaxReference, SyntaxSet};

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
        let token = info
            .split(|c: char| c.is_whitespace() || c == ',' || c == '{')
            .find(|part| !part.is_empty())
            .unwrap_or("")
            .trim_start_matches('.')
            .to_ascii_lowercase();
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
    pub fn line(&mut self, line: &str) -> Vec<(usize, usize, &'static str)> {
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
    stack.scopes.iter().rev().find_map(|scope| {
        let repr = scope.build_string();
        scope_class(&repr)
    })
}

fn scope_class(scope: &str) -> Option<&'static str> {
    // Longest-prefix-first: `constant.numeric` must win over `constant`, and
    // `entity.name.tag` over `entity.name`.
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
    let mut best: Option<(usize, &'static str)> = None;
    for (prefix, class) in MAP {
        if scope == *prefix || scope.starts_with(&format!("{prefix}.")) {
            let len = prefix.len();
            if best.is_none_or(|(seen, _)| len > seen) {
                best = Some((len, class));
            }
        }
    }
    best.map(|(_, class)| class)
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
