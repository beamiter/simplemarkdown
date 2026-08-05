//! Table layout.
//!
//! Produces finished rows — text plus properties with 1-based byte columns
//! relative to the table's own left edge — which the renderer then emits
//! behind whatever block prefix is in force.  Kept separate from the block
//! walker because column fitting is the one piece of layout here that has to
//! look at the whole structure before it can place a single character.

use crate::classes;
use crate::glyphs::Glyphs;
use crate::inline::{Laid, Run, wrap};
use crate::protocol::Prop;
use unicode_width::UnicodeWidthStr;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Align {
    Left,
    Center,
    Right,
}

/// One cell's inline content, already styled.
pub type Cell = Vec<Run>;

pub struct Table {
    pub header: Vec<Cell>,
    pub rows: Vec<Vec<Cell>>,
    pub aligns: Vec<Align>,
}

/// A laid-out row of the table.
pub struct Row {
    pub text: String,
    pub props: Vec<Prop>,
    pub links: Vec<(usize, usize, String)>,
    pub src: u32,
}

/// Padding inside a cell: one space either side of the content.
const PAD: usize = 1;
/// A column costs its content width plus both pads plus the divider to its left.
const PER_COLUMN: usize = PAD * 2 + 1;
/// Below this a column holds nothing but an ellipsis, so stop shrinking.
const MIN_COLUMN: usize = 3;

/// `zebra` tints every other body row.  A wide table is read across, and the
/// eye needs something to run along; the alternative is counting dividers.
pub fn layout(table: &Table, avail: usize, glyphs: &Glyphs, zebra: bool) -> Vec<Row> {
    let columns = table
        .header
        .len()
        .max(table.rows.iter().map(Vec::len).max().unwrap_or(0));
    if columns == 0 {
        return Vec::new();
    }

    let widths = fit(table, columns, avail);
    let mut out = Vec::new();

    out.push(border(
        &widths,
        glyphs.tbl_tl,
        glyphs.tbl_t,
        glyphs.tbl_tr,
        glyphs.tbl_h,
    ));
    if !table.header.is_empty() {
        out.extend(body_rows(&table.header, &widths, table, glyphs, true));
        out.push(border(
            &widths,
            glyphs.tbl_l,
            glyphs.tbl_x,
            glyphs.tbl_r,
            glyphs.tbl_h,
        ));
    }
    for (index, row) in table.rows.iter().enumerate() {
        let laid = body_rows(row, &widths, table, glyphs, false);
        // The stripe follows the source row, not the rendered one: a row whose
        // cells wrapped onto three lines is one stripe, not three.
        let stripe = zebra && index % 2 == 1;
        out.extend(laid.into_iter().map(|mut row| {
            if stripe {
                // Behind everything else, and pushed first so a same-priority
                // class drawn later still wins.
                row.props
                    .insert(0, Prop(1, row.text.len(), classes::TABLE_ROW_ALT));
            }
            row
        }));
    }
    out.push(border(
        &widths,
        glyphs.tbl_bl,
        glyphs.tbl_b,
        glyphs.tbl_br,
        glyphs.tbl_h,
    ));
    out
}

/// Choose a width for every column.
///
/// Natural widths win when they fit.  When they do not, columns narrower than
/// an equal share keep what they need and the surplus is shared among the wide
/// ones in proportion to their demand, so a table of one prose column and three
/// short ones does not shrink the short ones to nothing.
fn fit(table: &Table, columns: usize, avail: usize) -> Vec<usize> {
    let mut natural = vec![0usize; columns];
    for row in std::iter::once(&table.header).chain(table.rows.iter()) {
        for (index, cell) in row.iter().enumerate().take(columns) {
            natural[index] = natural[index].max(cell_width(cell));
        }
    }
    for width in natural.iter_mut() {
        *width = (*width).max(1);
    }

    let overhead = columns * PER_COLUMN + 1;
    let budget = avail.saturating_sub(overhead);
    let total: usize = natural.iter().sum();
    if budget == 0 {
        return vec![MIN_COLUMN; columns];
    }
    if total <= budget {
        return natural;
    }

    let mut widths = natural.clone();
    let mut fixed = vec![false; columns];
    loop {
        let free_columns = fixed.iter().filter(|done| !**done).count();
        if free_columns == 0 {
            break;
        }
        let used: usize = widths
            .iter()
            .zip(&fixed)
            .filter(|(_, done)| **done)
            .map(|(width, _)| *width)
            .sum();
        let share = budget.saturating_sub(used) / free_columns;
        if share < MIN_COLUMN {
            // Nothing left to share fairly; floor everything still free.
            for (width, done) in widths.iter_mut().zip(&fixed) {
                if !*done {
                    *width = MIN_COLUMN;
                }
            }
            break;
        }
        // Columns that already fit inside their share are settled; repeat, and
        // the space they gave back widens the columns that still need it.
        let settled: Vec<usize> = (0..columns)
            .filter(|index| !fixed[*index] && widths[*index] <= share)
            .collect();
        if settled.is_empty() {
            for index in 0..columns {
                if !fixed[index] {
                    widths[index] = share;
                }
            }
            break;
        }
        for index in settled {
            fixed[index] = true;
        }
    }
    widths
}

/// The width a cell wants on one line: its runs joined, whitespace collapsed.
fn cell_width(cell: &Cell) -> usize {
    let mut text = String::new();
    for run in cell {
        text.push_str(&run.text);
    }
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .width()
}

fn body_rows(
    cells: &[Cell],
    widths: &[usize],
    table: &Table,
    glyphs: &Glyphs,
    header: bool,
) -> Vec<Row> {
    let columns = widths.len();
    // Wrap every cell first: the row is as tall as its tallest cell.
    let wrapped: Vec<Vec<Laid>> = (0..columns)
        .map(|index| match cells.get(index) {
            Some(cell) if !cell.is_empty() => wrap(cell, widths[index]),
            _ => vec![Laid::default()],
        })
        .collect();
    let height = wrapped.iter().map(Vec::len).max().unwrap_or(1);
    let src = cells
        .iter()
        .flatten()
        .map(|run| run.src)
        .find(|src| *src > 0)
        .unwrap_or(0);

    (0..height)
        .map(|line| {
            let mut row = Row {
                text: String::new(),
                props: Vec::new(),
                links: Vec::new(),
                src: if line == 0 { src } else { 0 },
            };
            for index in 0..columns {
                push_border(&mut row, glyphs.tbl_v);
                row.text.push(' ');

                let empty = Laid::default();
                let laid = wrapped[index].get(line).unwrap_or(&empty);
                let align = table.aligns.get(index).copied().unwrap_or(Align::Left);
                let content = laid.text.width().min(widths[index]);
                let slack = widths[index] - content;
                let (before, after) = match align {
                    Align::Left => (0, slack),
                    Align::Right => (slack, 0),
                    Align::Center => (slack / 2, slack - slack / 2),
                };

                row.text.push_str(&" ".repeat(before));
                let base = row.text.len();
                row.text.push_str(&laid.text);
                for prop in &laid.props {
                    row.props.push(Prop(base + prop.0, prop.1, prop.2));
                }
                if header {
                    row.props
                        .push(Prop(base + 1, laid.text.len(), classes::TABLE_HEAD));
                }
                for (col, len, href) in &laid.links {
                    row.links.push((base + col, *len, href.clone()));
                }
                row.text.push_str(&" ".repeat(after));
                row.text.push(' ');
            }
            push_border(&mut row, glyphs.tbl_v);
            row
        })
        .collect()
}

fn push_border(row: &mut Row, glyph: &str) {
    let col = row.text.len() + 1;
    row.text.push_str(glyph);
    match row.props.last_mut() {
        Some(last) if last.2 == classes::TABLE_BORDER && last.0 + last.1 == col => {
            last.1 += glyph.len();
        }
        _ => row
            .props
            .push(Prop(col, glyph.len(), classes::TABLE_BORDER)),
    }
}

fn border(widths: &[usize], left: &str, mid: &str, right: &str, fill: &str) -> Row {
    let mut text = String::from(left);
    for (index, width) in widths.iter().enumerate() {
        if index > 0 {
            text.push_str(mid);
        }
        text.push_str(&fill.repeat(width + PAD * 2));
    }
    text.push_str(right);
    let len = text.len();
    Row {
        props: vec![Prop(1, len, classes::TABLE_BORDER)],
        text,
        links: Vec::new(),
        src: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::glyphs;
    use crate::inline::Style;

    fn cell(text: &str) -> Cell {
        vec![Run::new(text, Style::default(), 1)]
    }

    fn simple() -> Table {
        Table {
            header: vec![cell("Name"), cell("Value")],
            rows: vec![vec![cell("a"), cell("1")], vec![cell("bb"), cell("22")]],
            aligns: vec![Align::Left, Align::Right],
        }
    }

    #[test]
    fn every_row_is_the_same_width() {
        let rows = layout(&simple(), 60, &glyphs::UNICODE, false);
        let widths: Vec<usize> = rows.iter().map(|row| row.text.width()).collect();
        assert!(
            widths.windows(2).all(|pair| pair[0] == pair[1]),
            "{widths:?}"
        );
    }

    #[test]
    fn fits_inside_the_available_columns() {
        let wide = Table {
            header: vec![cell("a very long heading indeed"), cell("another long one")],
            rows: vec![vec![
                cell("a paragraph of text that will certainly not fit"),
                cell("x"),
            ]],
            aligns: vec![Align::Left, Align::Left],
        };
        let rows = layout(&wide, 40, &glyphs::UNICODE, false);
        for row in &rows {
            assert!(
                row.text.width() <= 40,
                "{:?} is {}",
                row.text,
                row.text.width()
            );
        }
    }

    #[test]
    fn right_alignment_pads_on_the_left() {
        let rows = layout(&simple(), 60, &glyphs::UNICODE, false);
        // Row 3 is the first body row: │ a  │  1 │
        assert!(rows[3].text.contains(" 1 │"));
    }

    #[test]
    fn properties_stay_inside_their_row() {
        let rows = layout(&simple(), 60, &glyphs::UNICODE, false);
        for row in &rows {
            for prop in &row.props {
                assert!(
                    prop.0 >= 1 && prop.0 + prop.1 - 1 <= row.text.len(),
                    "prop {prop:?} escapes {:?}",
                    row.text
                );
            }
        }
    }

    #[test]
    fn a_narrow_window_still_produces_a_table() {
        let rows = layout(&simple(), 12, &glyphs::UNICODE, false);
        assert!(!rows.is_empty());
        for row in &rows {
            assert!(row.text.width() <= 20);
        }
    }

    #[test]
    fn ascii_mode_uses_no_box_drawing() {
        let rows = layout(&simple(), 60, &glyphs::ASCII, false);
        for row in &rows {
            assert!(row.text.is_ascii(), "{:?}", row.text);
        }
    }

    #[test]
    fn wide_columns_shrink_before_narrow_ones() {
        let table = Table {
            header: vec![cell("id"), cell("description")],
            rows: vec![vec![
                cell("1"),
                cell("a long description that needs several lines to fit"),
            ]],
            aligns: vec![Align::Left, Align::Left],
        };
        let widths = fit(&table, 2, 40);
        assert_eq!(widths[0], 2, "the narrow column kept its natural width");
        assert!(widths[1] > widths[0]);
    }
}
