//! Text selection in a terminal grid. Local to the widget: it reads a [`GridSnapshot`] and never touches the program.
//!
//! The selection is linear, in reading order (like every terminal): the first row from its start column to the end,
//! the rows between whole, the last row up to its end column. A cell is `(col, row)`.

use super::grid::{CellView, GridSnapshot};

pub type Cell = (usize, usize);

/// Characters that end a word on a double click (the usual terminal set).
const SEPARATORS: &str = ",\u{2502}`|:\"' ()[]{}<>";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Selection {
    anchor: Cell,
    head: Cell,
    /// A word selection has an extent even when it is one cell wide.
    word: bool,
}

#[derive(PartialEq, Eq, Clone, Copy)]
enum Class {
    Space,
    Sep,
    Word,
}

fn class(cell: &CellView) -> Class {
    if cell.spacer {
        // The second half of a wide character belongs to the character.
        Class::Word
    } else if cell.ch == ' ' || cell.ch == '\0' {
        Class::Space
    } else if SEPARATORS.contains(cell.ch) {
        Class::Sep
    } else {
        Class::Word
    }
}

impl Selection {
    /// A click: an empty selection at `cell` that a drag extends.
    pub fn at(cell: Cell) -> Selection {
        Selection { anchor: cell, head: cell, word: false }
    }

    /// The word under `cell` (double click). A run of blanks, or one separator, selects itself.
    pub fn word_at(snap: &GridSnapshot, cell: Cell) -> Selection {
        let (col, row) = (cell.0.min(snap.cols.saturating_sub(1)), cell.1);
        let Some(first) = snap.cell(col, row) else { return Selection::at(cell) };
        let c = class(first);
        let same = |x: usize| snap.cell(x, row).is_some_and(|k| class(k) == c);
        // A separator selects only itself.
        let (mut start, mut end) = (col, col);
        if c != Class::Sep {
            while start > 0 && same(start - 1) {
                start -= 1;
            }
            while same(end + 1) {
                end += 1;
            }
        }
        Selection { anchor: (start, row), head: (end, row), word: true }
    }

    /// A drag: the moving end follows the pointer.
    pub fn extend(&mut self, cell: Cell) {
        self.head = cell;
    }

    /// True when something is selected (a click alone selects nothing).
    pub fn has_extent(&self) -> bool {
        self.word || self.anchor != self.head
    }

    /// Start and end in reading order, both inclusive.
    pub fn ordered(&self) -> (Cell, Cell) {
        let key = |c: Cell| (c.1, c.0);
        if key(self.anchor) <= key(self.head) {
            (self.anchor, self.head)
        } else {
            (self.head, self.anchor)
        }
    }

    /// The selected columns of `row` (inclusive), if the row is touched. `cols` is the grid width.
    pub fn row_span(&self, row: usize, cols: usize) -> Option<(usize, usize)> {
        if !self.has_extent() || cols == 0 {
            return None;
        }
        let ((sc, sr), (ec, er)) = self.ordered();
        if row < sr || row > er {
            return None;
        }
        let from = if row == sr { sc } else { 0 };
        let to = if row == er { ec } else { cols - 1 };
        Some((from.min(cols - 1), to.min(cols - 1)))
    }

    pub fn contains(&self, cell: Cell, cols: usize) -> bool {
        self.row_span(cell.1, cols).is_some_and(|(a, b)| cell.0 >= a && cell.0 <= b)
    }

    /// The selected text. Rows are joined with `\n`, trailing blanks of each row are dropped, spacer cells add nothing.
    pub fn text(&self, snap: &GridSnapshot) -> String {
        if !self.has_extent() || snap.rows == 0 || snap.cols == 0 {
            return String::new();
        }
        let ((_, sr), (_, er)) = self.ordered();
        let mut lines = Vec::new();
        for row in sr..=er.min(snap.rows - 1) {
            let Some((mut from, to)) = self.row_span(row, snap.cols) else { continue };
            // Starting on the second half of a wide character takes the whole character.
            if from > 0 && snap.cell(from, row).is_some_and(|c| c.spacer) {
                from -= 1;
            }
            let line: String = (from..=to).filter_map(|c| snap.cell(c, row)).filter(|c| !c.spacer).map(|c| if c.ch == '\0' { ' ' } else { c.ch }).collect();
            lines.push(line.trim_end().to_string());
        }
        lines.join("\n")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::term::TermGrid;

    fn snap(cols: u32, rows: u32, s: &str) -> GridSnapshot {
        let mut g = TermGrid::new(1, 1);
        g.feed(true, cols, rows, s.as_bytes());
        g.snapshot()
    }

    fn drag(a: Cell, b: Cell) -> Selection {
        let mut s = Selection::at(a);
        s.extend(b);
        s
    }

    #[test]
    fn a_click_selects_nothing() {
        let s = Selection::at((3, 1));
        assert!(!s.has_extent());
        assert_eq!(s.text(&snap(10, 2, "hello")), "");
        assert_eq!(s.row_span(1, 10), None);
    }

    #[test]
    fn a_drag_selects_inclusive_in_either_direction() {
        let g = snap(20, 2, "hello world");
        assert_eq!(drag((0, 0), (4, 0)).text(&g), "hello");
        assert_eq!(drag((4, 0), (0, 0)).text(&g), "hello", "backwards");
        assert_eq!(drag((6, 0), (10, 0)).text(&g), "world");
    }

    #[test]
    fn a_multi_row_selection_runs_in_reading_order() {
        let g = snap(10, 3, "alpha\r\nbeta\r\ngamma");
        assert_eq!(drag((2, 0), (1, 2)).text(&g), "pha\nbeta\nga");
        assert_eq!(drag((1, 2), (2, 0)).text(&g), "pha\nbeta\nga", "backwards");
        assert_eq!(drag((2, 0), (1, 2)).row_span(1, 10), Some((0, 9)), "a middle row is whole");
        assert!(drag((2, 0), (1, 2)).contains((9, 1), 10));
        assert!(!drag((2, 0), (1, 2)).contains((1, 0), 10));
    }

    #[test]
    fn trailing_blanks_are_dropped_per_row() {
        let g = snap(10, 2, "ab\r\ncd");
        assert_eq!(drag((0, 0), (9, 1)).text(&g), "ab\ncd");
    }

    #[test]
    fn wide_chars_copy_once_and_a_spacer_start_takes_the_character() {
        let g = snap(10, 1, "a\u{4f60}\u{597d}b");
        assert_eq!(drag((0, 0), (5, 0)).text(&g), "a\u{4f60}\u{597d}b");
        assert_eq!(drag((2, 0), (3, 0)).text(&g), "\u{4f60}\u{597d}", "starts on the spacer of the first character");
    }

    #[test]
    fn a_double_click_selects_the_word() {
        let g = snap(30, 1, "run cargo-test --all now");
        let s = Selection::word_at(&g, (6, 0));
        assert!(s.has_extent());
        assert_eq!(s.text(&g), "cargo-test");
        assert_eq!(Selection::word_at(&g, (0, 0)).text(&g), "run");
        assert_eq!(Selection::word_at(&g, (21, 0)).text(&g), "now");
        let one = snap(10, 1, "a b");
        assert_eq!(Selection::word_at(&one, (0, 0)).text(&one), "a", "a one-cell word still has an extent");
    }

    #[test]
    fn a_separator_selects_only_itself_and_the_path_stays_one_word() {
        let g = snap(30, 1, "(src/main.rs:42)");
        assert_eq!(Selection::word_at(&g, (0, 0)).text(&g), "(");
        assert_eq!(Selection::word_at(&g, (5, 0)).text(&g), "src/main.rs");
    }

    #[test]
    fn a_cjk_word_is_one_selection() {
        let g = snap(20, 1, "x \u{4f60}\u{597d} y");
        assert_eq!(Selection::word_at(&g, (3, 0)).text(&g), "\u{4f60}\u{597d}");
    }

    #[test]
    fn a_selection_past_the_grid_is_clamped() {
        let g = snap(5, 2, "abcde\r\nfg");
        let s = drag((1, 0), (40, 9));
        assert_eq!(s.text(&g), "bcde\nfg");
        assert_eq!(s.row_span(0, 5), Some((1, 4)));
    }
}
