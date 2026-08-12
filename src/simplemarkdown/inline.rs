//! Styled inline text and the line breaker that lays it out.
//!
//! Inline content is modelled as a flat list of [`Run`]s — a slice of text
//! plus the emphasis flags in force over it — rather than a tree.  Wrapping
//! then works on runs directly, which is what makes `**bo**ld` break as one
//! word: the word boundary search never looks at the style, only at the
//! characters.

use crate::classes;
use crate::protocol::Prop;
use unicode_width::UnicodeWidthChar;
use unicode_width::UnicodeWidthStr;

/// Emphasis state in force over a run.  Several can be active at once, and
/// each contributes its own text property — Vim happily overlaps them.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Style {
    pub bold: bool,
    pub italic: bool,
    pub strike: bool,
    pub code: bool,
    pub link: bool,
    pub image: bool,
    /// A class applied on top of the flags, used for heading text and for the
    /// dim URL suffix after a link.
    pub base: Option<&'static str>,
}

impl Style {
    /// The classes this style contributes, most general first so that the
    /// later, more specific ones win on equal property priority.
    fn classes(&self) -> Vec<&'static str> {
        let mut out = Vec::new();
        if let Some(base) = self.base {
            out.push(base);
        }
        match (self.bold, self.italic) {
            (true, true) => out.push(classes::BOLD_ITALIC),
            (true, false) => out.push(classes::BOLD),
            (false, true) => out.push(classes::ITALIC),
            (false, false) => {}
        }
        if self.strike {
            out.push(classes::STRIKE);
        }
        if self.image {
            out.push(classes::IMAGE);
        } else if self.link {
            out.push(classes::LINK);
        }
        if self.code {
            out.push(classes::CODE);
        }
        out
    }
}

/// A styled slice of inline text.
#[derive(Debug, Clone)]
pub struct Run {
    pub text: String,
    pub style: Style,
    /// 1-based source line this text came from, 0 when unknown.  Carried all
    /// the way through wrapping so a wrapped paragraph still scroll-syncs to
    /// the right source line rather than to the paragraph's first line.
    pub src: u32,
    /// Link target, when the run is part of a link's text.  Recorded per run
    /// so the Vim side can offer "follow the link under the cursor".
    pub href: Option<String>,
}

impl Run {
    pub fn new(text: impl Into<String>, style: Style, src: u32) -> Self {
        Self {
            text: text.into(),
            style,
            src,
            href: None,
        }
    }
}

/// One laid-out row: text plus properties with 1-based byte columns, relative
/// to the start of the row (the caller shifts them past any block prefix).
#[derive(Debug, Default)]
pub struct Laid {
    pub text: String,
    pub props: Vec<Prop>,
    pub src: u32,
    /// Link spans on this row, as `(byte_col, byte_len, href)`.
    pub links: Vec<(usize, usize, String)>,
}

/// A breakable unit: either a run of whitespace or an unbreakable word, both
/// possibly spanning several style runs.
#[derive(Debug)]
enum Token {
    Word(Vec<Run>),
    Space,
    HardBreak,
}

/// The sentinel a hard break (`Event::HardBreak`, i.e. two trailing spaces)
/// is encoded as in the run stream, so tokenising stays a single pass.
pub const HARD_BREAK: char = '\u{0}';

/// Lay out `runs` into rows no wider than `avail` display columns.
///
/// `avail` of 0 means "do not wrap": everything lands on one row, hard breaks
/// excepted.  Rows are returned with no trailing whitespace.
pub fn wrap(runs: &[Run], avail: usize) -> Vec<Laid> {
    let tokens = tokenize(runs);
    let mut rows: Vec<Laid> = Vec::new();
    let mut current: Vec<Run> = Vec::new();
    let mut width = 0usize;
    let mut pending_space = false;

    for token in tokens {
        match token {
            Token::HardBreak => {
                rows.push(finish(std::mem::take(&mut current)));
                width = 0;
                pending_space = false;
            }
            Token::Space => {
                // Leading whitespace on a row is dropped, not carried.
                pending_space = !current.is_empty();
            }
            Token::Word(word) => {
                let word_width = word.iter().map(|run| run.text.width()).sum::<usize>();
                let gap = usize::from(pending_space);
                let fits = avail == 0 || width + gap + word_width <= avail;

                if !fits && !current.is_empty() {
                    rows.push(finish(std::mem::take(&mut current)));
                    width = 0;
                    pending_space = false;
                }

                if pending_space {
                    let style = word.first().map(|run| run.style).unwrap_or_default();
                    // A space carrying `code` keeps the inline-code background
                    // continuous across a break inside `` `a b` ``.
                    current.push(Run::new(
                        " ",
                        Style {
                            base: None,
                            ..style
                        },
                        0,
                    ));
                    width += 1;
                    pending_space = false;
                }

                // Still too wide on an empty row: the word itself exceeds the
                // column, so split it by display width.  URLs and unspaced CJK
                // both land here.
                if avail > 0 && word_width > avail {
                    for chunk in split_word(&word, avail, width) {
                        let chunk_width = chunk.iter().map(|run| run.text.width()).sum::<usize>();
                        if width + chunk_width > avail && !current.is_empty() {
                            rows.push(finish(std::mem::take(&mut current)));
                            width = 0;
                        }
                        current.extend(chunk);
                        width += chunk_width;
                    }
                } else {
                    current.extend(word);
                    width += word_width;
                }
            }
        }
    }

    if !current.is_empty() {
        rows.push(finish(current));
    }
    if rows.is_empty() {
        rows.push(Laid::default());
    }
    rows
}

fn tokenize(runs: &[Run]) -> Vec<Token> {
    let mut tokens: Vec<Token> = Vec::new();
    let mut word: Vec<Run> = Vec::new();

    let flush = |word: &mut Vec<Run>, tokens: &mut Vec<Token>| {
        if !word.is_empty() {
            tokens.push(Token::Word(std::mem::take(word)));
        }
    };

    for run in runs {
        // From the fields, not from `..run.clone()`; see `split_word`, where
        // the same shape was measurably quadratic.  Here the optimiser appears
        // to elide the cloned text today, which is a thing to stop depending
        // on: a wide character is its own token, so a Chinese paragraph pushes
        // one of these per glyph.
        let piece = |text: String| Run {
            text,
            style: run.style,
            src: run.src,
            href: run.href.clone(),
        };
        let mut buffer = String::new();
        for ch in run.text.chars() {
            if ch == HARD_BREAK {
                if !buffer.is_empty() {
                    word.push(piece(std::mem::take(&mut buffer)));
                }
                flush(&mut word, &mut tokens);
                tokens.push(Token::HardBreak);
                continue;
            }
            if ch.is_whitespace() {
                if !buffer.is_empty() {
                    word.push(piece(std::mem::take(&mut buffer)));
                }
                flush(&mut word, &mut tokens);
                tokens.push(Token::Space);
                continue;
            }
            buffer.push(ch);
            // Wide characters — CJK, most emoji — are their own break
            // opportunity.  Without this a Chinese paragraph is one enormous
            // "word" and every line gets hard-split mid-sentence at exactly
            // the column, which reads far worse than breaking between glyphs.
            if ch.width().unwrap_or(0) >= 2 {
                word.push(piece(std::mem::take(&mut buffer)));
                flush(&mut word, &mut tokens);
            }
        }
        if !buffer.is_empty() {
            word.push(piece(buffer));
        }
    }
    flush(&mut word, &mut tokens);
    tokens
}

/// Break an over-wide word into chunks that fit, honouring char boundaries and
/// double-width characters.  `used` is how much of the first row is gone.
fn split_word(word: &[Run], avail: usize, used: usize) -> Vec<Vec<Run>> {
    let mut chunks: Vec<Vec<Run>> = Vec::new();
    let mut chunk: Vec<Run> = Vec::new();
    let mut room = avail.saturating_sub(used).max(1);
    let mut width = 0usize;

    for run in word {
        // Built from the fields rather than from `..run.clone()`.  Functional
        // update syntax clones the *whole* source run — including a `text` it
        // then drops unused — once per chunk emitted, which made splitting one
        // unbroken run quadratic in its length: 75 KB cost 1.93 ms, 600 KB cost
        // 66.57 ms.  A token that long is a pasted blob rather than a word, and
        // a document containing one should not stop being editable.
        let piece = |text: String| Run {
            text,
            style: run.style,
            src: run.src,
            href: run.href.clone(),
        };
        let mut buffer = String::new();
        for ch in run.text.chars() {
            let cw = ch.width().unwrap_or(0);
            if width + cw > room && (width > 0 || !chunk.is_empty()) {
                if !buffer.is_empty() {
                    chunk.push(piece(std::mem::take(&mut buffer)));
                }
                chunks.push(std::mem::take(&mut chunk));
                room = avail.max(1);
                width = 0;
            }
            buffer.push(ch);
            width += cw;
        }
        if !buffer.is_empty() {
            chunk.push(piece(buffer));
        }
    }
    if !chunk.is_empty() {
        chunks.push(chunk);
    }
    chunks
}

/// Concatenate a row's runs and turn their styles into property spans.
fn finish(runs: Vec<Run>) -> Laid {
    let mut out = Laid::default();
    for run in runs {
        if run.text.is_empty() {
            continue;
        }
        if out.src == 0 && run.src > 0 {
            out.src = run.src;
        }
        let col = out.text.len() + 1;
        let len = run.text.len();
        out.text.push_str(&run.text);
        for class in run.style.classes() {
            push_prop(&mut out.props, Prop(col, len, class));
        }
        if let Some(href) = run.href {
            match out.links.last_mut() {
                // Split runs inside one link text (`[**a** b](x)`) are one link.
                Some(last) if last.2 == href && last.0 + last.1 == col => last.1 += len,
                _ => out.links.push((col, len, href)),
            }
        }
    }
    // Trailing whitespace would show up as a coloured gap under a link or code
    // span, and makes `$` land past the text.
    trim_end(&mut out);
    out
}

fn push_prop(props: &mut Vec<Prop>, prop: Prop) {
    if let Some(last) = props.last_mut()
        && last.2 == prop.2
        && last.0 + last.1 == prop.0
    {
        last.1 += prop.1;
        return;
    }
    props.push(prop);
}

fn trim_end(laid: &mut Laid) {
    let trimmed = laid.text.trim_end().len();
    if trimmed == laid.text.len() {
        return;
    }
    laid.text.truncate(trimmed);
    clamp(&mut laid.props, trimmed);
    laid.links.retain_mut(|(col, len, _)| {
        if *col > trimmed {
            return false;
        }
        *len = (*len).min(trimmed + 1 - *col);
        *len > 0
    });
}

/// Drop or shorten properties that would run past `len` bytes.  `prop_add()`
/// errors on a column past the end of the line, so this is not cosmetic.
pub fn clamp(props: &mut Vec<Prop>, len: usize) {
    props.retain_mut(|prop| {
        if prop.0 > len {
            return false;
        }
        prop.1 = prop.1.min(len + 1 - prop.0);
        prop.1 > 0
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plain(text: &str) -> Vec<Run> {
        vec![Run::new(text, Style::default(), 1)]
    }

    #[test]
    fn wraps_on_word_boundaries() {
        let rows = wrap(&plain("the quick brown fox jumps"), 10);
        assert_eq!(
            rows.iter().map(|r| r.text.as_str()).collect::<Vec<_>>(),
            vec!["the quick", "brown fox", "jumps"]
        );
    }

    #[test]
    fn zero_avail_means_no_wrapping() {
        let rows = wrap(&plain("the quick brown fox jumps"), 0);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].text, "the quick brown fox jumps");
    }

    #[test]
    fn over_wide_word_is_split_not_dropped() {
        let rows = wrap(&plain("https://example.com/a/very/long/path"), 12);
        let joined: String = rows.iter().map(|r| r.text.as_str()).collect();
        assert_eq!(joined, "https://example.com/a/very/long/path");
        assert!(rows.iter().all(|r| r.text.width() <= 12));
    }

    #[test]
    fn cjk_breaks_between_glyphs_and_respects_double_width() {
        let rows = wrap(&plain("中文换行测试内容"), 6);
        assert!(rows.len() > 1);
        assert!(rows.iter().all(|r| r.text.width() <= 6));
        let joined: String = rows.iter().map(|r| r.text.as_str()).collect();
        assert_eq!(joined, "中文换行测试内容");
    }

    #[test]
    fn style_spans_survive_a_break_mid_phrase() {
        let runs = vec![
            Run::new(
                "bo",
                Style {
                    bold: true,
                    ..Default::default()
                },
                1,
            ),
            Run::new("ld", Style::default(), 1),
            Run::new(" tail", Style::default(), 1),
        ];
        let rows = wrap(&runs, 40);
        assert_eq!(rows[0].text, "bold tail");
        assert_eq!(rows[0].props, vec![Prop(1, 2, classes::BOLD)]);
    }

    #[test]
    fn a_styled_word_is_never_broken_at_a_style_seam() {
        let runs = vec![
            Run::new(
                "aaa",
                Style {
                    bold: true,
                    ..Default::default()
                },
                1,
            ),
            Run::new("bbb", Style::default(), 1),
        ];
        // "aaabbb" is 6 wide and does not fit in 4, but it is one word, so it
        // must be split by width rather than at the seam.
        let rows = wrap(&runs, 4);
        assert_eq!(rows[0].text, "aaab");
    }

    #[test]
    fn properties_never_escape_their_row() {
        let runs = vec![Run::new(
            "word ",
            Style {
                bold: true,
                ..Default::default()
            },
            1,
        )];
        let rows = wrap(&runs, 40);
        assert_eq!(rows[0].text, "word");
        for prop in &rows[0].props {
            assert!(prop.0 + prop.1 - 1 <= rows[0].text.len());
        }
    }

    #[test]
    fn hard_break_starts_a_new_row() {
        let runs = vec![Run::new(format!("one{HARD_BREAK}two"), Style::default(), 1)];
        let rows = wrap(&runs, 40);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].text, "one");
        assert_eq!(rows[1].text, "two");
    }

    #[test]
    fn source_line_follows_the_text_not_the_block() {
        let runs = vec![
            Run::new("first", Style::default(), 7),
            Run::new(" ", Style::default(), 0),
            Run::new("second", Style::default(), 8),
        ];
        let rows = wrap(&runs, 6);
        assert_eq!(rows[0].src, 7);
        assert_eq!(rows[1].src, 8);
    }

    #[test]
    fn link_spans_merge_across_style_runs() {
        let mut a = Run::new(
            "bold",
            Style {
                bold: true,
                link: true,
                ..Default::default()
            },
            1,
        );
        a.href = Some("http://x".into());
        let mut b = Run::new(
            "text",
            Style {
                link: true,
                ..Default::default()
            },
            1,
        );
        b.href = Some("http://x".into());
        let rows = wrap(&[a, b], 40);
        assert_eq!(rows[0].links, vec![(1, 8, "http://x".to_string())]);
    }
}
