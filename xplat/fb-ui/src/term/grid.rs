//! The terminal grid: herdr frame bytes in, an owned snapshot of cells out (alacritty_terminal does the parsing).
//!
//! A full frame resets the grid (like Swift: resize to the frame size, then `ESC c`, then the bytes). An increment
//! is applied as is. The size follows the frame's width and height. There is no scrollback here: the live view never
//! scrolls (history is a separate read-only view).

use std::time::Instant;

use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color, CursorShape as VteShape, NamedColor, Processor};

/// A cell color before the palette maps it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TermColor {
    /// The terminal's own foreground or background (the background stays transparent).
    Default,
    /// 0..=15 are the ANSI colors, 16..=231 the 6x6x6 cube, 232..=255 the gray ramp.
    Indexed(u8),
    Rgb(u8, u8, u8),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellView {
    pub ch: char,
    pub fg: TermColor,
    pub bg: TermColor,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strike: bool,
    pub inverse: bool,
    pub dim: bool,
    pub hidden: bool,
    /// The first of two cells. The next cell is its spacer (`ch == ' '`, `spacer`).
    pub wide: bool,
    pub spacer: bool,
}

impl Default for CellView {
    fn default() -> Self {
        CellView {
            ch: ' ',
            fg: TermColor::Default,
            bg: TermColor::Default,
            bold: false,
            italic: false,
            underline: false,
            strike: false,
            inverse: false,
            dim: false,
            hidden: false,
            wide: false,
            spacer: false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CursorShape {
    Block,
    Underline,
    Beam,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CursorView {
    pub col: usize,
    pub row: usize,
    pub shape: CursorShape,
    pub wide: bool,
}

/// What the widget draws. Owned, so a view can hold it without borrowing the parser.
#[derive(Debug, Clone, PartialEq)]
pub struct GridSnapshot {
    pub cols: usize,
    pub rows: usize,
    /// Row-major, `cols * rows` cells.
    pub cells: Vec<CellView>,
    /// `None` when the program hides the cursor.
    pub cursor: Option<CursorView>,
}

impl GridSnapshot {
    pub fn blank(cols: usize, rows: usize) -> GridSnapshot {
        GridSnapshot { cols, rows, cells: vec![CellView::default(); cols * rows], cursor: None }
    }

    pub fn cell(&self, col: usize, row: usize) -> Option<&CellView> {
        (col < self.cols && row < self.rows).then(|| &self.cells[row * self.cols + col])
    }

    /// One row as text. Spacer cells and trailing blanks are dropped.
    pub fn row_text(&self, row: usize) -> String {
        if row >= self.rows {
            return String::new();
        }
        let s: String = self.cells[row * self.cols..(row + 1) * self.cols].iter().filter(|c| !c.spacer).map(|c| c.ch).collect();
        s.trim_end().to_string()
    }
}

pub struct TermGrid {
    term: Term<VoidListener>,
    parser: Processor,
    cols: usize,
    rows: usize,
}

struct Size {
    cols: usize,
    rows: usize,
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.rows
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

/// Largest grid a frame may ask for. herdr never sends more; a corrupt size must not allocate gigabytes.
pub const MAX_COLS: usize = 1000;
pub const MAX_ROWS: usize = 500;

fn config(history: usize) -> Config {
    // herdr keeps the history. The live view has none.
    Config { scrolling_history: history, ..Config::default() }
}

impl TermGrid {
    pub fn new(cols: usize, rows: usize) -> TermGrid {
        TermGrid::with_history(cols, rows, 0)
    }

    /// A grid that keeps up to `history` lines that scrolled off the top (for [`TermGrid::snapshot_all`]).
    pub fn with_history(cols: usize, rows: usize, history: usize) -> TermGrid {
        let (cols, rows) = (cols.clamp(1, MAX_COLS), rows.clamp(1, MAX_ROWS));
        TermGrid { term: Term::new(config(history), &Size { cols, rows }, VoidListener), parser: Processor::new(), cols, rows }
    }

    pub fn size(&self) -> (usize, usize) {
        (self.cols, self.rows)
    }

    /// Applies one herdr frame. `full` resets the grid first. A width or height of 0 keeps the current size.
    pub fn feed(&mut self, full: bool, width: u32, height: u32, bytes: &[u8]) {
        if full {
            // A corrupt size must not allocate gigabytes.
            let (width, height) = ((width as usize).min(MAX_COLS), (height as usize).min(MAX_ROWS));
            if width > 0 && height > 0 && (width != self.cols || height != self.rows) {
                self.cols = width;
                self.rows = height;
                self.term.resize(Size { cols: self.cols, rows: self.rows });
            }
            // An unfinished synchronized update (BSU without ESU) buffers every later byte, even a full frame.
            // A full frame starts from nothing, so the parser starts over too.
            self.parser = Processor::new();
            self.parser.advance(&mut self.term, b"\x1bc");
        }
        self.parser.advance(&mut self.term, bytes);
    }

    /// Ends a synchronized update (ESC [ ? 2026 h) whose end never came: vte holds every byte back until it ends or
    /// times out. Call it on each poll. Returns true when it flushed, so the caller redraws.
    pub fn flush_sync(&mut self, now: Instant) -> bool {
        match self.parser.sync_timeout().sync_timeout() {
            Some(at) if now >= at => {
                self.parser.stop_sync(&mut self.term);
                true
            }
            _ => false,
        }
    }

    /// Application cursor keys (DECCKM): arrows send `ESC O x` instead of `ESC [ x`.
    pub fn app_cursor(&self) -> bool {
        self.term.mode().contains(TermMode::APP_CURSOR)
    }

    pub fn alt_screen(&self) -> bool {
        self.term.mode().contains(TermMode::ALT_SCREEN)
    }

    pub fn bracketed_paste(&self) -> bool {
        self.term.mode().contains(TermMode::BRACKETED_PASTE)
    }

    /// Everything the grid holds, scrollback first, then the screen. Blank rows at the end are dropped (one row stays).
    /// No cursor. The row count is whatever the content needs, so a reader never loses a top line to a bad guess.
    pub fn snapshot_all(&self) -> GridSnapshot {
        let grid = self.term.grid();
        let (top, bottom) = (grid.topmost_line().0, grid.bottommost_line().0);
        let blank = CellView::default();
        let mut cells: Vec<CellView> = Vec::new();
        for line in top..=bottom {
            for col in 0..self.cols {
                cells.push(view_of(&grid[Line(line)][Column(col)]));
            }
        }
        let mut rows = (bottom - top + 1) as usize;
        while rows > 1 && cells[(rows - 1) * self.cols..rows * self.cols].iter().all(|c| *c == blank) {
            rows -= 1;
        }
        cells.truncate(rows * self.cols);
        GridSnapshot { cols: self.cols, rows, cells, cursor: None }
    }

    pub fn snapshot(&self) -> GridSnapshot {
        let mut snap = GridSnapshot::blank(self.cols, self.rows);
        let content = self.term.renderable_content();
        for ic in content.display_iter {
            let (row, col) = (ic.point.line.0, ic.point.column.0);
            if row < 0 || row as usize >= self.rows || col >= self.cols {
                continue;
            }
            snap.cells[row as usize * self.cols + col] = view_of(ic.cell);
        }
        if self.term.mode().contains(TermMode::SHOW_CURSOR) && content.cursor.shape != VteShape::Hidden {
            let (row, col) = (content.cursor.point.line.0, content.cursor.point.column.0);
            if row >= 0 && (row as usize) < self.rows && col < self.cols {
                let shape = match content.cursor.shape {
                    VteShape::Underline => CursorShape::Underline,
                    VteShape::Beam => CursorShape::Beam,
                    _ => CursorShape::Block,
                };
                let wide = snap.cells[row as usize * self.cols + col].wide;
                snap.cursor = Some(CursorView { col, row: row as usize, shape, wide });
            }
        }
        snap
    }
}

fn convert(c: Color) -> TermColor {
    match c {
        Color::Spec(rgb) => TermColor::Rgb(rgb.r, rgb.g, rgb.b),
        Color::Indexed(i) => TermColor::Indexed(i),
        Color::Named(n) => {
            let v = n as usize;
            match n {
                NamedColor::Foreground | NamedColor::Background | NamedColor::Cursor | NamedColor::BrightForeground | NamedColor::DimForeground => TermColor::Default,
                _ if v < 16 => TermColor::Indexed(v as u8),
                // Dim black..white sit after the cursor color; they are the plain 0..=7 colors with the dim flag.
                NamedColor::DimBlack => TermColor::Indexed(0),
                NamedColor::DimRed => TermColor::Indexed(1),
                NamedColor::DimGreen => TermColor::Indexed(2),
                NamedColor::DimYellow => TermColor::Indexed(3),
                NamedColor::DimBlue => TermColor::Indexed(4),
                NamedColor::DimMagenta => TermColor::Indexed(5),
                NamedColor::DimCyan => TermColor::Indexed(6),
                NamedColor::DimWhite => TermColor::Indexed(7),
                _ => TermColor::Default,
            }
        }
    }
}

fn view_of(cell: &alacritty_terminal::term::cell::Cell) -> CellView {
    let f = cell.flags;
    CellView {
        ch: cell.c,
        fg: convert(cell.fg),
        bg: convert(cell.bg),
        bold: f.contains(Flags::BOLD),
        italic: f.contains(Flags::ITALIC),
        underline: f.intersects(Flags::ALL_UNDERLINES),
        strike: f.contains(Flags::STRIKEOUT),
        inverse: f.contains(Flags::INVERSE),
        dim: f.contains(Flags::DIM),
        hidden: f.contains(Flags::HIDDEN),
        wide: f.contains(Flags::WIDE_CHAR),
        spacer: f.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn full(cols: u32, rows: u32, s: &str) -> TermGrid {
        let mut g = TermGrid::new(1, 1);
        g.feed(true, cols, rows, s.as_bytes());
        g
    }

    #[test]
    fn a_full_frame_sets_the_size_and_draws_text() {
        let g = full(20, 4, "hello\r\nworld");
        assert_eq!(g.size(), (20, 4));
        let s = g.snapshot();
        assert_eq!((s.cols, s.rows), (20, 4));
        assert_eq!(s.row_text(0), "hello");
        assert_eq!(s.row_text(1), "world");
        assert_eq!(s.cursor, Some(CursorView { col: 5, row: 1, shape: CursorShape::Block, wide: false }));
    }

    #[test]
    fn the_size_follows_each_full_frame() {
        let mut g = full(20, 4, "abc");
        g.feed(true, 30, 6, b"xyz");
        assert_eq!(g.size(), (30, 6));
        let s = g.snapshot();
        assert_eq!((s.cols, s.rows, s.cells.len()), (30, 6, 180));
        assert_eq!(s.row_text(0), "xyz", "the full frame reset the old text");
    }

    #[test]
    fn a_full_frame_clears_and_an_increment_applies() {
        let mut g = full(10, 3, "old text");
        g.feed(true, 10, 3, b"new");
        assert_eq!(g.snapshot().row_text(0), "new");
        g.feed(false, 10, 3, b"\x1b[2;1Hnext");
        let s = g.snapshot();
        assert_eq!(s.row_text(0), "new", "an increment keeps what is there");
        assert_eq!(s.row_text(1), "next");
    }

    #[test]
    fn zero_size_keeps_the_size() {
        let mut g = full(10, 3, "a");
        g.feed(true, 0, 0, b"b");
        assert_eq!(g.size(), (10, 3));
        assert_eq!(g.snapshot().row_text(0), "b");
    }

    #[test]
    fn colors_ansi_256_and_truecolor() {
        let g = full(20, 2, "\x1b[31mR\x1b[0m\x1b[1;92mG\x1b[0m\x1b[38;5;200mP\x1b[48;2;1;2;3mT\x1b[0mN");
        let s = g.snapshot();
        assert_eq!(s.cell(0, 0).unwrap().fg, TermColor::Indexed(1));
        let g1 = s.cell(1, 0).unwrap();
        assert_eq!(g1.fg, TermColor::Indexed(10));
        assert!(g1.bold);
        assert_eq!(s.cell(2, 0).unwrap().fg, TermColor::Indexed(200));
        assert_eq!(s.cell(3, 0).unwrap().bg, TermColor::Rgb(1, 2, 3));
        let n = s.cell(4, 0).unwrap();
        assert_eq!((n.fg, n.bg), (TermColor::Default, TermColor::Default), "reset gives the defaults back");
    }

    #[test]
    fn attributes_bold_italic_underline_inverse_strike_dim() {
        let g = full(20, 1, "\x1b[1mb\x1b[0m\x1b[3mi\x1b[0m\x1b[4mu\x1b[0m\x1b[7mv\x1b[0m\x1b[9ms\x1b[0m\x1b[2md");
        let s = g.snapshot();
        assert!(s.cell(0, 0).unwrap().bold);
        assert!(s.cell(1, 0).unwrap().italic);
        assert!(s.cell(2, 0).unwrap().underline);
        assert!(s.cell(3, 0).unwrap().inverse);
        assert!(s.cell(4, 0).unwrap().strike);
        assert!(s.cell(5, 0).unwrap().dim);
    }

    #[test]
    fn cjk_wide_chars_take_two_cells() {
        let g = full(10, 1, "a你好b");
        let s = g.snapshot();
        let c = s.cell(1, 0).unwrap();
        assert!(c.wide && c.ch == '你');
        assert!(s.cell(2, 0).unwrap().spacer);
        assert!(s.cell(3, 0).unwrap().wide && s.cell(3, 0).unwrap().ch == '好');
        assert_eq!(s.cell(5, 0).unwrap().ch, 'b');
        assert_eq!(s.row_text(0), "a你好b");
        assert_eq!(s.cursor.unwrap().col, 6);
    }

    #[test]
    fn clear_screen_and_cursor_moves() {
        let mut g = full(10, 3, "junk\r\nmore");
        g.feed(false, 10, 3, b"\x1b[2J\x1b[Hok");
        let s = g.snapshot();
        assert_eq!(s.row_text(0), "ok");
        assert_eq!(s.row_text(1), "");
        assert_eq!(s.cursor.map(|c| (c.col, c.row)), Some((2, 0)));
    }

    #[test]
    fn the_cursor_hides_and_changes_shape() {
        let mut g = full(10, 2, "x");
        g.feed(false, 10, 2, b"\x1b[?25l");
        assert_eq!(g.snapshot().cursor, None);
        g.feed(false, 10, 2, b"\x1b[?25h\x1b[6 q");
        assert_eq!(g.snapshot().cursor.map(|c| c.shape), Some(CursorShape::Beam));
        g.feed(false, 10, 2, b"\x1b[4 q");
        assert_eq!(g.snapshot().cursor.map(|c| c.shape), Some(CursorShape::Underline));
    }

    #[test]
    fn alt_screen_and_back() {
        let mut g = full(10, 3, "main");
        assert!(!g.alt_screen());
        g.feed(false, 10, 3, b"\x1b[?1049h\x1b[Halt");
        assert!(g.alt_screen());
        assert_eq!(g.snapshot().row_text(0), "alt");
        g.feed(false, 10, 3, b"\x1b[?1049l");
        assert!(!g.alt_screen());
        assert_eq!(g.snapshot().row_text(0), "main", "the main screen is back");
    }

    #[test]
    fn a_full_frame_leaves_the_alt_screen() {
        let mut g = full(10, 3, "\x1b[?1049hvim");
        assert!(g.alt_screen());
        g.feed(true, 10, 3, b"shell");
        assert!(!g.alt_screen());
        assert_eq!(g.snapshot().row_text(0), "shell");
    }

    #[test]
    fn application_cursor_and_bracketed_paste_modes() {
        let mut g = full(10, 2, "");
        assert!(!g.app_cursor());
        g.feed(false, 10, 2, b"\x1b[?1h\x1b[?2004h");
        assert!(g.app_cursor() && g.bracketed_paste());
        g.feed(false, 10, 2, b"\x1b[?1l");
        assert!(!g.app_cursor());
    }

    #[test]
    fn long_output_scrolls_inside_the_screen() {
        let g = full(8, 2, "a\r\nb\r\nc");
        let s = g.snapshot();
        assert_eq!((s.row_text(0), s.row_text(1)), ("b".to_string(), "c".to_string()));
    }

    #[test]
    fn a_full_frame_after_an_unfinished_sync_update_still_draws() {
        let mut g = full(10, 3, "");
        g.feed(false, 10, 3, b"\x1b[?2026hhidden");
        assert_eq!(g.snapshot().row_text(0), "", "the sync update holds its bytes back");
        g.feed(true, 10, 3, b"fresh");
        assert_eq!(g.snapshot().row_text(0), "fresh", "a full frame is not swallowed by the open sync update");
        g.feed(false, 10, 3, b"\x1b[2;1Hnext");
        assert_eq!(g.snapshot().row_text(1), "next", "increments apply again");
    }

    #[test]
    fn an_expired_sync_update_is_flushed() {
        let mut g = full(10, 3, "");
        let t = std::time::Instant::now();
        g.feed(false, 10, 3, b"\x1b[?2026hlate");
        assert!(!g.flush_sync(t), "not due yet");
        assert_eq!(g.snapshot().row_text(0), "");
        assert!(g.flush_sync(t + std::time::Duration::from_secs(2)), "past the timeout");
        assert_eq!(g.snapshot().row_text(0), "late");
        assert!(!g.flush_sync(t + std::time::Duration::from_secs(3)), "nothing left to flush");
    }

    #[test]
    fn a_huge_frame_size_is_clamped() {
        let mut g = full(10, 3, "");
        g.feed(true, 4_000_000_000, 4_000_000_000, b"x");
        assert_eq!(g.size(), (MAX_COLS, MAX_ROWS));
        let s = g.snapshot();
        assert_eq!(s.cells.len(), MAX_COLS * MAX_ROWS);
        assert_eq!(s.row_text(0), "x");
    }

    #[test]
    fn snapshot_all_holds_scrollback_and_trims_blank_rows() {
        let mut g = TermGrid::with_history(6, 3, 1000);
        g.feed(true, 6, 3, b"one\r\ntwo\r\nthree\r\nfour\r\nfive");
        let all = g.snapshot_all();
        assert_eq!(all.rows, 5, "two lines scrolled into the history, all kept");
        assert_eq!(all.row_text(0), "one");
        assert_eq!(all.row_text(4), "five");
        assert_eq!(all.cursor, None);
        assert_eq!(g.snapshot().row_text(0), "three", "the plain snapshot is the screen");
        let blank = TermGrid::with_history(6, 3, 1000).snapshot_all();
        assert_eq!((blank.rows, blank.cols), (1, 6), "one row stays");
    }
}
