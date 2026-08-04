//! The closed set of text-property classes the renderer may emit.
//!
//! A class is a suffix, not a highlight group: the Vim side registers a
//! property type per class and links `SimpleMarkdown<Class>` to something in
//! the user's colour scheme.  Keeping the set closed and enumerable is what
//! lets `--classes` and `make check-classes` prove the two sides agree — an
//! unregistered property type is a hard `prop_add()` error at render time, in
//! a callback, where it is thoroughly unpleasant to debug.

macro_rules! classes {
    ($($konst:ident => $name:literal),* $(,)?) => {
        $(pub const $konst: &str = $name;)*
        /// Every class, in declaration order.  `--classes` prints this.
        pub const ALL: &[&str] = &[$($name),*];
    };
}

classes! {
    // Headings: the text itself, and the leading rule/marker column.
    H1          => "H1",
    H2          => "H2",
    H3          => "H3",
    H4          => "H4",
    H5          => "H5",
    H6          => "H6",
    HEAD_MARK   => "HeadMark",
    HEAD_RULE   => "HeadRule",

    // Inline emphasis.
    BOLD        => "Bold",
    ITALIC      => "Italic",
    BOLD_ITALIC => "BoldItalic",
    STRIKE      => "Strike",

    // Code.
    CODE        => "Code",
    CODE_BLOCK  => "CodeBlock",
    CODE_BORDER => "CodeBorder",
    CODE_LANG   => "CodeLang",
    CODE_CONT   => "CodeCont",

    // Links and images.
    LINK        => "Link",
    LINK_URL    => "LinkUrl",
    IMAGE       => "Image",
    FOOTNOTE    => "Footnote",

    // Block decorations.
    QUOTE       => "Quote",
    QUOTE_BAR   => "QuoteBar",
    ALERT_NOTE  => "AlertNote",
    ALERT_TIP   => "AlertTip",
    ALERT_IMPORTANT => "AlertImportant",
    ALERT_WARNING   => "AlertWarning",
    ALERT_CAUTION   => "AlertCaution",
    BULLET      => "Bullet",
    NUMBER      => "Number",
    TASK        => "Task",
    TASK_DONE   => "TaskDone",
    RULE        => "Rule",
    TERM        => "Term",

    // Tables.
    TABLE_BORDER => "TableBorder",
    TABLE_HEAD   => "TableHead",

    // Raw passthrough.
    HTML        => "Html",

    // Code-block syntax classes.  Mapped from syntect scopes, deliberately
    // coarse: the point is to land on groups every colour scheme defines.
    SYN_KEYWORD  => "SynKeyword",
    SYN_STRING   => "SynString",
    SYN_COMMENT  => "SynComment",
    SYN_NUMBER   => "SynNumber",
    SYN_BOOLEAN  => "SynBoolean",
    SYN_TYPE     => "SynType",
    SYN_FUNCTION => "SynFunction",
    SYN_CONSTANT => "SynConstant",
    SYN_OPERATOR => "SynOperator",
    SYN_PUNCT    => "SynPunct",
    SYN_VARIABLE => "SynVariable",
    SYN_PROPERTY => "SynProperty",
    SYN_PREPROC  => "SynPreProc",
    SYN_TAG      => "SynTag",
    SYN_ESCAPE   => "SynEscape",
    SYN_INVALID  => "SynInvalid",
}

/// The heading class for a level, clamped to the six that exist.
pub fn heading(level: u8) -> &'static str {
    match level {
        1 => H1,
        2 => H2,
        3 => H3,
        4 => H4,
        5 => H5,
        _ => H6,
    }
}
