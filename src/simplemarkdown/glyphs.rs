//! The two decoration alphabets.
//!
//! Every glyph the renderer draws comes from here, so `unicode = false` is a
//! single switch rather than a condition sprinkled through the layout code.
//! The ASCII set exists for terminals whose font renders box-drawing at the
//! wrong advance width, which shifts every column in a table by one.

pub struct Glyphs {
    pub head_rule_heavy: &'static str,
    pub head_rule_light: &'static str,
    pub head_marks: [&'static str; 6],

    pub quote_bar: &'static str,
    pub bullets: [&'static str; 3],
    pub task_todo: &'static str,
    pub task_done: &'static str,
    pub rule: &'static str,

    pub box_tl: &'static str,
    pub box_tr: &'static str,
    pub box_bl: &'static str,
    pub box_br: &'static str,
    pub box_h: &'static str,
    pub box_v: &'static str,

    pub tbl_tl: &'static str,
    pub tbl_tr: &'static str,
    pub tbl_bl: &'static str,
    pub tbl_br: &'static str,
    pub tbl_t: &'static str,
    pub tbl_b: &'static str,
    pub tbl_l: &'static str,
    pub tbl_r: &'static str,
    pub tbl_x: &'static str,
    pub tbl_h: &'static str,
    pub tbl_v: &'static str,

    /// Marks a code line continued from the row above.
    pub code_cont: &'static str,
    /// Marks a code line clipped at the box edge.
    pub code_clip: &'static str,
    pub image: &'static str,
    /// Alert marker.  One glyph for all five kinds on purpose: the colour and
    /// the word already distinguish them, and every candidate glyph that would
    /// — ℹ, ✖ and friends — carries an emoji presentation that terminals draw
    /// two columns wide while unicode-width reports one, which silently pushes
    /// every following column out by one.
    pub alert: &'static str,
}

pub static UNICODE: Glyphs = Glyphs {
    head_rule_heavy: "━",
    head_rule_light: "─",
    head_marks: ["▌", "▌", "◆", "◇", "▪", "▫"],

    quote_bar: "▏",
    bullets: ["•", "◦", "▪"],
    task_todo: "☐",
    task_done: "☑",
    rule: "─",

    box_tl: "╭",
    box_tr: "╮",
    box_bl: "╰",
    box_br: "╯",
    box_h: "─",
    box_v: "│",

    tbl_tl: "┌",
    tbl_tr: "┐",
    tbl_bl: "└",
    tbl_br: "┘",
    tbl_t: "┬",
    tbl_b: "┴",
    tbl_l: "├",
    tbl_r: "┤",
    tbl_x: "┼",
    tbl_h: "─",
    tbl_v: "│",

    code_cont: "⤷",
    code_clip: "›",
    image: "▣",
    alert: "▸",
};

pub static ASCII: Glyphs = Glyphs {
    head_rule_heavy: "=",
    head_rule_light: "-",
    head_marks: ["#", "##", "###", "####", "#####", "######"],

    quote_bar: "|",
    bullets: ["*", "-", "+"],
    task_todo: "[ ]",
    task_done: "[x]",
    rule: "-",

    box_tl: "+",
    box_tr: "+",
    box_bl: "+",
    box_br: "+",
    box_h: "-",
    box_v: "|",

    tbl_tl: "+",
    tbl_tr: "+",
    tbl_bl: "+",
    tbl_br: "+",
    tbl_t: "+",
    tbl_b: "+",
    tbl_l: "+",
    tbl_r: "+",
    tbl_x: "+",
    tbl_h: "-",
    tbl_v: "|",

    code_cont: ">",
    code_clip: ">",
    image: "[img]",
    alert: ">",
};

pub fn for_mode(unicode: bool) -> &'static Glyphs {
    if unicode { &UNICODE } else { &ASCII }
}
